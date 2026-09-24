const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const worker_log_bun = cli.worker_log_bun;

test "the worker log prefixes messages with the worker and task IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    var workerLog = worker_log_bun.WorkerLogBun.init(3, false, true);
    workerLog.info("idle");
    workerLog.setTaskId("task-1");
    workerLog.info("busy");
    workerLog.verbose("not shown");
    workerLog.debug("not shown");
    workerLog.event("done");
    workerLog.tool("ffprobe", .{ .stdout = "o", .stderr = null });
    workerLog.warn("careful");
    workerLog.@"error"("bad");
    workerLog.exception("failed", utils.errors.throwError("Cause", .{}));
    try std.testing.expectEqualStrings("[W3] idle\n[W3:task-1] busy\n[W3:task-1] [EVENT] done\n[W3:task-1] == ffprobe stdout ==\no\n", stdout_capture.written());
    try std.testing.expectEqualStrings("[W3:task-1] careful\n[W3:task-1] bad\n[W3:task-1] failed\nError: Cause\n", stderr_capture.written());
}

test "the routing log sends worker thread messages to the worker log" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);
    const previous = utils.log.log;
    defer utils.log.setLog(previous);

    var mainLog = cli.log.Log.init(.{ .verbose = true });
    utils.log.setLog(mainLog.ilog());
    worker_log_bun.installWorkerLogRouting();
    worker_log_bun.installWorkerLogRouting();

    utils.log.log.info("from main");
    try std.testing.expect(utils.log.log.verboseEnabled());

    const Worker = struct {
        fn run() void {
            var workerLog = worker_log_bun.WorkerLogBun.init(1, false, false);
            worker_log_bun.createWorkerLog(&workerLog);
            defer worker_log_bun.clearWorkerLog();
            worker_log_bun.setWorkerTaskId("abc");
            utils.log.log.info("from worker");
            utils.log.log.verbose("hidden in worker");
        }
    };
    const thread = try std.Thread.spawn(.{}, Worker.run, .{});
    thread.join();
    utils.log.log.verbose("main verbose");
    try std.testing.expectEqualStrings("from main\n[W1:abc] from worker\nmain verbose\n", stdout_capture.written());
}
