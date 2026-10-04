const std = @import("std");
const menu = @import("../lib/menu.zig");

test "menus, separators and submenus are read" {
    const parsed = try menu.parseMenu(std.testing.allocator,
        \\[{"label":"File","items":[
        \\  {"label":"Quit","action":"quit","accelerator":"CmdOrCtrl+Q"},
        \\  {"separator":true},
        \\  {"label":"More","items":[{"label":"Deep","action":"deep"}]}
        \\]}]
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.len);
    try std.testing.expectEqualStrings("File", parsed.value[0].label);
    const items = parsed.value[0].items;
    try std.testing.expectEqualStrings("quit", items[0].action.?);
    try std.testing.expectEqualStrings("CmdOrCtrl+Q", items[0].accelerator.?);
    try std.testing.expect(items[1].separator);
    try std.testing.expectEqualStrings("deep", items[2].items.?[0].action.?);
}

test "an empty menu has no menus" {
    const parsed = try menu.parseMenu(std.testing.allocator, "[]");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.len);
}

test "text that is not a menu is refused" {
    try std.testing.expectError(error.UnexpectedToken, menu.parseMenu(std.testing.allocator, "{}"));
}

test "an ampersand is doubled" {
    const escaped = try menu.escapeLabel(std.testing.allocator, "Save & Close");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("Save && Close", escaped);
}
