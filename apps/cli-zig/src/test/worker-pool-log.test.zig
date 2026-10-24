const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const ziggy = @import("ziggy");
const WorkerPoolBun = cli.worker_pool.WorkerPoolBun;
const worker_messages = ziggy.worker_messages;

//
// Writes the log line a worker sends as the pool writes it, for the worker and task given.
//
fn writeLine(arena: std.mem.Allocator, workerId: u32, taskId: ?[]const u8, message: worker_messages.IWorkerLogMessage) !void {
    WorkerPoolBun.writeWorkerLog(arena, workerId, taskId, try worker_messages.encode(arena, message));
}

test "a worker's log lines are written prefixed with the worker and task IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    try writeLine(allocator, 3, null, .{ .level = .info, .message = "idle" });
    try writeLine(allocator, 3, "task-1", .{ .level = .info, .message = "busy" });
    try writeLine(allocator, 3, "task-1", .{ .level = .debug, .message = "not shown" });
    try writeLine(allocator, 3, "task-1", .{ .level = .event, .message = "done" });
    try writeLine(allocator, 3, "task-1", .{ .level = .tool, .message = "ffprobe", .toolData = .{ .stdout = "o" } });
    try writeLine(allocator, 3, "task-1", .{ .level = .warn, .message = "careful" });
    try writeLine(allocator, 3, "task-1", .{ .level = .@"error", .message = "bad" });
    try writeLine(allocator, 3, "task-1", .{ .level = .exception, .message = "failed", .@"error" = "Error: Cause" });
    try std.testing.expectEqualStrings("[W3] idle\n[W3:task-1] busy\n[W3:task-1] [EVENT] done\n[W3:task-1] == ffprobe stdout ==\no\n", stdout_capture.written());
    try std.testing.expectEqualStrings("[W3:task-1] careful\n[W3:task-1] bad\n[W3:task-1] failed\nError: Cause\n", stderr_capture.written());
}

test "a worker's long event is written whole, as the template string does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    const longMessage = try allocator.alloc(u8, 20000);
    @memset(longMessage, 'e');
    try writeLine(allocator, 2, null, .{ .level = .event, .message = longMessage });
    try std.testing.expectEqualStrings(try std.mem.concat(allocator, u8, &.{ "[W2] [EVENT] ", longMessage, "\n" }), stdout_capture.written());
}

test "a worker's tool output is not written when it is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    try writeLine(allocator, 1, null, .{ .level = .tool, .message = "ffprobe", .toolData = .{ .stdout = "" } });
    try writeLine(allocator, 1, null, .{ .level = .tool, .message = "ffprobe", .toolData = .{ .stderr = "" } });
    try writeLine(allocator, 1, null, .{ .level = .tool, .message = "ffprobe", .toolData = .{} });
    try writeLine(allocator, 1, null, .{ .level = .tool, .message = "ffprobe" });
    try std.testing.expectEqualStrings("", stdout_capture.written());
    try std.testing.expectEqualStrings("", stderr_capture.written());
}
