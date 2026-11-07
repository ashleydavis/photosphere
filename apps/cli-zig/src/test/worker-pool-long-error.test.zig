const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const ziggy = @import("ziggy");
const media_tools = @import("media-tools-zig");
const worker_pool_test = @import("worker-pool.test.zig");
const WorkerPoolBun = cli.worker_pool.WorkerPoolBun;
const Collector = worker_pool_test.Collector;
const types = ziggy.task_queue.types;
const Timers = ziggy.timers.Timers;

//
// Text as long as a real task type name, repeated to make an error message longer than the fixed buffer the Collector used to copy
// it into, which panicked the whole test binary and took every other test in the package with it.
//
const long_text = "photosphere-library-sync-photos-provider-s3-bucket-credential-refresh-and-reconciliation-of-the-metadata-index";

//
// The task type of the failing task.
//
const long_error_task_type = "long-error";

//
// Fails with an error message several times as long as long_text.
//
fn longErrorHandler(allocator: std.mem.Allocator, io: std.Io, timers: Timers, log: utils.log.ILog, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = log;
    _ = timers;
    _ = allocator;
    _ = io;
    _ = data;
    _ = context;
    return utils.errors.throwError("Failed: {s} {s} {s}", .{ long_text, long_text, long_text });
}

//
// The task types the worker of the test runs.
//
const test_tasks = [_]ziggy.task_runner.TaskHandlerEntry{
    .{ .name = long_error_task_type, .handler = ziggy.task_runner.fromQueueHandler(longErrorHandler) },
};

test "an error message longer than the collector's buffer is recorded whole" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = std.testing.allocator;
    var timer_list = ziggy.timers.TimerList.init();
    var mediaTools = try media_tools.MediaTools.init();
    defer mediaTools.deinit();
    const pool = try WorkerPoolBun.init(allocator, &mediaTools, 1, 10000, .{ .tasks = &test_tasks });
    defer pool.deinit(std.testing.io, allocator);
    var collector = Collector.init(arena.allocator());
    _ = try pool.onTaskComplete(allocator, .{ .context = &collector, .function = Collector.onComplete });
    const taskId = try pool.addTask(allocator, std.testing.io, log, long_error_task_type, .null, "source", null, null);
    allocator.free(taskId);
    try collector.waitForCompleted(log, pool, allocator, timer_list.interface(), 1);

    // The message is longer than the 256 bytes the collector used to copy it into.
    try std.testing.expectEqual(@as(usize, 1), collector.failed);
    try std.testing.expectEqualStrings("Error", collector.lastErrorName);
    try std.testing.expect(collector.lastErrorMessage.len > 256);
    try std.testing.expectEqualStrings("Failed: " ++ long_text ++ " " ++ long_text ++ " " ++ long_text, collector.lastErrorMessage);
}
