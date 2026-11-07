const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const ziggy = @import("ziggy");
const WorkerPoolBun = cli.worker_pool.WorkerPoolBun;
const worker_messages = ziggy.worker_messages;

//
// Writes the log line a worker sends as the pool writes it, to the log given, for the worker and task given, showing tool lines
// when `toolsShown` (the command's --tools).
//
fn writeLine(arena: std.mem.Allocator, log: utils.log.ILog, toolsShown: bool, workerId: u32, taskId: ?[]const u8, message: worker_messages.IWorkerLogMessage) !void {
    WorkerPoolBun.writeWorkerLog(arena, log, toolsShown, workerId, taskId, try worker_messages.encode(arena, message));
}

test "a worker's log lines are written prefixed with the worker and task IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // The main thread's log as `--tools` makes it: the output of tools is shown and debug lines are not.
    const memory = try utils.memory_log.MemoryLog.init(allocator, .{
        .verbose = false,
        .debug = false,
        .tools = true,
    });
    defer memory.deinit();

    try writeLine(allocator, memory.log, true, 3, null, .{ .level = .info, .message = "idle" });
    try writeLine(allocator, memory.log, true, 3, "task-1", .{ .level = .info, .message = "busy" });
    try writeLine(allocator, memory.log, true, 3, "task-1", .{ .level = .debug, .message = "not shown" });
    try writeLine(allocator, memory.log, true, 3, "task-1", .{ .level = .event, .message = "done" });
    try writeLine(allocator, memory.log, true, 3, "task-1", .{ .level = .tool, .message = "ffprobe", .toolData = .{ .stdout = "o" } });
    try writeLine(allocator, memory.log, true, 3, "task-1", .{ .level = .warn, .message = "careful" });
    try writeLine(allocator, memory.log, true, 3, "task-1", .{ .level = .@"error", .message = "bad" });
    try writeLine(allocator, memory.log, true, 3, "task-1", .{ .level = .exception, .message = "failed", .@"error" = "Error: Cause" });
    try std.testing.expectEqualStrings("[W3] idle\n[W3:task-1] busy\n[W3:task-1] [EVENT] done\n[W3:task-1] == ffprobe stdout ==\no\n", memory.stdout());
    try std.testing.expectEqualStrings("[W3:task-1] careful\n[W3:task-1] bad\n[W3:task-1] failed\nError: Cause\n", memory.stderr());
}

test "a worker's long event is written whole, as the template string does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const memory = try utils.memory_log.MemoryLog.init(allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();

    const longMessage = try allocator.alloc(u8, 20000);
    @memset(longMessage, 'e');
    try writeLine(allocator, memory.log, false, 2, null, .{ .level = .event, .message = longMessage });
    try std.testing.expectEqualStrings(try std.mem.concat(allocator, u8, &.{ "[W2] [EVENT] ", longMessage, "\n" }), memory.stdout());
}

test "a worker's tool output is not written when it is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const memory = try utils.memory_log.MemoryLog.init(allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();

    try writeLine(allocator, memory.log, false, 1, null, .{ .level = .tool, .message = "ffprobe", .toolData = .{ .stdout = "" } });
    try writeLine(allocator, memory.log, false, 1, null, .{ .level = .tool, .message = "ffprobe", .toolData = .{ .stderr = "" } });
    try writeLine(allocator, memory.log, false, 1, null, .{ .level = .tool, .message = "ffprobe", .toolData = .{} });
    try writeLine(allocator, memory.log, false, 1, null, .{ .level = .tool, .message = "ffprobe" });
    try std.testing.expectEqualStrings("", memory.stdout());
    try std.testing.expectEqualStrings("", memory.stderr());
}

test "with the file log on the main thread, a worker's lines reach the log file tagged with the worker and task IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const logsDir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/logs", .{&tmp.sub_path});
    const logger = try utils.file_log.FileLog.start(allocator, std.testing.io, .{
        .file_prefix = "psi",
        .title = "Photosphere CLI Log",
        .logs_dir = logsDir,
        .command = null,
        .version = "dev",
        .header_lines = &.{},
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer logger.stop(allocator, std.testing.io);
    const log = logger.ilog();

    try writeLine(allocator, log, false, 3, "task-1", .{ .level = .info, .message = "busy" });
    try writeLine(allocator, log, false, 3, "task-1", .{ .level = .verbose, .message = "detail" });
    try writeLine(allocator, log, false, 3, null, .{ .level = .@"error", .message = "bad" });
    const written = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, logger.getLogFilePath(), allocator, .limited(1024 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, written, "] [INFO] [W3:task-1] busy\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "] [VERBOSE] [W3:task-1] detail\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "] [ERROR] [W3] bad\n") != null);
    try std.testing.expectEqualStrings("[W3:task-1] busy\n", stdout_capture.written());
    try std.testing.expectEqualStrings("[W3] bad\n", stderr_capture.written());
}
