const std = @import("std");
const node_utils = @import("node-utils-zig");
const utils = @import("utils-zig");
const exec = node_utils.exec.exec;

test "exec runs the command in the shell and returns its output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try exec(arena.allocator(), std.testing.io, "echo hello && echo oops 1>&2");
    try std.testing.expectEqualStrings("hello\n", result.stdout);
    try std.testing.expectEqualStrings("oops\n", result.stderr);
}

test "exec fails with Node's message when the command exits with a non-zero code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Thrown, exec(arena.allocator(), std.testing.io, "echo broken 1>&2; exit 3"));
    try std.testing.expectEqualStrings("Command failed: echo broken 1>&2; exit 3\nbroken\n", utils.errors.lastErrorMessage());
}

test "exec passes process.env to the command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(arena.allocator());
    try environ_map.put("PHOTOSPHERE_EXEC_TEST", "from-env");
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);
    const result = try exec(arena.allocator(), std.testing.io, "echo $PHOTOSPHERE_EXEC_TEST");
    try std.testing.expectEqualStrings("from-env\n", result.stdout);
}
