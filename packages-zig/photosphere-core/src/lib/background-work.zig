//
// The background work: the automatic import, the sync and the prefetch of a partial replica. Each is a pass that asks a planning task
// what to do, runs the tasks the plan hands back one after another, and ends. A pass with nothing to do ends straight away.
//
// A pass never waits for the next one: it holds a worker thread only while it works. The core's timer starts the next pass when the gap
// the plan set is up (see MainState). MainState.startBackgroundWork, which the page's startBackgroundImport request calls,
// switches the work on, and MainState.stopBackgroundWork, which its stopBackgroundImport request calls, switches it off.
// The main thread gives each pass task what it needs in its data and records how it ended from its result.
//
// While any of the work is switched on the core holds the app running (on Android a foreground service with its notification), so the
// timer goes on starting passes with the app off screen. Each pass is also a task whose type is registered as keep-alive.
//
// The decisions of a pass are in the functions that take a PassServices, a plain interface over everything that needs the platform or the
// core, so they are tested with no core and no phone. The passes report what they are doing to the native app, which writes it to the
// system log: the app's own log file is written through the page, which is suspended exactly when this work matters.
//

const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const windows_native_calls = @import("windows-native-calls.zig");
const macos_native_calls = @import("macos-native-calls.zig");

const TaskContext = ziggy.task_runner.TaskContext;
const TaskServices = ziggy.task_runner.TaskServices;
const HandlerServices = ziggy.core.HandlerServices;
const Timers = ziggy.timers.Timers;
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
pub const PassServices = struct {
    // The implementation.
    ptr: *anyopaque,
    // The implementation's functions.
    vtable: *const VTable,

    //
    // The functions an implementation provides.
    //
    // Each is given the Io, the allocator, which is the pass's, and the timers of the pass's thread.
    pub const VTable = struct {
        // Runs the planning task and returns its outputs. Fails when the task fails, which the pass treats as a pass that did not work
        // rather than as a reason to give up.
        readPlan: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, plan_task: []const u8, data: std.json.Value) anyerror!std.json.Value,
        // Runs one step of the pass and waits for it to finish.
        runStep: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, pass: Pass, step: IStep) anyerror!IStepResult,
        // Keeps the CPU running while a pass is in flight, and lets it sleep again afterwards.
        holdAwake: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, awake: bool) anyerror!void,
        // Says what the pass is doing.
        report: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, message: []const u8) void,
        // Says what went wrong.
        reportError: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, message: []const u8) void,
        // Whether the pass has been told to stop.
        isStopped: *const fn (ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) bool,
    };

    fn readPlan(self: PassServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers, plan_task: []const u8, data: std.json.Value) !std.json.Value {
        return try self.vtable.readPlan(self.ptr, io, allocator, timers, plan_task, data);
    }

    fn runStep(self: PassServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers, pass: Pass, step: IStep) !IStepResult {
        return try self.vtable.runStep(self.ptr, io, allocator, timers, pass, step);
    }

    fn holdAwake(self: PassServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers, awake: bool) !void {
        try self.vtable.holdAwake(self.ptr, io, allocator, timers, awake);
    }

    fn report(self: PassServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers, message: []const u8) void {
        self.vtable.report(self.ptr, io, allocator, timers, message);
    }

    fn reportError(self: PassServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers, message: []const u8) void {
        self.vtable.reportError(self.ptr, io, allocator, timers, message);
    }

    fn isStopped(self: PassServices, io: std.Io, allocator: std.mem.Allocator) bool {
        return self.vtable.isStopped(self.ptr, io, allocator);
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
fn readPlanOrReport(io: std.Io, allocator: std.mem.Allocator, timers: Timers, pass_services: PassServices, plan_task: []const u8, data: std.json.Value, fallback_pause_ms: u64, what: []const u8) ?IPlan {
    const outputs = pass_services.readPlan(io, allocator, timers, plan_task, data) catch |err| {
        const text = std.fmt.allocPrint(allocator, "Could not work out {s}: {s}", .{ what, describe(allocator, err) }) catch "Could not work out what to do.";
        pass_services.reportError(io, allocator, timers, text);
        return null;
    };
    return parsePlan(allocator, outputs, fallback_pause_ms) catch |err| {
        const text = std.fmt.allocPrint(allocator, "Could not work out {s}: {s}", .{ what, describe(allocator, err) }) catch "Could not work out what to do.";
        pass_services.reportError(io, allocator, timers, text);
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
fn runSteps(io: std.Io, allocator: std.mem.Allocator, timers: Timers, pass_services: PassServices, pass: Pass, plan: IPlan, label: []const u8, results: *std.ArrayList(IStepResult)) StepsOutcome {
    for (plan.steps) |step| {
        if (pass_services.isStopped(io, allocator)) {
            return .stopped;
        }
        const result = pass_services.runStep(io, allocator, timers, pass, step) catch |err| {
            pass_services.reportError(io, allocator, timers, std.fmt.allocPrint(allocator, "{s} step \"{s}\" failed: {s}", .{ label, step.@"type", describe(allocator, err) }) catch "A step failed.");
            return .failed;
        };
        if (!result.succeeded) {
            pass_services.reportError(io, allocator, timers, std.fmt.allocPrint(allocator, "{s} step \"{s}\" did not succeed.", .{ label, step.@"type" }) catch "A step did not succeed.");
            return .failed;
        }
        results.append(allocator, result) catch {
            pass_services.reportError(io, allocator, timers, "The pass ran out of memory.");
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
pub fn runImportPass(io: std.Io, allocator: std.mem.Allocator, timers: Timers, pass_services: PassServices) IPassResult {
    const plan = readPlanOrReport(io, allocator, timers, pass_services, "plan-auto-import", .null, FALLBACK_PAUSE_MS, "what automatic import should do") orelse {
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
        pass_services.report(io, allocator, timers, "Automatic import is switched off.");
        return .{
            .gap_ms = plan.pause_ms,
            .finished = true,
        };
    }
    pass_services.holdAwake(io, allocator, timers, true) catch |err| {
        pass_services.reportError(io, allocator, timers, std.fmt.allocPrint(allocator, "Could not keep the phone awake for automatic import: {s}", .{describe(allocator, err)}) catch "Could not keep the phone awake.");
        return ran;
    };
    defer pass_services.holdAwake(io, allocator, timers, false) catch |err| {
        pass_services.reportError(io, allocator, timers, std.fmt.allocPrint(allocator, "Could not let the phone sleep again after automatic import: {s}", .{describe(allocator, err)}) catch "Could not let the phone sleep again.");
    };
    pass_services.report(io, allocator, timers, std.fmt.allocPrint(allocator, "Automatic import running into \"{s}\".", .{plan.database_path}) catch "Automatic import running.");
    var results: std.ArrayList(IStepResult) = .empty;
    _ = runSteps(io, allocator, timers, pass_services, .import, plan, "Automatic import", &results);
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
fn readSyncPlan(io: std.Io, allocator: std.mem.Allocator, timers: Timers, pass_services: PassServices, replica_state: *ReplicaState) ?IPlan {
    var request: std.json.ObjectMap = .empty;
    request.put(allocator, "prefetchState", .{
        .string = replicaStateName(replica_state.*),
    }) catch {
        pass_services.reportError(io, allocator, timers, "The sync pass ran out of memory.");
        return null;
    };
    return readPlanOrReport(io, allocator, timers, pass_services, "plan-sync", .{ .object = request }, SYNC_FALLBACK_PAUSE_MS, "whether a sync should run");
}

//
// One pass of the sync: asks the plan-sync task whether a sync should run, and runs the tasks it hands back. Never finished, because
// every reason a sync is refused can go away without the app being touched.
//
// The first pass after the work is switched on only reads the gap, so the first sync waits the configured pause too. The work is switched
// on when a database is opened, and a sync at that moment would push a database the user has only just opened, racing whatever they do
// to it next. The pause is a setting only the plan reads.
//
pub fn runSyncPass(io: std.Io, allocator: std.mem.Allocator, timers: Timers, pass_services: PassServices, replica_state: *ReplicaState, first: bool) IPassResult {
    const plan = readSyncPlan(io, allocator, timers, pass_services, replica_state) orelse {
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
        pass_services.report(io, allocator, timers, std.fmt.allocPrint(allocator, "Not syncing: {s}", .{plan.reason}) catch "Not syncing.");
        return ran;
    }
    pass_services.holdAwake(io, allocator, timers, true) catch |err| {
        pass_services.reportError(io, allocator, timers, std.fmt.allocPrint(allocator, "Could not keep the phone awake for a sync: {s}", .{describe(allocator, err)}) catch "Could not keep the phone awake.");
        return ran;
    };
    defer pass_services.holdAwake(io, allocator, timers, false) catch |err| {
        pass_services.reportError(io, allocator, timers, std.fmt.allocPrint(allocator, "Could not let the phone sleep again after a sync: {s}", .{describe(allocator, err)}) catch "Could not let the phone sleep again.");
    };
    pass_services.report(io, allocator, timers, std.fmt.allocPrint(allocator, "Syncing \"{s}\".", .{plan.database_path}) catch "Syncing.");
    var results: std.ArrayList(IStepResult) = .empty;
    _ = runSteps(io, allocator, timers, pass_services, .sync, plan, "Sync", &results);
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
pub fn runPrefetchPass(io: std.Io, allocator: std.mem.Allocator, timers: Timers, pass_services: PassServices, replica_state: *ReplicaState) IPassResult {
    const plan = readPlanOrReport(io, allocator, timers, pass_services, "plan-prefetch", .null, FALLBACK_PAUSE_MS, "what the background prefetch should do") orelse {
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
        pass_services.report(io, allocator, timers, std.fmt.allocPrint(allocator, "No database to fill in: {s}", .{plan.reason}) catch "No database to fill in.");
        return ran;
    }
    pass_services.holdAwake(io, allocator, timers, true) catch |err| {
        pass_services.reportError(io, allocator, timers, std.fmt.allocPrint(allocator, "Could not keep the phone awake for the prefetch: {s}", .{describe(allocator, err)}) catch "Could not keep the phone awake.");
        return ran;
    };
    defer pass_services.holdAwake(io, allocator, timers, false) catch |err| {
        pass_services.reportError(io, allocator, timers, std.fmt.allocPrint(allocator, "Could not let the phone sleep again after the prefetch: {s}", .{describe(allocator, err)}) catch "Could not let the phone sleep again.");
    };
    pass_services.report(io, allocator, timers, std.fmt.allocPrint(allocator, "Filling in \"{s}\".", .{plan.database_path}) catch "Filling in a replica.");

    var results: std.ArrayList(IStepResult) = .empty;
    switch (runSteps(io, allocator, timers, pass_services, .prefetch, plan, "Prefetch", &results)) {
        .completed => {},
        .stopped => {
            return ran;
        },
        .failed => {
            // Stalled, not complete. A step that failed tells us nothing about what is left, and a sync that waited on it would wait
            // for ever.
            replica_state.* = .stalled;
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
        replica_state.* = .complete;
        pass_services.report(io, allocator, timers, std.fmt.allocPrint(allocator, "\"{s}\" is filled in; nothing left to fetch.", .{plan.database_path}) catch "The replica is filled in; nothing left to fetch.");
        return .{
            .gap_ms = plan.pause_ms,
            .finished = true,
        };
    }
    // Fetching anything at all counts as progress, including a pass that fetched files and found nothing left: the next pass confirms
    // that and reports the replica complete, so at worst a sync waits one more gap. Fetching nothing while files are still missing is
    // the stuck case, and it is the one a sync must not wait on.
    replica_state.* = if (anything_fetched) .working else .stalled;
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
// The services of a pass that runs as a task: its steps are child tasks of the pass's own task, so they take its source and are
// cancelled with it, and the platform is reached through the native app's native calls. The pass services' pointer is the task's
// services, the argument the task was given (see runPass).
//
const task_pass_services_vtable: PassServices.VTable = .{
    .readPlan = readPlanOfTask,
    .runStep = runStepOfTask,
    .holdAwake = holdAwakeOfTask,
    .report = reportOfTask,
    .reportError = reportErrorOfTask,
    .isStopped = isStoppedOfTask,
};

//
// The pass services of a pass that runs as the task whose services are given.
//
fn taskPassServices(services: *const TaskServices) PassServices {
    return .{
        .ptr = @constCast(services),
        .vtable = &task_pass_services_vtable,
    };
}

//
// The services of the task the pass services are for.
//
fn servicesOf(ptr: *anyopaque) TaskServices {
    const services: *const TaskServices = @ptrCast(@alignCast(ptr));
    return services.*;
}

//
// Runs a child task and waits for it. The completion is allocated with the allocator, which is the pass's. A child that did not
// succeed is returned as its completion, for the caller to decide on.
//
fn runChildOfTask(services: TaskServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers, task_type: []const u8, data: std.json.Value) !ziggy.types.Completion {
    return try services.runChild(io, allocator, timers, allocator, task_type, data, null);
}

fn readPlanOfTask(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, plan_task: []const u8, data: std.json.Value) anyerror!std.json.Value {
    const completion = try runChildOfTask(servicesOf(ptr), io, allocator, timers, plan_task, data);
    if (completion.status != .succeeded) {
        return utils.errors.throwError("{s} failed: {s}", .{ plan_task, completion.error_message orelse "no reason given" });
    }
    const text = completion.result_json orelse {
        return utils.errors.throwError("{s} returned nothing.", .{plan_task});
    };
    return try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

fn runStepOfTask(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, pass: Pass, step: IStep) anyerror!IStepResult {
    const services = servicesOf(ptr);
    const completion = try runChildOfTask(services, io, allocator, timers, step.@"type", step.data);
    if (completion.status != .succeeded) {
        sendBackgroundLog(services, io, allocator, timers, std.fmt.allocPrint(allocator, "Background {s} task \"{s}\" failed: {s}", .{ pass.label(), step.@"type", completion.error_message orelse "no reason given" }) catch "A background task failed.", true);
        return .{
            .succeeded = false,
            .files_fetched = 0,
            .files_still_missing = 0,
        };
    }
    if (pass != .prefetch) {
        return .{
            .succeeded = true,
            .files_fetched = 0,
            .files_still_missing = 0,
        };
    }
    const outputs: ?std.json.Value = if (completion.result_json) |text| try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{}) else null;
    return readPrefetchStepCounts(outputs);
}

fn holdAwakeOfTask(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, awake: bool) anyerror!void {
    _ = try callNativeApp(servicesOf(ptr), io, allocator, timers, "holdAwake", try json.stringify(allocator, .{
        .awake = awake,
    }));
}

fn reportOfTask(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, message: []const u8) void {
    sendBackgroundLog(servicesOf(ptr), io, allocator, timers, message, false);
}

fn reportErrorOfTask(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, timers: Timers, message: []const u8) void {
    sendBackgroundLog(servicesOf(ptr), io, allocator, timers, message, true);
}

fn isStoppedOfTask(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) bool {
    return servicesOf(ptr).isCancelled(io, allocator);
}

//
// Tells the native app what the pass is doing, for the system log. A native app that cannot take it is not allowed to make the
// pass's report vanish, so the message goes to the app's own log with the reason.
//
fn sendBackgroundLog(services: TaskServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers, message: []const u8, is_error: bool) void {
    const log = services.log;
    const request = json.stringify(allocator, .{
        .@"error" = is_error,
        .message = message,
    }) catch {
        log.@"error"(message);
        return;
    };
    _ = callNativeApp(services, io, allocator, timers, "backgroundLog", request) catch |err| {
        log.@"error"(std.fmt.allocPrint(allocator, "The background work could not tell the system log \"{s}\": {s}", .{ message, utils.errors.errorMessage(err) }) catch message);
    };
}

//
// The type of the task event a task sends for the main thread to hold the computer awake, or let it go, on Windows and MacOS, where the
// hold belongs to the main thread (see callOnDesktop). Its data is the JSON text of the holdAwake request.
//
pub const HOLD_AWAKE_EVENT_TYPE = "hold-awake";

//
// Calls the native app to do what the method names, and returns its result, which is JSON text, allocated with the allocator. A
// platform without the callback and a native app that cannot do it are each an error with a sentence the user can act on.
//
pub fn callNativeApp(services: TaskServices, io: std.Io, allocator: std.mem.Allocator, timers: ?Timers, method: []const u8, request_json: []const u8) ![]const u8 {
    const reply = services.nativeCall(io, allocator, timers, method, request_json) catch |err| {
        if (err == error.NativeCallMissing) {
            return try callOnDesktop(services, io, allocator, method, request_json);
        }
        return err;
    };
    if (!reply.succeeded) {
        return utils.errors.throwError("{s}", .{reply.text});
    }
    return reply.text;
}

//
// Makes a native call when the native app has no native call callback. Ziggy's Windows native app and MacOS bridge have none, so on
// Windows and MacOS the task makes the calls a desktop can do itself (windows-native-calls.zig, macos-native-calls.zig): the constant
// results here, on the task's thread, and holdAwake on the main thread, which keeps the hold, through a task event of
// HOLD_AWAKE_EVENT_TYPE. Anywhere else, and for a call only a phone can make, it is an error that names the method.
//
pub fn callOnDesktop(services: TaskServices, io: std.Io, allocator: std.mem.Allocator, method: []const u8, request_json: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows or builtin.os.tag == .macos) {
        if (std.mem.eql(u8, method, "holdAwake")) {
            try services.sendEvent(io, allocator, .{
                .type = HOLD_AWAKE_EVENT_TYPE,
                .request = json.Raw{
                    .text = request_json,
                },
            });
            return "null";
        }
    }
    if (builtin.os.tag == .windows) {
        var native_calls = windows_native_calls.WindowsNativeCalls.init();
        defer native_calls.deinit();
        if (try native_calls.call(allocator, method, request_json)) |result| {
            return result;
        }
    }
    if (builtin.os.tag == .macos) {
        var native_calls = macos_native_calls.MacosNativeCalls.init();
        defer native_calls.deinit();
        if (try native_calls.call(allocator, method, request_json)) |result| {
            return result;
        }
    }
    return utils.errors.throwError("{s} is only available in the Photosphere app on a phone.", .{method});
}

//
// What the main thread gives a pass task: what it knows that the pass needs.
//
pub const IPassTaskData = struct {
    // Whether this is the first sync pass since the sync was switched on, which only reads the gap (see runSyncPass).
    first: bool = false,
    // What the last completed prefetch pass reported about the replica, which the sync pass holds back for.
    replicaState: ReplicaState = .unknown,
};

//
// What a pass task gives back to the main thread, which records when the next pass is due and what the prefetch reported about the replica.
//
pub const IPassTaskResult = struct {
    // How long to wait before the next pass, in milliseconds.
    gapMs: u64,
    // Whether the work is over until it is switched on again.
    finished: bool,
    // What the replica is like after the pass. Only the prefetch pass changes it.
    replicaState: ReplicaState,
};

//
// Runs one pass in the task, with what the main thread gave it, and gives back how it ended.
//
fn runPass(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, data: std.json.Value, pass: Pass) ![]const u8 {
    const given = try std.json.parseFromValueLeaky(IPassTaskData, allocator, data, .{
        .ignore_unknown_fields = true,
    });
    var replica_state = given.replicaState;
    const pass_services = taskPassServices(&services);
    const result = switch (pass) {
        .import => runImportPass(io, allocator, timers, pass_services),
        .sync => runSyncPass(io, allocator, timers, pass_services, &replica_state, given.first),
        .prefetch => runPrefetchPass(io, allocator, timers, pass_services, &replica_state),
    };
    return try json.stringify(allocator, IPassTaskResult{
        .gapMs = result.gap_ms,
        .finished = result.finished,
        .replicaState = replica_state,
    });
}

//
// The task that is one pass of the automatic import.
//
pub fn autoImportPassTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
    return try runPass(services, timers, io, allocator, data, .import);
}

//
// The task that is one pass of the sync.
//
pub fn syncPassTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
    return try runPass(services, timers, io, allocator, data, .sync);
}

//
// The task that is one pass of the prefetch.
//
pub fn prefetchPassTask(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
    return try runPass(services, timers, io, allocator, data, .prefetch);
}
