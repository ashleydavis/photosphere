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

test "exec hands the quotes in the command to the shell untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Quoted arguments holding spaces and %, like `magick identify -format "%w %h" "<file>"`. cmd.exe on
    // Windows echoes the arguments as they reach it, quotes included, and ends lines with CRLF.
    if (builtin.os.tag == .windows) {
        const result = try exec(arena.allocator(), std.testing.io, "echo \"%w %h\" \"file name.jpg\"");
        try std.testing.expectEqualStrings("\"%w %h\" \"file name.jpg\"\r\n", result.stdout);
    }
    else {
        const result = try exec(arena.allocator(), std.testing.io, "echo \"%w %h\" \"file name.jpg\"");
        try std.testing.expectEqualStrings("%w %h file name.jpg\n", result.stdout);
    }
}

test "exec reads stdout and stderr together so a command filling stderr does not block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // More than a pipe buffer holds goes to stderr before anything goes to stdout.
    if (builtin.os.tag == .windows) {
        const result = try exec(arena.allocator(), std.testing.io, "(for /L %i in (1,1,10000) do @echo stderr line %i>&2)& echo done");
        try std.testing.expectEqualStrings("done\r\n", result.stdout);
        try std.testing.expect(result.stderr.len > 128 * 1024);
    }
    else {
        const result = try exec(arena.allocator(), std.testing.io, "i=0; while [ $i -lt 10000 ]; do echo stderr line $i 1>&2; i=$((i+1)); done; echo done");
        try std.testing.expectEqualStrings("done\n", result.stdout);
        try std.testing.expect(result.stderr.len > 128 * 1024);
    }
}

//
// Writes a file of the given number of bytes to a unique path under the package's .zig-cache directory.
//
fn writeFileOfSize(allocator: std.mem.Allocator, io: std.Io, size: usize) ![]const u8 {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const filePath = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/photosphere-exec-test-{x}.txt", .{std.mem.readInt(u64, &random_bytes, .little)});
    const data = try allocator.alloc(u8, size);
    @memset(data, 'a');
    try node_utils.fs.outputFile(allocator, io, filePath, data);
    return filePath;
}

//
// Prints a file to stdout, or to stderr when toStderr is true, in the shell exec runs.
//
fn printFileCommand(allocator: std.mem.Allocator, filePath: []const u8, toStderr: bool) ![]const u8 {
    const printer = if (builtin.os.tag == .windows) "type" else "cat";
    const nativePath = if (builtin.os.tag == .windows) try std.mem.replaceOwned(u8, allocator, filePath, "/", "\\") else filePath;
    const redirect = if (toStderr) " 1>&2" else "";
    return std.fmt.allocPrint(allocator, "{s} \"{s}\"{s}", .{ printer, nativePath, redirect });
}

test "exec takes up to maxBuffer (1 MiB) of output, as Bun's exec does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try writeFileOfSize(allocator, io, 1024 * 1024);
    defer std.Io.Dir.cwd().deleteFile(io, filePath) catch {};

    const toStdout = try exec(allocator, io, try printFileCommand(allocator, filePath, false));
    try std.testing.expectEqual(@as(usize, 1024 * 1024), toStdout.stdout.len);
    const toStderr = try exec(allocator, io, try printFileCommand(allocator, filePath, true));
    try std.testing.expectEqual(@as(usize, 1024 * 1024), toStderr.stderr.len);
}

test "exec fails with Bun's RangeError when the command writes more than maxBuffer to stdout or stderr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const filePath = try writeFileOfSize(allocator, io, 1024 * 1024 + 1);
    defer std.Io.Dir.cwd().deleteFile(io, filePath) catch {};

    try std.testing.expectError(error.Thrown, exec(allocator, io, try printFileCommand(allocator, filePath, false)));
    try std.testing.expectEqualStrings("RangeError", utils.errors.lastErrorName());
    try std.testing.expectEqualStrings("stdout maxBuffer length exceeded", utils.errors.lastErrorMessage());

    try std.testing.expectError(error.Thrown, exec(allocator, io, try printFileCommand(allocator, filePath, true)));
    try std.testing.expectEqualStrings("RangeError", utils.errors.lastErrorName());
    try std.testing.expectEqualStrings("stderr maxBuffer length exceeded", utils.errors.lastErrorMessage());
}
