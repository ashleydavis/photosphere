const std = @import("std");
const cli = @import("cli-zig");

const prompts = cli.prompts;

test "note writes the message in a box of bars under its title" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    cli.picocolors.setColorSupportOverride(false);
    defer cli.picocolors.setColorSupportOverride(null);
    var output = std.Io.Writer.Allocating.init(allocator);

    try prompts.note(allocator, std.testing.io, "Both devices must be on the same local network (wired or Wi-Fi).\nThis does not work over the internet.", "\u{2139} Network Requirement", .{ .common = .{ .output = &output.writer } });

    // What the TypeScript note writes (psi secrets send), the lines padded to the longest plus 2.
    const expected =
        "   \u{2139} Network Requirement\n" ++
        (" " ** 70) ++ "\n" ++
        "   Both devices must be on the same local network (wired or Wi-Fi).   \n" ++
        "   This does not work over the internet.                              \n" ++
        (" " ** 70) ++ "\n";
    try std.testing.expectEqualStrings(expected, output.written());
}

test "note dims the message, greys the bars and resets the title when colour is on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    cli.picocolors.setColorSupportOverride(true);
    defer cli.picocolors.setColorSupportOverride(null);
    var output = std.Io.Writer.Allocating.init(allocator);

    try prompts.note(allocator, std.testing.io, "ab", "T", .{ .common = .{ .output = &output.writer } });

    const bar = "\x1b[90m \x1b[39m";
    const expected =
        "   \x1b[0mT\x1b[0m\n" ++
        bar ++ "      " ++ bar ++ "\n" ++
        bar ++ "  \x1b[2mab\x1b[22m  " ++ bar ++ "\n" ++
        bar ++ "      " ++ bar ++ "\n";
    try std.testing.expectEqualStrings(expected, output.written());
}

test "note without a title writes the box alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    cli.picocolors.setColorSupportOverride(false);
    defer cli.picocolors.setColorSupportOverride(null);
    var output = std.Io.Writer.Allocating.init(allocator);

    try prompts.note(allocator, std.testing.io, "x", "", .{ .common = .{ .output = &output.writer } });

    // The three spaces before the box go before its first line only.
    try std.testing.expectEqualStrings("          \n   x   \n       \n", output.written());
}
