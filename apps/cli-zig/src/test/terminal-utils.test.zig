const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const terminal_utils = cli.terminal_utils;

test "writeProgress clears the line and writes the message on a TTY" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    terminal_utils.setOutputForTesting(&output.writer, true);
    defer terminal_utils.setOutputForTesting(null, null);
    terminal_utils.writeProgress("Copying files...");
    try std.testing.expectEqualStrings("\x1b[2K\x1b[1GCopying files...", output.written());
    terminal_utils.clearProgressMessage();
    try std.testing.expectEqualStrings("\x1b[2K\x1b[1GCopying files...\x1b[2K\x1b[1G", output.written());
}

test "writeProgress writes nothing when stdout is not a TTY" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    terminal_utils.setOutputForTesting(&output.writer, false);
    defer terminal_utils.setOutputForTesting(null, null);
    terminal_utils.writeProgress("Copying files...");
    terminal_utils.clearProgressMessage();
    try std.testing.expectEqualStrings("", output.written());
}

test "writeProgress writes nothing when verbose logging is enabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    terminal_utils.setOutputForTesting(&output.writer, true);
    defer terminal_utils.setOutputForTesting(null, null);
    const previous = utils.log.log;
    defer utils.log.setLog(previous);
    var verboseLog = cli.log.Log.init(.{ .verbose = true });
    utils.log.setLog(verboseLog.ilog());
    terminal_utils.writeProgress("Copying files...");
    terminal_utils.clearProgressMessage();
    try std.testing.expectEqualStrings("", output.written());
}
