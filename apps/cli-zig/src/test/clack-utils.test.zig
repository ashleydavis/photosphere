const std = @import("std");
const cli = @import("cli-zig");
const prompts = cli.prompts;
const core_utils = @import("cli-zig").prompts.common;

test "diffLines returns the indexes of the changed lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const diffLines = @import("cli-zig").clack_core.utils.diffLines;
    try std.testing.expect(try diffLines(allocator, "a\nb", "a\nb") == null);
    const diff = (try diffLines(allocator, "a\nb\nc", "a\nx\nc\nd")).?;
    try std.testing.expectEqualSlices(usize, &.{ 1, 3 }, diff);
}

test "isActionKey recognises the cancel aliases" {
    const settings = @import("cli-zig").clack_core.utils.settings;
    try std.testing.expect(settings.isActionKey(&.{ "\x03", "c", "\x03" }, .cancel));
    try std.testing.expect(settings.isActionKey(&.{ null, "escape", null }, .cancel));
    try std.testing.expect(!settings.isActionKey(&.{ "k", "k", "k" }, .cancel));
    try std.testing.expectEqual(settings.Action.up, settings.aliasAction("k").?);
    try std.testing.expectEqual(settings.Action.space, settings.actionNamed("space").?);
    try std.testing.expect(settings.actionNamed("tab") == null);
}

test "limitOptions shows a window with ellipses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    cli.picocolors.setColorSupportOverride(false);
    defer cli.picocolors.setColorSupportOverride(null);
    const Style = struct {
        fn style(styleAllocator: std.mem.Allocator, context: *anyopaque, option: []const u8, active: bool) anyerror![]const u8 {
            _ = context;
            return std.fmt.allocPrint(styleAllocator, "{s}{s}", .{ if (active) ">" else " ", option });
        }
    };
    var context: u8 = 0;
    const options = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };
    const lines = try prompts.limitOptions([]const u8, allocator, .{
        .options = &options,
        .maxItems = null,
        .cursor = 7,
        .rows = 10,
        .style = Style.style,
        .styleContext = &context,
    });
    try std.testing.expectEqual(@as(usize, 6), lines.len);
    try std.testing.expectEqualStrings("...", lines[0]);
    try std.testing.expectEqualStrings(">7", lines[3]);
    try std.testing.expectEqualStrings(" 9", lines[5]);
    const middle = try prompts.limitOptions([]const u8, allocator, .{
        .options = &options,
        .maxItems = 5,
        .cursor = 4,
        .rows = null,
        .style = Style.style,
        .styleContext = &context,
    });
    try std.testing.expectEqual(@as(usize, 5), middle.len);
    try std.testing.expectEqualStrings("...", middle[0]);
    try std.testing.expectEqualStrings(">4", middle[2]);
    try std.testing.expectEqualStrings("...", middle[4]);
}

test "the unicode symbols are used unless TERM is linux" {
    const node_utils = @import("node-utils-zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(arena.allocator());
    try environ_map.put("TERM", "linux");
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);
    try std.testing.expect(!core_utils.isUnicodeSupported());
    try std.testing.expectEqualStrings("*", core_utils.S_STEP_ACTIVE());
    try environ_map.put("TERM", "xterm-256color");
    try std.testing.expect(core_utils.isUnicodeSupported());
    try std.testing.expectEqualStrings("\u{25C6}", core_utils.S_STEP_ACTIVE());
}
