const std = @import("std");
const cli = @import("cli-zig");
const helpers = @import("test-helpers.zig");
const wrapAnsi = cli.wrap_ansi.wrapAnsi;
const stringWidth = cli.string_width.stringWidth;

test "wrapAnsi matches wrap-ansi with hard wrapping and no trimming" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try helpers.loadFixture(allocator, "wrap-ansi.json");
    for (fixture.object.get("wrapCases").?.array.items) |wrapCase| {
        const input = helpers.stringField(wrapCase, "input");
        const columns: usize = @intCast(helpers.intField(wrapCase, "columns"));
        const output = try wrapAnsi(allocator, input, columns);
        std.testing.expectEqualStrings(helpers.stringField(wrapCase, "output"), output) catch |err| {
            std.debug.print("input={f} columns={d}\n", .{ std.json.fmt(input, .{}), columns });
            return err;
        };
    }
}

test "wrapAnsi without a column count only normalizes line endings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a very long line\nnext", try wrapAnsi(arena.allocator(), "a very long line\r\nnext", null));
}

test "stringWidth matches string-width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fixture = try helpers.loadFixture(allocator, "wrap-ansi.json");
    for (fixture.object.get("widthCases").?.array.items) |widthCase| {
        const input = helpers.stringField(widthCase, "input");
        std.testing.expectEqual(@as(usize, @intCast(helpers.intField(widthCase, "width"))), stringWidth(input)) catch |err| {
            std.debug.print("input={f}\n", .{std.json.fmt(input, .{})});
            return err;
        };
    }
}

test "stripAnsi removes SGR codes and hyperlinks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("red", try cli.string_width.stripAnsi(allocator, "\x1b[31mred\x1b[39m"));
    try std.testing.expectEqualStrings("link", try cli.string_width.stripAnsi(allocator, "\x1b]8;;http://x\x07link\x1b]8;;\x07"));
    try std.testing.expectEqualStrings("ab", try cli.string_width.stripAnsi(allocator, "a\x1b[2Kb"));
}
