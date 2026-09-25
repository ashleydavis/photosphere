const std = @import("std");
const cli = @import("cli-zig");
const tools = @import("tools-zig");

test "ensureMediaProcessingTools returns when every tool is available" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const status = try tools.verifyTools(arena.allocator(), std.testing.io);
    if (!status.allAvailable) {
        // The missing-tools path exits the process, so it cannot run in a unit test.
        return error.SkipZigTest;
    }
    try cli.ensure_tools.ensureMediaProcessingTools(arena.allocator(), std.testing.io, true);
}
