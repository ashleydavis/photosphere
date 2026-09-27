const std = @import("std");
const builtin = @import("builtin");
const node_utils = @import("node-utils-zig");
const utils = @import("utils-zig");
const exec = node_utils.exec.exec;

test "exec runs the command in the shell and returns its output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The command runs in cmd.exe on Windows, which has its own syntax and ends lines with CRLF.
    if (builtin.os.tag == .windows) {
        const result = try exec(arena.allocator(), std.testing.io, "echo hello&& echo oops>&2");
        try std.testing.expectEqualStrings("hello\r\n", result.stdout);
        try std.testing.expectEqualStrings("oops\r\n", result.stderr);
    }
    else {
        const result = try exec(arena.allocator(), std.testing.io, "echo hello && echo oops 1>&2");
        try std.testing.expectEqualStrings("hello\n", result.stdout);
        try std.testing.expectEqualStrings("oops\n", result.stderr);
    }
}

test "exec fails with Node's message when the command exits with a non-zero code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // The command runs in cmd.exe on Windows, which has its own syntax and ends lines with CRLF.
    if (builtin.os.tag == .windows) {
        try std.testing.expectError(error.Thrown, exec(arena.allocator(), std.testing.io, "echo broken>&2& exit 3"));
        try std.testing.expectEqualStrings("Command failed: echo broken>&2& exit 3\nbroken\r\n", utils.errors.lastErrorMessage());
    }
    else {
        try std.testing.expectError(error.Thrown, exec(arena.allocator(), std.testing.io, "echo broken 1>&2; exit 3"));
        try std.testing.expectEqualStrings("Command failed: echo broken 1>&2; exit 3\nbroken\n", utils.errors.lastErrorMessage());
    }
}

test "exec passes process.env to the command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(arena.allocator());
    try environ_map.put("PHOTOSPHERE_EXEC_TEST", "from-env");
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);

    // cmd.exe on Windows expands %NAME% and ends lines with CRLF.
    if (builtin.os.tag == .windows) {
        const result = try exec(arena.allocator(), std.testing.io, "echo %PHOTOSPHERE_EXEC_TEST%");
        try std.testing.expectEqualStrings("from-env\r\n", result.stdout);
    }
    else {
        const result = try exec(arena.allocator(), std.testing.io, "echo $PHOTOSPHERE_EXEC_TEST");
        try std.testing.expectEqualStrings("from-env\n", result.stdout);
    }
}

test "execLogged returns the output of the command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try node_utils.exec.execLogged(arena.allocator(), std.testing.io, "echo", "echo hello", null);
    const expected = if (builtin.os.tag == .windows) "hello\r\n" else "hello\n";
    try std.testing.expectEqualStrings(expected, result.stdout);
}

test "execLogged reports a command that fails as a failure to execute it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Thrown, node_utils.exec.execLogged(arena.allocator(), std.testing.io, "sh", "exit 3", null));
    try std.testing.expectEqualStrings("Failed to execute command: exit 3", utils.errors.lastErrorMessage());
}

//
// A validation that always fails.
//
fn failValidation(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!?[]const u8 {
    _ = context;
    _ = allocator;
    _ = io;
    return "the output is missing";
}

test "execLogged reports a failed validation as a failure to execute the command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The failure is reported on stdout, which the test runner reads its own messages from.
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    utils.console.setCapture(&output.writer, &output.writer);
    defer utils.console.setCapture(null, null);
    var unused: u8 = 0;
    try std.testing.expectError(error.Thrown, node_utils.exec.execLogged(arena.allocator(), std.testing.io, "echo", "echo hello", .{ .context = &unused, .function = failValidation }));
    try std.testing.expectEqualStrings("Failed to execute command: echo hello", utils.errors.lastErrorMessage());
}
