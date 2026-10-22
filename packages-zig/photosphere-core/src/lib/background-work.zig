//
// The background work: the automatic import, the sync and the prefetch of a partial replica. Each is a pass that asks a planning task
// what to do, runs the tasks the plan hands back one after another, and ends. A pass with nothing to do ends straight away.
//
// A pass never waits for the next one: it holds a worker thread only while it works. The core's timer starts the next pass when the gap
// the plan asked for is up (see MainState.runDueTimers). startBackgroundWork, which the page's startBackgroundImport request calls,
// switches the work on, and stopBackgroundWork, which its stopBackgroundImport request calls, switches it off.
//
// While any of the work is switched on the core holds the app running (on Android a foreground service with its notification), so the
// timer goes on starting passes with the app off screen. Each pass is also a task whose type is registered as keep-alive.
//
// The decisions of a pass are in the functions that take a PassHost, a plain interface over everything that needs the platform or the
// core, so they are tested with no core and no phone. The passes report what they are doing to the shell, which writes it to the
// system log: the app's own log file is written through the page, which is suspended exactly when this work matters.
//

const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const main_state = @import("main-state.zig");

const TaskContext = ziggy.task_runner.TaskContext;
const json = ziggy.json;

//
// The gap between automatic import or prefetch passes when no plan has said what it should be, in milliseconds.
//
// Only reached when a plan cannot be read, because every plan carries a gap that the settings file resolves. It exists because a gap
// of zero is not a gap: the timer would start a pass, the pass would fail to read a plan, and the next would start as fast as it could.
//
pub const FALLBACK_PAUSE_MS: u64 = 30_000;

//
// The gap between sync passes when no plan has said what it should be, in milliseconds.
//
pub const SYNC_FALLBACK_PAUSE_MS: u64 = 5 * 60 * 1000;

//
// The three passes.
//
pub const Pass = enum {
    // Automatic import: takes new photos from the device library into the default database.
    import,
    // Sync: pushes the database the user works in to its origin.
    sync,
    // Prefetch: fills in the thumbnails and index files a partial replica is missing.
    prefetch,

    //
    // The task type the pass runs as.
    //
    pub fn taskType(self: Pass) []const u8 {
        return switch (self) {
            .import => "background-auto-import",
            .sync => "background-sync",
            .prefetch => "background-prefetch",
        };
    }

    //
    // The source the pass and every task it starts are queued under, so one cancellation stops the pass and what it started.
    //
    pub fn source(self: Pass) []const u8 {
        return switch (self) {
            .import => "auto-import",
            .sync => "background-sync",
            .prefetch => "background-prefetch",
        };
    }

    //
    // What the pass's tasks are called in the messages about them.
    //
    pub fn label(self: Pass) []const u8 {
        return switch (self) {
            .import => "import",
            .sync => "sync",
            .prefetch => "prefetch",
        };
    }

    //
    // The pass that runs as a task type, or null when the type is not a pass's.
    //
    pub fn fromTaskType(task_type: []const u8) ?Pass {
        inline for (std.meta.fields(Pass)) |field| {
            const pass: Pass = @enumFromInt(field.value);
            if (std.mem.eql(u8, pass.taskType(), task_type)) {
                return pass;
            }
        }
        return null;
    }
};

//
// How many passes there are.
//
pub const PASS_COUNT = std.meta.fields(Pass).len;

//
// What a finished pass says should happen next.
//
pub const IPassResult = struct {
    // How long to wait before the next pass, in milliseconds.
    gap_ms: u64,
    // Whether the work is over until it is switched on again: automatic import is switched off, or the replica is complete.
    finished: bool,
};

//
// What the last completed prefetch pass says about the replica, for the sync pass, which holds back while a prefetch is making
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
    // The last pass fetched nothing and found nothing missing: the replica is filled in and the prefetch has finished. Syncing is allowed.
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
    // Whether the step succeeded. A step that failed leaves the work switched on, because what would not work is tried again on the
    // next pass.
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
// Everything a pass needs that it cannot do itself: running the planning task and the steps, keeping the CPU awake, and saying what
// happened. An interface so the passes' decisions are tested with no core and no phone.
//
pub const PassHost = struct {
    // The implementation.
    ptr: *anyopaque,
    // The implementation's functions.
    vtable: *const VTable,

    //
    // The functions an implementation provides.
    //
    pub const VTable = struct {
        // Runs the planning task and returns its outputs. Fails when the task fails, which the pass treats as a pass that did not work
        // rather than as a reason to give up.
        readPlan: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, plan_task: []const u8, data: std.json.Value) anyerror!std.json.Value,
        // Runs one step and waits for it to finish.
        runStep: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, step: IStep) anyerror!IStepResult,
        // Keeps the CPU running while a pass is in flight, and lets it sleep again afterwards.
        holdAwake: *const fn (ptr: *anyopaque, awake: bool) anyerror!void,
        // Says what the pass is doing.
        report: *const fn (ptr: *anyopaque, message: []const u8) void,
        // Says what went wrong.
        reportError: *const fn (ptr: *anyopaque, message: []const u8) void,
        // Whether the pass has been told to stop.
        isStopped: *const fn (ptr: *anyopaque) bool,
    };

    fn readPlan(self: PassHost, allocator: std.mem.Allocator, plan_task: []const u8, data: std.json.Value) !std.json.Value {
        return try self.vtable.readPlan(self.ptr, allocator, plan_task, data);
    }

    fn runStep(self: PassHost, allocator: std.mem.Allocator, step: IStep) !IStepResult {
        return try self.vtable.runStep(self.ptr, allocator, step);
    }

    fn holdAwake(self: PassHost, awake: bool) !void {
        try self.vtable.holdAwake(self.ptr, awake);
    }

    fn report(self: PassHost, message: []const u8) void {
        self.vtable.report(self.ptr, message);
    }

    fn reportError(self: PassHost, message: []const u8) void {
        self.vtable.reportError(self.ptr, message);
    }

    fn isStopped(self: PassHost) bool {
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
                const step_type = json.getString(item, "type") orelse {
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
        .database_path = json.getString(outputs, "databasePath") orelse "",
        .reason = json.getString(outputs, "reason") orelse "",
        .pause_ms = pause_ms,
        .steps = steps.items,
    };
}

//
// Reads the plan of a pass, reporting a failure to read it. A plan that cannot be read is not an answer of "finished": treating it as
// one would switch the work off for good over a single failed task, so the caller counts the pass as run and the next one asks again.
//
fn readPlanOrReport(allocator: std.mem.Allocator, host: PassHost, plan_task: []const u8, data: std.json.Value, fallback_pause_ms: u64, what: []const u8) ?IPlan {
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
// How running the steps of a pass ended.
//
const StepsOutcome = enum {
    // Every step succeeded.
    completed,
    // The pass was stopped before a step started.
    stopped,
    // A step failed or did not succeed, which is reported.
    failed,
};

//
// Runs the steps of a plan in order, with the CPU held awake for the length of the pass, collecting what each did into results. The
// rest of the pass is abandoned when the pass is stopped before a step or a step does not work: what failed is tried again on the next
// pass, from the plan. A step that does not work is reported even when the pass is being stopped, because a stop cancels the step and
// says nothing about why it ended.
//
fn runSteps(allocator: std.mem.Allocator, host: PassHost, plan: IPlan, label: []const u8, results: *std.ArrayList(IStepResult)) StepsOutcome {
    for (plan.steps) |step| {
        if (host.isStopped()) {
            return .stopped;
        }
        const result = host.runStep(allocator, step) catch |err| {
            host.reportError(std.fmt.allocPrint(allocator, "{s} step \"{s}\" failed: {s}", .{ label, step.@"type", describe(allocator, err) }) catch "A step failed.");
            return .failed;
        };
        if (!result.succeeded) {
            host.reportError(std.fmt.allocPrint(allocator, "{s} step \"{s}\" did not succeed.", .{ label, step.@"type" }) catch "A step did not succeed.");
            return .failed;
        }
        results.append(allocator, result) catch {
            host.reportError("The pass ran out of memory.");
            return .failed;
        };
    }
    return .completed;
}

//
// One pass of the automatic import: asks the plan-auto-import task what to do and runs the tasks it hands back. Finished when the plan
// says automatic import is switched off.
//
// A pass that fails does not finish the work. The next one runs anyway: an import can fail for a reason that has since gone (no space
// at that moment, a file being written as it was read), and giving up would leave automatic import switched on in the interface and
// doing nothing.
//
pub fn runImportPass(allocator: std.mem.Allocator, host: PassHost) IPassResult {
    const plan = readPlanOrReport(allocator, host, "plan-auto-import", .null, FALLBACK_PAUSE_MS, "what automatic import should do") orelse {
        return .{
            .gap_ms = FALLBACK_PAUSE_MS,
            .finished = false,
        };
    };
    const ran: IPassResult = .{
        .gap_ms = plan.pause_ms,
        .finished = false,
    };
    if (!plan.should_run) {
        host.report("Automatic import is switched off.");
        return .{
            .gap_ms = plan.pause_ms,
            .finished = true,
        };
    }
    host.holdAwake(true) catch |err| {
        host.reportError(std.fmt.allocPrint(allocator, "Could not keep the phone awake for automatic import: {s}", .{describe(allocator, err)}) catch "Could not keep the phone awake.");
        return ran;
    };
    defer host.holdAwake(false) catch |err| {
        host.reportError(std.fmt.allocPrint(allocator, "Could not let the phone sleep again after automatic import: {s}", .{describe(allocator, err)}) catch "Could not let the phone sleep again.");
    };
    host.report(std.fmt.allocPrint(allocator, "Automatic import running into \"{s}\".", .{plan.database_path}) catch "Automatic import running.");
    var results: std.ArrayList(IStepResult) = .empty;
    _ = runSteps(allocator, host, plan, "Automatic import", &results);
    return ran;
}

//
// The name a replica state has on the wire, which the sync plan reads. Lower case because it is a wire value, and a value the plan does
// not recognise is read as "unknown", which allows syncing: a value nobody understood must not be able to stop a phone syncing.
//
fn replicaStateName(state: ReplicaState) []const u8 {
    return @tagName(state);
}

//
// Asks the plan-sync task whether a sync should run. What the prefetch is doing goes with the question, because a sync that runs while
// a prefetch is working does the same work slowly and gets in its own way.
//
fn readSyncPlan(allocator: std.mem.Allocator, host: PassHost, replica_state: *std.atomic.Value(ReplicaState)) ?IPlan {
    var request: std.json.ObjectMap = .empty;
    request.put(allocator, "prefetchState", .{
        .string = replicaStateName(replica_state.load(.acquire)),
    }) catch {
        host.reportError("The sync pass ran out of memory.");
        return null;
    };
    return readPlanOrReport(allocator, host, "plan-sync", .{ .object = request }, SYNC_FALLBACK_PAUSE_MS, "whether a sync should run");
}

//
// One pass of the sync: asks the plan-sync task whether a sync should run, and runs the tasks it hands back. Never finished, because
// every reason a sync is refused can go away without the app being touched.
//
// The first pass after the work is switched on only reads the gap, so the first sync waits the configured pause too. The work is switched
// on when a database is opened, and a sync at that moment would push a database the user has only just opened, racing whatever they do
// to it next. The pause is a setting only the plan reads.
//
pub fn runSyncPass(allocator: std.mem.Allocator, host: PassHost, replica_state: *std.atomic.Value(ReplicaState), first: bool) IPassResult {
    const plan = readSyncPlan(allocator, host, replica_state) orelse {
        return .{
            .gap_ms = SYNC_FALLBACK_PAUSE_MS,
            .finished = false,
        };
    };
    const ran: IPassResult = .{
        .gap_ms = plan.pause_ms,
        .finished = false,
    };
    if (first) {
        return ran;
    }
    if (!plan.should_run) {
        host.report(std.fmt.allocPrint(allocator, "Not syncing: {s}", .{plan.reason}) catch "Not syncing.");
        return ran;
    }
    host.holdAwake(true) catch |err| {
        host.reportError(std.fmt.allocPrint(allocator, "Could not keep the phone awake for a sync: {s}", .{describe(allocator, err)}) catch "Could not keep the phone awake.");
        return ran;
    };
    defer host.holdAwake(false) catch |err| {
        host.reportError(std.fmt.allocPrint(allocator, "Could not let the phone sleep again after a sync: {s}", .{describe(allocator, err)}) catch "Could not let the phone sleep again.");
    };
    host.report(std.fmt.allocPrint(allocator, "Syncing \"{s}\".", .{plan.database_path}) catch "Syncing.");
    var results: std.ArrayList(IStepResult) = .empty;
    _ = runSteps(allocator, host, plan, "Sync", &results);
    return ran;
}

//
// One pass of the prefetch: asks the plan-prefetch task whether a prefetch should run and runs the tasks it hands back. Records what
// the pass says about the replica for the sync pass. Finished when the replica is complete, because asking again would walk every
// object at the origin every gap. Opening a database switches it on again.
//
// A pass that fails does not finish the work. The next one runs anyway: a file can fail to copy for a reason that has since gone, and
// these passes exist precisely because a prefetch that gave up was never tried again.
//
pub fn runPrefetchPass(allocator: std.mem.Allocator, host: PassHost, replica_state: *std.atomic.Value(ReplicaState)) IPassResult {
    const plan = readPlanOrReport(allocator, host, "plan-prefetch", .null, FALLBACK_PAUSE_MS, "what the background prefetch should do") orelse {
        return .{
            .gap_ms = FALLBACK_PAUSE_MS,
            .finished = false,
        };
    };
    const ran: IPassResult = .{
        .gap_ms = plan.pause_ms,
        .finished = false,
    };
    if (!plan.should_run) {
        // Refused, not finished. The next pass asks again, because everything that refuses a pass can stop refusing without the app
        // being touched.
        host.report(std.fmt.allocPrint(allocator, "No database to fill in: {s}", .{plan.reason}) catch "No database to fill in.");
        return ran;
    }
    host.holdAwake(true) catch |err| {
        host.reportError(std.fmt.allocPrint(allocator, "Could not keep the phone awake for the prefetch: {s}", .{describe(allocator, err)}) catch "Could not keep the phone awake.");
        return ran;
    };
    defer host.holdAwake(false) catch |err| {
        host.reportError(std.fmt.allocPrint(allocator, "Could not let the phone sleep again after the prefetch: {s}", .{describe(allocator, err)}) catch "Could not let the phone sleep again.");
    };
    host.report(std.fmt.allocPrint(allocator, "Filling in \"{s}\".", .{plan.database_path}) catch "Filling in a replica.");

    var results: std.ArrayList(IStepResult) = .empty;
    switch (runSteps(allocator, host, plan, "Prefetch", &results)) {
        .completed => {},
        .stopped => {
            return ran;
        },
        .failed => {
            // Stalled, not complete. A step that failed tells us nothing about what is left, and a sync that waited on it would wait
            // for ever.
            replica_state.store(.stalled, .release);
            return ran;
        },
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
        // Nothing fetched and nothing missing: the replica is complete and there is nothing left to walk. Opening a database switches
        // the prefetch on again when there is a reason to.
        replica_state.store(.complete, .release);
        host.report(std.fmt.allocPrint(allocator, "\"{s}\" is filled in; nothing left to fetch.", .{plan.database_path}) catch "The replica is filled in; nothing left to fetch.");
        return .{
            .gap_ms = plan.pause_ms,
            .finished = true,
        };
    }
    // Fetching anything at all counts as progress, including a pass that fetched files and found nothing left: the next pass confirms
    // that and reports the replica complete, so at worst a sync waits one more gap. Fetching nothing while files are still missing is
    // the stuck case, and it is the one a sync must not wait on.
    replica_state.store(if (anything_fetched) .working else .stalled, .release);
    return ran;
}

//
// Reads what a prefetch step did out of the outputs of its task. A task that returned nothing is read as a pass that fetched nothing
// and left nothing, which is what a prefetch against a full database returns and is the answer that finishes the prefetch.
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
    if (json.getInteger(value, "filesFetched")) |fetched| {
        if (fetched > 0) {
            result.files_fetched = @intCast(fetched);
        }
    }
    if (json.getInteger(value, "filesStillMissing")) |missing| {
        if (missing > 0) {
            result.files_still_missing = @intCast(missing);
        }
    }
    return result;
}

//
// The host of a pass that runs as a task: its steps are child tasks of the pass's own task, so they take its source and are cancelled
// with it, and the platform is reached through the shell's host requests.
//
const TaskPassHost = struct {
    // The context of the pass's task.
    context: *TaskContext,
    // Which pass this is.
    pass: Pass,

    const vtable: PassHost.VTable = .{
        .readPlan = readPlanErased,
        .runStep = runStepErased,
        .holdAwake = holdAwakeErased,
        .report = reportErased,
        .reportError = reportErrorErased,
        .isStopped = isStoppedErased,
    };

    fn host(self: *TaskPassHost) PassHost {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // Runs a child task and waits for it. The completion is allocated with the allocator, which is the pass's. A child that did not
    // succeed is returned as its completion, for the caller to decide on.
    //
    fn runChild(self: *TaskPassHost, allocator: std.mem.Allocator, task_type: []const u8, data: std.json.Value) !ziggy.types.Completion {
        return try self.context.runChild(allocator, task_type, data, null);
    }

    fn readPlanErased(ptr: *anyopaque, allocator: std.mem.Allocator, plan_task: []const u8, data: std.json.Value) anyerror!std.json.Value {
        const self: *TaskPassHost = @ptrCast(@alignCast(ptr));
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
        const self: *TaskPassHost = @ptrCast(@alignCast(ptr));
        const completion = try self.runChild(allocator, step.@"type", step.data);
        if (completion.status != .succeeded) {
            self.reportErrorMessage(std.fmt.allocPrint(allocator, "Background {s} task \"{s}\" failed: {s}", .{ self.pass.label(), step.@"type", completion.error_message orelse "no reason given" }) catch "A background task failed.");
            return .{
                .succeeded = false,
                .files_fetched = 0,
                .files_still_missing = 0,
            };
        }
        if (self.pass != .prefetch) {
            return .{
                .succeeded = true,
                .files_fetched = 0,
                .files_still_missing = 0,
            };
        }
        const outputs: ?std.json.Value = if (completion.result_json) |text| try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{}) else null;
        return readPrefetchStepCounts(outputs);
    }

    fn holdAwakeErased(ptr: *anyopaque, awake: bool) anyerror!void {
        const self: *TaskPassHost = @ptrCast(@alignCast(ptr));
        _ = try askShell(self.context, "holdAwake", try json.stringify(self.context.arena, .{
            .awake = awake,
        }));
    }

    fn reportErased(ptr: *anyopaque, message: []const u8) void {
        const self: *TaskPassHost = @ptrCast(@alignCast(ptr));
        self.tellShell(message, false);
    }

    fn reportErrorErased(ptr: *anyopaque, message: []const u8) void {
        const self: *TaskPassHost = @ptrCast(@alignCast(ptr));
        self.tellShell(message, true);
    }

    fn reportErrorMessage(self: *TaskPassHost, message: []const u8) void {
        self.tellShell(message, true);
    }

    fn isStoppedErased(ptr: *anyopaque) bool {
        const self: *TaskPassHost = @ptrCast(@alignCast(ptr));
        return self.context.isCancelled();
    }

    //
    // Tells the shell what the pass is doing, for the system log. A shell that cannot take it is not allowed to make the pass's
    // report vanish, so the message goes to the app's own log with the reason.
    //
    fn tellShell(self: *TaskPassHost, message: []const u8, is_error: bool) void {
        const request = json.stringify(self.context.arena, .{
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
            return try answerWithoutShell(context, method, request_json);
        }
        return err;
    };
    if (!reply.succeeded) {
        return utils.errors.throwError("{s}", .{reply.text});
    }
    return reply.text;
}

//
// Answers a host request when the shell has no host request callback. Ziggy's Windows shell and MacOS bridge have none, so on Windows
// and MacOS the core answers the requests a desktop can itself (windows-host.zig, macos-host.zig). Anywhere else, and for a request only
// a phone can answer, it is an error that says so.
//
pub fn answerWithoutShell(context: *TaskContext, method: []const u8, request_json: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        if (try main_state.fromContext(context).windows_host.answer(context.arena, method, request_json)) |answer| {
            return answer;
        }
    }
    if (builtin.os.tag == .macos) {
        if (try main_state.fromContext(context).macos_host.answer(context.arena, method, request_json)) |answer| {
            return answer;
        }
    }
    return utils.errors.throwError("{s} is only available in the Photosphere app on a phone.", .{method});
}

//
// Runs one pass in the task's own context, and records when the next one is due.
//
fn runPass(context: *TaskContext, pass: Pass) void {
    const state = main_state.fromContext(context);
    var pass_host: TaskPassHost = .{
        .context = context,
        .pass = pass,
    };
    const result = switch (pass) {
        .import => runImportPass(context.arena, pass_host.host()),
        .sync => runSyncPass(context.arena, pass_host.host(), &state.prefetch_replica_state, state.takeFirstSyncPass()),
        .prefetch => runPrefetchPass(context.arena, pass_host.host(), &state.prefetch_replica_state),
    };
    state.backgroundPassEnded(pass, result);
}

//
// The task that is one pass of the automatic import.
//
pub fn autoImportPassTask(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    runPass(context, .import);
    return try context.arena.dupe(u8, "null");
}

//
// The task that is one pass of the sync.
//
pub fn syncPassTask(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    runPass(context, .sync);
    return try context.arena.dupe(u8, "null");
}

//
// The task that is one pass of the prefetch.
//
pub fn prefetchPassTask(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    runPass(context, .prefetch);
    return try context.arena.dupe(u8, "null");
}

//
// Switches the background work on. Each pass that was off is due at once, and the core's timer starts it. Switching on a pass that is
// already on changes nothing, and a pass that finished (the import when automatic import was switched off, the prefetch when its
// replica was complete) is switched on again, which is how switching the feature back on, or opening a database, brings it back.
//
pub fn startBackgroundWork(context: *TaskContext) void {
    const state = main_state.fromContext(context);
    inline for (std.meta.fields(Pass)) |field| {
        const pass: Pass = @enumFromInt(field.value);

        // A desktop imports by watching folders (ensureAutoImport), so a second import here would import everything twice.
        if (pass == .import and builtin.os.tag != .ios and !builtin.abi.isAndroid()) {
            continue;
        }
        state.switchOnBackgroundPass(pass);
    }
}

//
// Switches the background work off and stops the passes in flight.
//
pub fn stopBackgroundWork(context: *TaskContext) void {
    const state = main_state.fromContext(context);
    state.switchOffBackgroundPasses();
    inline for (std.meta.fields(Pass)) |field| {
        const pass: Pass = @enumFromInt(field.value);
        state.core.runner.cancelSource(pass.source());
    }
}
