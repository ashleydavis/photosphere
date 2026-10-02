const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const task_queue = @import("task-queue-zig");
const worker_pool_test = @import("worker-pool.test.zig");
const WorkerPoolBun = cli.worker_pool.WorkerPoolBun;
const Collector = worker_pool_test.Collector;
const types = task_queue.types;

//
// A task type name as long as a real one: the worker lists every registered type in the error it reports for
// an unregistered one, so one name this long makes that message longer than the fixed buffer the Collector
// used to copy it into, which panicked the whole test binary and took every other test in the package with it.
//
const long_handler_type_name = "photosphere-library-sync-photos-provider-s3-bucket-credential-refresh-and-reconciliation-of-the-metadata-index";

//
// The task type the failing task asks for, which nothing has registered.
//
const unregistered_task_type = "photosphere-library-sync-no-such-task-type";

//
// The handler registered for the long task type name (it is never called; only its name in the registry
// matters, because the worker prints the registry in the error it reports for an unregistered task type).
//
fn longNameHandler(allocator: std.mem.Allocator, io: std.Io, data: std.json.Value, context: types.ITaskContext) anyerror!std.json.Value {
    _ = allocator;
    _ = io;
    _ = data;
    _ = context;
    return .null;
}

test "an error message longer than the collector's buffer is recorded whole" {
    try task_queue.worker.registerHandler(long_handler_type_name, longNameHandler);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The pool installs the worker log routing in place of the global log; put the global log back after.
    const previousLog = utils.log.log;
    defer utils.log.setLog(previousLog);
    const pool = try WorkerPoolBun.init(std.testing.io, 1, 10000, .{});
    defer pool.deinit();
    var collector = Collector{};
    _ = try pool.onTaskComplete(.{ .context = &collector, .function = Collector.onComplete });
    _ = try pool.addTask(arena.allocator(), std.testing.io, unregistered_task_type, .null, "source", null, null);
    try collector.waitForCompleted(1);

    // The message the worker builds is longer than the 256 bytes the collector used to copy it into.
    try std.testing.expectEqual(@as(usize, 1), collector.failed);
    try std.testing.expectEqualStrings("Error", collector.lastErrorName[0..collector.lastErrorNameLength]);
    const message = collector.lastErrorMessage[0..collector.lastErrorMessageLength];
    try std.testing.expect(message.len > 256);
    try std.testing.expect(std.mem.startsWith(u8, message, "No handler registered for task type: "));
    try std.testing.expect(std.mem.indexOf(u8, message, unregistered_task_type) != null);
    try std.testing.expect(std.mem.indexOf(u8, message, long_handler_type_name) != null);
}