//
// A task that does nothing but take a while, so the job manager can be driven by hand.
//
// Every real job either finishes too fast to look at (a load, a small replication) or needs a large
// database and a long setup to make it last (an import). This one takes as long as it is told to,
// works through named stages reporting a rising count as it goes, and stops when it is cancelled,
// so the interface can be exercised without staging any data at all.
//
// It is reachable only from the developer section of the sidebar, which is hidden unless developer
// mode is switched on.
//

const std = @import("std");
const Timers = @import("ziggy").timers.Timers;
const utils = @import("utils-zig");
const task_queue_zig = @import("ziggy").task_queue;
const errors = utils.errors;
const sleep = utils.sleep.sleep;
const ITaskContext = task_queue_zig.types.ITaskContext;
const IJobTag = task_queue_zig.types.IJobTag;
const sendJobProgress = task_queue_zig.job_progress.sendJobProgress;

//
// How long each step of the task sleeps before it looks at the clock and the cancel flag again.
//
// Short enough that Cancel feels immediate, long enough that a task lasting a minute does not wake
// thousands of times doing nothing.
//
const STEP_MS: i64 = 250;

//
// Input data for the test-job task.
// (Zig: the `= 0`, `= &.{}` and `= null` defaults let std.json parse data that leaves keys out.)
//
pub const ITestJobData = struct {
    //
    // How long the task should run for, in milliseconds.
    //
    durationMs: i64 = 0,

    //
    // The stages the task works through, in order, an equal share of the time each. Each one names
    // what the job claims to be doing, so the progress line changes as the job goes rather than
    // counting down the same sentence.
    //
    stages: []const []const u8 = &.{},

    //
    // How many things this task pretends to process. The progress line counts up to it, so the
    // detail under the job's name moves the way a real job's does.
    //
    itemCount: i64 = 0,

    //
    // Names the job this task belongs to. Several tasks carrying the same tag are one row in the
    // interface, which is one of the cases this task exists to demonstrate.
    //
    job: ?IJobTag = null,
};

//
// What the task reports when it finishes.
//
pub const ITestJobResult = struct {
    //
    // How long the task actually ran for, in milliseconds. Shorter than asked for when cancelled.
    //
    elapsedMs: i64,

    //
    // True when the task stopped early because it was cancelled.
    //
    cancelled: bool,
};

//
// The progress line for a task that is the given fraction of the way through.
//
// Exported so the wording can be checked without running a task for half a minute.
// (Zig: when there are no stages the stage is written as "undefined".)
//
pub fn describeTestJobProgress(allocator: std.mem.Allocator, stages: []const []const u8, itemCount: i64, fraction: f64) ![]const u8 {
    const clamped = @min(@max(fraction, 0), 0.999);
    const stageIndex: usize = @intFromFloat(@floor(clamped * @as(f64, @floatFromInt(stages.len))));
    const stage = if (stageIndex < stages.len) stages[stageIndex] else "undefined";
    const done: i64 = @as(i64, @intFromFloat(@floor(clamped * @as(f64, @floatFromInt(itemCount))))) + 1;
    return std.fmt.allocPrint(allocator, "{s}: {d} of {d}", .{ stage, done, itemCount });
}

//
// The name the job is logged under: its name, or "untitled" when the task carries no tag.
// (Zig: "untitled" is used when the job tag is missing.)
//
fn jobName(job: ?IJobTag) []const u8 {
    if (job) |tag| {
        return tag.name;
    }
    return "untitled";
}

//
// Runs for the requested time, reporting progress as it goes, and stops early when cancelled.
// (Zig: the task data and output are JSON values holding ITestJobData and ITestJobResult.)
//
pub fn testJobHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    _: Timers,
    log: utils.log.ILog,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    // (Zig: reading the task data into the typed struct fails when a key holds the wrong type.
    // The failure is reported as a sentence, not a bare parser error name.)
    const data = std.json.parseFromValueLeaky(ITestJobData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errors.throwError("The test-job task data is not valid: durationMs and itemCount must be whole numbers, stages must be an array of strings and job must be an object", .{});
    };

    const startedAt = context.timestampProvider.now(io);
    const endsAt = startedAt + data.durationMs;

    // Math.round rounds halves up.
    const seconds: i64 = @intFromFloat(@floor(@as(f64, @floatFromInt(data.durationMs)) / 1000 + 0.5));
    log.info(try std.fmt.allocPrint(allocator, "Test job \"{s}\" running for {d}s.", .{ jobName(data.job), seconds }));

    while (true) {
        const now = context.timestampProvider.now(io);
        if (context.isCancelled(io, allocator)) {
            log.info(try std.fmt.allocPrint(allocator, "Test job \"{s}\" cancelled after {d}ms.", .{ jobName(data.job), now - startedAt }));
            return resultToJson(allocator, .{
                .elapsedMs = now - startedAt,
                .cancelled = true,
            });
        }

        if (now >= endsAt) {
            break;
        }

        const fraction = @as(f64, @floatFromInt(now - startedAt)) / @as(f64, @floatFromInt(data.durationMs));
        try sendJobProgress(allocator, io, log, context, data.job, startedAt, try describeTestJobProgress(allocator, data.stages, data.itemCount, fraction));

        try sleep(io, @intCast(@min(STEP_MS, endsAt - now)));
    }

    log.info(try std.fmt.allocPrint(allocator, "Test job \"{s}\" finished.", .{jobName(data.job)}));

    return resultToJson(allocator, .{
        .elapsedMs = context.timestampProvider.now(io) - startedAt,
        .cancelled = false,
    });
}

//
// Converts the result to the JSON value the task returns.
//
fn resultToJson(allocator: std.mem.Allocator, result: ITestJobResult) !std.json.Value {
    const text = try std.json.Stringify.valueAlloc(allocator, result, .{});
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}
