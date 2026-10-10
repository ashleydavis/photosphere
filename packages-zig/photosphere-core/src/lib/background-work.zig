//
// The work a phone does with the app off screen: the automatic import, the sync and the prefetch of a partial replica. Each is a loop
// that asks a planning task what its next pass should do, runs the tasks the plan hands back one after another, waits the gap the plan
// asked for, and asks again.
//
// Each loop is a task of its own whose type is registered as keep-alive, so while any of them is queued or running the core asks the
// shell to keep the app running (on Android a foreground service with its notification). The loops are queued by startBackgroundWork,
// which the page's startBackgroundImport request calls, and ended by stopBackgroundWork, which its stopBackgroundImport request calls,
// or by themselves when their plan says there is nothing left to do.
//
// The decisions of a pass are in the functions that take a LoopHost, a plain interface over everything that needs the platform or the
// core, so they are tested with no core and no phone. The loops report what they are doing to the shell, which writes it to the
// system log: the app's own log file is written through the page, which is suspended exactly when this work matters.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");
const main_state = @import("main-state.zig");

const TaskContext = ziggy.task_runner.TaskContext;
const json_util = ziggy.json_util;

//
// The gap between automatic import or prefetch passes when no plan has said what it should be, in milliseconds.
//
// Only reached when the very first plan read fails, because every plan carries a gap that the settings file resolves. It exists
// because a gap of zero is not a gap: the loop would ask for a pass, fail to read a plan, and ask again as fast as it could be answered.
//
pub const FALLBACK_PAUSE_MS: u64 = 30_000;

//
// The gap between sync passes when no plan has said what it should be, in milliseconds.
//
pub const SYNC_FALLBACK_PAUSE_MS: u64 = 5 * 60 * 1000;

//
// How long a wait between passes sleeps before it looks again at whether the loop has been told to stop, in milliseconds.
//
const PAUSE_SLICE_MS: u64 = 100;

//
// The three loops.
//
pub const Loop = enum {
    // Automatic import: takes new photos from the device library into the default database.
    import,
    // Sync: pushes the database the user works in to its origin.
    sync,
    // Prefetch: fills in the thumbnails and index files a partial replica is missing.
    prefetch,

    //
    // The task type the loop runs as.
    //
    pub fn taskType(self: Loop) []const u8 {
        return switch (self) {
            .import => "background-auto-import",
            .sync => "background-sync",
            .prefetch => "background-prefetch",
        };
    }

    //
    // The source the loop and every task it starts are queued under, so one cancellation stops the loop and the pass it is in.
    //
    pub fn source(self: Loop) []const u8 {
        return switch (self) {
            .import => "auto-import",
            .sync => "background-sync",
            .prefetch => "background-prefetch",
        };
    }

    //
    // What the loop's tasks are called in the messages about them.
    //
    pub fn label(self: Loop) []const u8 {
        return switch (self) {
            .import => "import",
            .sync => "sync",
            .prefetch => "prefetch",
        };
    }

    //
    // The loop that runs as a task type, or null when the type is not a loop's.
    //
    pub fn fromTaskType(task_type: []const u8) ?Loop {
        inline for (std.meta.fields(Loop)) |field| {
            const loop: Loop = @enumFromInt(field.value);
            if (std.mem.eql(u8, loop.taskType(), task_type)) {
                return loop;
            }
        }
        return null;
    }
};

//
// How many loops there are.
//
pub const LOOP_COUNT = std.meta.fields(Loop).len;

//
// What the last completed prefetch pass says about the replica, for the sync loop, which holds back while a prefetch is making
// progress.
//
// A sync that runs while a prefetch is working does the same work slowly and gets in its own way. What a sync must never do is wait for
// a prefetch that cannot finish, because a phone that has stopped syncing silently is the failure this exists to remove. So the states
// say whether the prefetch is making progress, not whether it is finished, and only one of them holds a sync back.
//
pub const ReplicaState = enum(u8) {
    // No pass has completed yet, so nothing is known. Syncing is allowed: refusing on no evidence is how a loop gets stuck.
    unknown,
    // The last pass fetched files, so the prefetch is getting through the replica. Syncing waits.
    working,
    // The last pass fetched nothing and left files missing, or failed outright. The prefetch is stuck, and syncing stops waiting for it.
    stalled,
    // The last pass fetched nothing and found nothing missing: the replica is filled in and the loop has stopped. Syncing is allowed.
    complete,
};

//
// One task a pass runs.
//
pub const IStep = struct {
    // The task type to queue.
    @"type": []const u8,
    // The task's input data.
    data: std.json.Value,
};

//
// What running one step did.
//
pub const IStepResult = struct {
    // Whether the step succeeded. A step that failed leaves the loop running, because what would not work is tried again on the next
    // pass.
    succeeded: bool,
    // How many files the step copied down from the origin (a prefetch step), or 0.
    files_fetched: u64,
    // How many files the step found missing and did not copy (a prefetch step), or 0.
    files_still_missing: u64,
};

//
// What a plan asks of one pass, read from the outputs of a planning task.
//
pub const IPlan = struct {
    // Whether a pass should run at all.
    should_run: bool,
    // The database the pass works on, for the log.
    database_path: []const u8,
    // Why the pass is not running, for the log.
    reason: []const u8,
    // How long to wait after the pass before the next one, in milliseconds.
    pause_ms: u64,
    // The tasks the pass runs, in order.
    steps: []const IStep,
};

//
// Everything a loop needs that it cannot do itself: running the planning task and the steps, waiting, keeping the CPU awake, and saying
// what happened. An interface so the loops' decisions are tested with no core, no phone and no clock.
//
pub const LoopHost = struct {
    // The implementation.
    ptr: *anyopaque,
    // The implementation's functions.
    vtable: *const VTable,

    //
    // The functions an implementation provides.
    //
    pub const VTable = struct {
        // Runs the planning task and returns its outputs. Fails when the task fails, which the loop treats as a pass that did not work
        // rather than as a reason to give up.
        readPlan: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, plan_task: []const u8, data: std.json.Value) anyerror!std.json.Value,
        // Runs one step and waits for it to finish.
        runStep: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, step: IStep) anyerror!IStepResult,
        // Waits for the given number of milliseconds, or until the loop is stopped. Returns false when the wait was cut short by a stop.
        pause: *const fn (ptr: *anyopaque, millis: u64) bool,
        // Keeps the CPU running while a pass is in flight, and lets it sleep again afterwards.
        holdAwake: *const fn (ptr: *anyopaque, awake: bool) anyerror!void,
        // Says what the loop is doing.
        report: *const fn (ptr: *anyopaque, message: []const u8) void,
        // Says what went wrong.
        reportError: *const fn (ptr: *anyopaque, message: []const u8) void,
        // Whether the loop has been told to stop.
        isStopped: *const fn (ptr: *anyopaque) bool,
    };

    fn readPlan(self: LoopHost, allocator: std.mem.Allocator, plan_task: []const u8, data: std.json.Value) !std.json.Value {
        return try self.vtable.readPlan(self.ptr, allocator, plan_task, data);
    }

    fn runStep(self: LoopHost, allocator: std.mem.Allocator, step: IStep) !IStepResult {
        return try self.vtable.runStep(self.ptr, allocator, step);
    }

    fn pause(self: LoopHost, millis: u64) bool {
        return self.vtable.pause(self.ptr, millis);
    }

    fn holdAwake(self: LoopHost, awake: bool) !void {
        try self.vtable.holdAwake(self.ptr, awake);
    }

    fn report(self: LoopHost, message: []const u8) void {
        self.vtable.report(self.ptr, message);
    }

    fn reportError(self: LoopHost, message: []const u8) void {
        self.vtable.reportError(self.ptr, message);
    }

    fn isStopped(self: LoopHost) bool {
        return self.vtable.isStopped(self.ptr);
    }
};

//
// The text of an error for the log: the message a thrown error recorded, otherwise the error's name.
//
fn describe(allocator: std.mem.Allocator, err: anyerror) []const u8 {
    return allocator.dupe(u8, utils.errors.errorMessage(err)) catch "out of memory";
}

//
// Reads a plan out of the outputs of a planning task. Every field that is missing is read as the answer that does nothing, so outputs
// that arrive malformed refuse a pass rather than running one on a guess. A step that has no type or no data is an error.
//
pub fn parsePlan(allocator: std.mem.Allocator, outputs: std.json.Value, fallback_pause_ms: u64) !IPlan {
    if (outputs != .object) {
        return utils.errors.throwError("The plan was not an object.", .{});
    }
    var steps: std.ArrayList(IStep) = .empty;
    if (outputs.object.get("steps")) |steps_value| {
        if (steps_value == .array) {
            for (steps_value.array.items) |item| {
                const step_type = json_util.getString(item, "type") orelse {
                    return utils.errors.throwError("A step of the plan has no type.", .{});
                };
                const data = if (item == .object) item.object.get("data") else null;
                if (data == null or data.? != .object) {
                    return utils.errors.throwError("The step \"{s}\" of the plan has no data.", .{step_type});
                }
                try steps.append(allocator, .{
                    .@"type" = step_type,
                    .data = data.?,
                });
            }
        }
    }
    const should_run = if (outputs.object.get("shouldRun")) |value| (value == .bool and value.bool) else false;
    var pause_ms = fallback_pause_ms;
    if (outputs.object.get("pauseBetweenRunsMs")) |value| {
        // Clamped rather than taken as given: a gap of zero or less is a loop with no gap at all.
        switch (value) {
            .integer => |integer| {
                if (integer > 0) {
                    pause_ms = @intCast(integer);
                }
            },
            .float => |float| {
                if (float >= 1) {
                    pause_ms = @intFromFloat(float);
                }
            },
            else => {},
        }
    }
    return .{
        .should_run = should_run,
        .database_path = json_util.getString(outputs, "databasePath") orelse "",
        .reason = json_util.getString(outputs, "reason") orelse "",
        .pause_ms = pause_ms,
        .steps = steps.items,
    };
}

//
// What a finished pass says about what should happen next.
//
pub const PassOutcome = enum {
    // The pass ran, or tried to. Wait the gap and go again.
    ran,
    // The loop's work is over: automatic import is switched off, or the replica is complete. End the loop.
    stop,
};

//
// Reads the plan of a pass, reporting a failure to read it. A plan that cannot be read is not an answer of "stop": treating it as one
// would end the loop for good over a single failed task, so the caller counts the pass as run and the next one asks again.
//
fn readPlanOrReport(allocator: std.mem.Allocator, host: LoopHost, plan_task: []const u8, data: std.json.Value, fallback_pause_ms: u64, what: []const u8) ?IPlan {
    const outputs = host.readPlan(allocator, plan_task, data) catch |err| {
        const text = std.fmt.allocPrint(allocator, "Could not work out {s}: {s}", .{ what, describe(allocator, err) }) catch "Could not work out what to do.";
        host.reportError(text);
        return null;
    };
    return parsePlan(allocator, outputs, fallback_pause_ms) catch |err| {
        const text = std.fmt.allocPrint(allocator, "Could not work out {s}: {s}", .{ what, describe(allocator, err) }) catch "Could not work out what to do.";
        host.reportError(text);
        return null;
    };
}

//
// Runs the steps of a plan in order, with the CPU held awake for the length of the pass. Returns what the steps did, or null when the
// pass was abandoned: the loop was stopped, or a step did not work (which is reported). The rest of the pass is abandoned and not the
// loop: what failed is tried again on the next pass, from the plan.
//
fn runSteps(allocator: std.mem.Allocator, host: LoopHost, plan: IPlan, label: []const u8, results: *std.ArrayList(IStepResult)) bool {
    for (plan.steps) |step| {
        if (host.isStopped()) {
            return false;
        }
        const result = host.runStep(allocator, step) catch |err| {
            if (host.isStopped()) {
                return false;
            }
            host.reportError(std.fmt.allocPrint(allocator, "{s} step \"{s}\" failed: {s}", .{ label, step.@"type", describe(allocator, err) }) catch "A step failed.");
            return false;
        };
        if (!result.succeeded) {
            if (host.isStopped()) {
                return false;
            }
            host.reportError(std.fmt.allocPrint(allocator, "{s} step \"{s}\" did not succeed.", .{ label, step.@"type" }) catch "A step did not succeed.");
            return false;
        }
        results.append(allocator, result) catch {
            host.reportError("The loop ran out of memory.");
            return false;
        };
    }
    return true;
}

//
// One pass of the automatic import: asks the plan-auto-import task what to do and runs the tasks it hands back.
//
fn importPass(allocator: std.mem.Allocator, host: LoopHost, pause_ms: *u64) PassOutcome {
    const plan = readPlanOrReport(allocator, host, "plan-auto-import", .null, FALLBACK_PAUSE_MS, "what automatic import should do") orelse {
        return .ran;
    };
    pause_ms.* = plan.pause_ms;
    if (!plan.should_run) {
        host.report("Automatic import is switched off.");
        return .stop;
    }
    host.holdAwake(true) catch |err| {
        host.reportError(std.fmt.allocPrint(allocator, "Could not keep the phone awake for automatic import: {s}", .{describe(allocator, err)}) catch "Could not keep the phone awake.");
        return .ran;
    };
    defer host.holdAwake(false) catch |err| {
        host.reportError(std.fmt.allocPrint(allocator, "Could not let the phone sleep again after automatic import: {s}", .{describe(allocator, err)}) catch "Could not let the phone sleep again.");
    };
    host.report(std.fmt.allocPrint(allocator, "Automatic import running into \"{s}\".", .{plan.database_path}) catch "Automatic import running.");
    var results: std.ArrayList(IStepResult) = .empty;
    _ = runSteps(allocator, host, plan, "Automatic import", &results);
    return .ran;
}

//
// The automatic import loop. Runs passes until a plan says automatic import is switched off, or until the host says to stop.
//
// A pass that fails does not end the loop. The next one is scheduled anyway: an import can fail for a reason that has since gone (no
// space at that moment, a file being written as it was read), and giving up would leave automatic import switched on in the
// interface and doing nothing.
//
pub fn runImportLoop(allocator: std.mem.Allocator, host: LoopHost) void {
    var pause_ms: u64 = FALLBACK_PAUSE_MS;
    while (!host.isStopped()) {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const outcome = importPass(arena_state.allocator(), host, &pause_ms);
        if (outcome == .stop) {
            host.report("Automatic import is switched off. The sync loop carries on.");
            return;
        }
        if (host.isStopped()) {
            return;
        }
        if (!host.pause(pause_ms)) {
            return;
        }
    }
}

//
// The name a replica state has on the wire, which the sync plan reads. Lower case because it is a wire value, and a value the plan does
// not recognise is read as "unknown", which allows syncing: a value nobody understood must not be able to stop a phone syncing.
//
fn replicaStateName(state: ReplicaState) []const u8 {
    return @tagName(state);
}

//
// One pass of the sync: asks the plan-sync task whether a sync should run, and runs the tasks it hands back. What the prefetch is
// doing goes with the question, because a sync that runs while a prefetch is working does the same work slowly and gets in its own way.
//
fn syncPass(allocator: std.mem.Allocator, host: LoopHost, replica_state: *std.atomic.Value(ReplicaState), pause_ms: *u64) void {
    var request: std.json.ObjectMap = .empty;
    request.put(allocator, "prefetchState", .{
        .string = replicaStateName(replica_state.load(.acquire)),
    }) catch {
        host.reportError("The sync loop ran out of memory.");
        return;
    };
    const plan = readPlanOrReport(allocator, host, "plan-sync", .{ .object = request }, SYNC_FALLBACK_PAUSE_MS, "whether a sync should run") orelse {
        return;
    };
    pause_ms.* = plan.pause_ms;
    if (!plan.should_run) {
        host.report(std.fmt.allocPrint(allocator, "Not syncing: {s}", .{plan.reason}) catch "Not syncing.");
        return;
    }
    host.holdAwake(true) catch |err| {
        host.reportError(std.fmt.allocPrint(allocator, "Could not keep the phone awake for a sync: {s}", .{describe(allocator, err)}) catch "Could not keep the phone awake.");
        return;
    };
    defer host.holdAwake(false) catch |err| {
        host.reportError(std.fmt.allocPrint(allocator, "Could not let the phone sleep again after a sync: {s}", .{describe(allocator, err)}) catch "Could not let the phone sleep again.");
    };
    host.report(std.fmt.allocPrint(allocator, "Syncing \"{s}\".", .{plan.database_path}) catch "Syncing.");
    var results: std.ArrayList(IStepResult) = .empty;
    _ = runSteps(allocator, host, plan, "Sync", &results);
}

//
// The sync loop. Runs passes until the host says to stop. It never ends itself, because every reason a sync is refused can go away
// without the app being touched.
//
pub fn runSyncLoop(allocator: std.mem.Allocator, host: LoopHost, replica_state: *std.atomic.Value(ReplicaState)) void {
    var pause_ms: u64 = SYNC_FALLBACK_PAUSE_MS;
    while (!host.isStopped()) {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        syncPass(arena_state.allocator(), host, replica_state, &pause_ms);
        if (host.isStopped()) {
            return;
        }
        if (!host.pause(pause_ms)) {
            return;
        }
    }
}

//
// One pass of the prefetch: asks the plan-prefetch task whether a prefetch should run and runs the tasks it hands back. Records what
// the pass says about the replica for the sync loop, and says whether the replica is now complete.
//
fn prefetchPass(allocator: std.mem.Allocator, host: LoopHost, replica_state: *std.atomic.Value(ReplicaState), pause_ms: *u64) PassOutcome {
    const plan = readPlanOrReport(allocator, host, "plan-prefetch", .null, FALLBACK_PAUSE_MS, "what the background prefetch should do") orelse {
        return .ran;
    };
    pause_ms.* = plan.pause_ms;
    if (!plan.should_run) {
        // Refused, not finished. The loop keeps asking, because everything that refuses a pass can stop refusing without the app
        // being touched.
        host.report(std.fmt.allocPrint(allocator, "No database to fill in: {s}", .{plan.reason}) catch "No database to fill in.");
        return .ran;
    }
    host.holdAwake(true) catch |err| {
        host.reportError(std.fmt.allocPrint(allocator, "Could not keep the phone awake for the prefetch: {s}", .{describe(allocator, err)}) catch "Could not keep the phone awake.");
        return .ran;
    };
    defer host.holdAwake(false) catch |err| {
        host.reportError(std.fmt.allocPrint(allocator, "Could not let the phone sleep again after the prefetch: {s}", .{describe(allocator, err)}) catch "Could not let the phone sleep again.");
    };
    host.report(std.fmt.allocPrint(allocator, "Filling in \"{s}\".", .{plan.database_path}) catch "Filling in a replica.");

    var results: std.ArrayList(IStepResult) = .empty;
    if (!runSteps(allocator, host, plan, "Prefetch", &results)) {
        // Stalled, not complete. A step that failed tells us nothing about what is left, and a sync that waited on it would wait for
        // ever.
        if (!host.isStopped()) {
            replica_state.store(.stalled, .release);
        }
        return .ran;
    }

    var anything_fetched = false;
    var anything_left = false;
    for (results.items) |result| {
        if (result.files_fetched > 0) {
            anything_fetched = true;
        }
        if (result.files_still_missing > 0) {
            anything_left = true;
        }
    }
    if (!anything_fetched and !anything_left) {
        // Nothing fetched and nothing missing: the replica is complete and there is nothing left to walk. Opening a database starts
        // the loop again when there is a reason to.
        replica_state.store(.complete, .release);
        host.report(std.fmt.allocPrint(allocator, "\"{s}\" is filled in; nothing left to fetch.", .{plan.database_path}) catch "The replica is filled in; nothing left to fetch.");
        return .stop;
    }
    // Fetching anything at all counts as progress, including a pass that fetched files and found nothing left: the next pass confirms
    // that and reports the replica complete, so at worst a sync waits one more gap. Fetching nothing while files are still missing is
    // the stuck case, and it is the one a sync must not wait on.
    replica_state.store(if (anything_fetched) .working else .stalled, .release);
    return .ran;
}

//
// The prefetch loop. Runs passes until one reports the replica complete, or until the host says to stop.
//
// A pass that fails does not end the loop. The next one is scheduled anyway: a file can fail to copy for a reason that has since gone,
// and this loop exists precisely because a prefetch that gave up was never tried again. It ends itself when the replica is complete,
// because asking again would walk every object at the origin every gap, and is started again when a database is opened.
//
pub fn runPrefetchLoop(allocator: std.mem.Allocator, host: LoopHost, replica_state: *std.atomic.Value(ReplicaState)) void {
    var pause_ms: u64 = FALLBACK_PAUSE_MS;
    while (!host.isStopped()) {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const outcome = prefetchPass(arena_state.allocator(), host, replica_state, &pause_ms);
        if (outcome == .stop) {
            host.report("The replica is filled in, so the background prefetch loop has finished. Opening a database starts it again.");
            return;
        }
        if (host.isStopped()) {
            return;
        }
        if (!host.pause(pause_ms)) {
            return;
        }
    }
}

//
// Reads what a prefetch step did out of the outputs of its task. A task that returned nothing is read as a pass that fetched nothing
// and left nothing, which is what a prefetch against a full database returns and is the answer that ends the loop.
//
pub fn readPrefetchStepCounts(outputs: ?std.json.Value) IStepResult {
    var result: IStepResult = .{
        .succeeded = true,
        .files_fetched = 0,
        .files_still_missing = 0,
    };
    const value = outputs orelse {
        return result;
    };
    if (json_util.getInteger(value, "filesFetched")) |fetched| {
        if (fetched > 0) {
            result.files_fetched = @intCast(fetched);
        }
    }
    if (json_util.getInteger(value, "filesStillMissing")) |missing| {
        if (missing > 0) {
            result.files_still_missing = @intCast(missing);
        }
    }
    return result;
}

//
// The loop host of a loop that runs as a task: its steps are child tasks of the loop's own task, so they take its source and are
// cancelled with it, and the platform is reached through the shell's host requests.
//
const TaskLoopHost = struct {
    // The context of the loop's task.
    context: *TaskContext,
    // Which loop this is.
    loop: Loop,

    const vtable: LoopHost.VTable = .{
        .readPlan = readPlanErased,
        .runStep = runStepErased,
        .pause = pauseErased,
        .holdAwake = holdAwakeErased,
        .report = reportErased,
        .reportError = reportErrorErased,
        .isStopped = isStoppedErased,
    };

    fn host(self: *TaskLoopHost) LoopHost {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // Runs a child task and waits for it, keeping nothing of it once it has ended: a loop runs for as long as the phone is switched on, so
    // what each pass queued must not pile up until it ends. The completion is allocated with the allocator, which is the pass's. A child
    // that did not succeed is returned as its completion, for the caller to decide on.
    //
    fn runChild(self: *TaskLoopHost, allocator: std.mem.Allocator, task_type: []const u8, data: std.json.Value) !ziggy.types.Completion {
        return try self.context.runChild(allocator, task_type, data, null);
    }

    fn readPlanErased(ptr: *anyopaque, allocator: std.mem.Allocator, plan_task: []const u8, data: std.json.Value) anyerror!std.json.Value {
        const self: *TaskLoopHost = @ptrCast(@alignCast(ptr));
        const completion = try self.runChild(allocator, plan_task, data);
        if (completion.status != .succeeded) {
            return utils.errors.throwError("{s} failed: {s}", .{ plan_task, completion.error_message orelse "no reason given" });
        }
        const text = completion.result_json orelse {
            return utils.errors.throwError("{s} returned nothing.", .{plan_task});
        };
        return try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
    }

    fn runStepErased(ptr: *anyopaque, allocator: std.mem.Allocator, step: IStep) anyerror!IStepResult {
        const self: *TaskLoopHost = @ptrCast(@alignCast(ptr));
        const completion = try self.runChild(allocator, step.@"type", step.data);
        if (completion.status != .succeeded) {
            if (!self.context.isCancelled()) {
                self.reportErrorMessage(std.fmt.allocPrint(allocator, "Background {s} task \"{s}\" failed: {s}", .{ self.loop.label(), step.@"type", completion.error_message orelse "no reason given" }) catch "A background task failed.");
            }
            return .{
                .succeeded = false,
                .files_fetched = 0,
                .files_still_missing = 0,
            };
        }
        if (self.loop != .prefetch) {
            return .{
                .succeeded = true,
                .files_fetched = 0,
                .files_still_missing = 0,
            };
        }
        const outputs: ?std.json.Value = if (completion.result_json) |text| try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{}) else null;
        return readPrefetchStepCounts(outputs);
    }

    fn pauseErased(ptr: *anyopaque, millis: u64) bool {
        const self: *TaskLoopHost = @ptrCast(@alignCast(ptr));
        var waited: u64 = 0;
        while (waited < millis) {
            if (self.context.isCancelled()) {
                return false;
            }
            const slice = @min(PAUSE_SLICE_MS, millis - waited);
            utils.sleep.sleep(self.context.io(), slice) catch |err| {
                self.reportErrorMessage(std.fmt.allocPrint(self.context.arena, "The background work could not wait between passes, so it stops: {s}", .{utils.errors.errorMessage(err)}) catch "The background work could not wait between passes, so it stops.");
                return false;
            };
            waited += slice;
        }
        return !self.context.isCancelled();
    }

    fn holdAwakeErased(ptr: *anyopaque, awake: bool) anyerror!void {
        const self: *TaskLoopHost = @ptrCast(@alignCast(ptr));
        _ = try askShell(self.context, "holdAwake", try json_util.stringify(self.context.arena, .{
            .awake = awake,
        }));
    }

    fn reportErased(ptr: *anyopaque, message: []const u8) void {
        const self: *TaskLoopHost = @ptrCast(@alignCast(ptr));
        self.tellShell(message, false);
    }

    fn reportErrorErased(ptr: *anyopaque, message: []const u8) void {
        const self: *TaskLoopHost = @ptrCast(@alignCast(ptr));
        self.tellShell(message, true);
    }

    fn reportErrorMessage(self: *TaskLoopHost, message: []const u8) void {
        self.tellShell(message, true);
    }

    fn isStoppedErased(ptr: *anyopaque) bool {
        const self: *TaskLoopHost = @ptrCast(@alignCast(ptr));
        return self.context.isCancelled();
    }

    //
    // Tells the shell what the loop is doing, for the system log. A shell that cannot take it is not allowed to make the loop's
    // report vanish, so the message goes to the app's own log with the reason.
    //
    fn tellShell(self: *TaskLoopHost, message: []const u8, is_error: bool) void {
        const request = json_util.stringify(self.context.arena, .{
            .@"error" = is_error,
            .message = message,
        }) catch {
            utils.log.log.@"error"(message);
            return;
        };
        _ = askShell(self.context, "backgroundLog", request) catch |err| {
            utils.log.log.@"error"(std.fmt.allocPrint(self.context.arena, "The background work could not tell the system log \"{s}\": {s}", .{ message, utils.errors.errorMessage(err) }) catch message);
        };
    }
};

//
// Asks the shell to do what the method names, and returns its answer, which is JSON text. A platform without the callback and a shell
// that cannot do it are each an error with a sentence the user can act on.
//
pub fn askShell(context: *TaskContext, method: []const u8, request_json: []const u8) ![]const u8 {
    const reply = context.hostRequest(method, request_json) catch |err| {
        if (err == error.HostCallbackMissing) {
            return utils.errors.throwError("{s} is only available in the Photosphere app on a phone.", .{method});
        }
        return err;
    };
    if (!reply.succeeded) {
        return utils.errors.throwError("{s}", .{reply.text});
    }
    return reply.text;
}

//
// The task that is the automatic import loop. Ends when a plan says automatic import is switched off, or when it is cancelled.
//
pub fn autoImportLoopTask(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    var loop_host: TaskLoopHost = .{
        .context = context,
        .loop = .import,
    };
    runImportLoop(std.heap.smp_allocator, loop_host.host());
    return try context.arena.dupe(u8, "null");
}

//
// The task that is the sync loop. Ends only when it is cancelled.
//
pub fn syncLoopTask(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    var loop_host: TaskLoopHost = .{
        .context = context,
        .loop = .sync,
    };
    runSyncLoop(std.heap.smp_allocator, loop_host.host(), &main_state.fromContext(context).prefetch_replica_state);
    return try context.arena.dupe(u8, "null");
}

//
// The task that is the prefetch loop. Ends when a pass finds the replica complete, or when it is cancelled.
//
pub fn prefetchLoopTask(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    var loop_host: TaskLoopHost = .{
        .context = context,
        .loop = .prefetch,
    };
    runPrefetchLoop(std.heap.smp_allocator, loop_host.host(), &main_state.fromContext(context).prefetch_replica_state);
    return try context.arena.dupe(u8, "null");
}

//
// Starts the loops that are not already running. Starting one that is running does nothing, and a loop that ended (the import loop
// when automatic import was switched off, the prefetch loop when its replica was complete) is started again, which is how switching
// the feature back on, or opening a database, brings it back.
//
pub fn startBackgroundWork(context: *TaskContext) !void {
    const state = main_state.fromContext(context);
    inline for (std.meta.fields(Loop)) |field| {
        const loop: Loop = @enumFromInt(field.value);
        if (state.claimBackgroundLoop(loop)) {
            errdefer state.releaseBackgroundLoop(loop);
            const task_id = try state.uuid_generator.generate(context.arena, context.io());
            try state.core.runner.addTask(task_id, loop.taskType(), loop.source(), "null", .background, null);
        }
    }
}

//
// Stops the loops and the passes they are in, and does nothing for a loop that is not running.
//
pub fn stopBackgroundWork(context: *TaskContext) void {
    const state = main_state.fromContext(context);
    inline for (std.meta.fields(Loop)) |field| {
        const loop: Loop = @enumFromInt(field.value);
        state.core.runner.cancelSource(loop.source());
    }
}
