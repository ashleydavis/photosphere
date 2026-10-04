const std = @import("std");
const menu_keys = @import("../lib/menu-keys.zig");

test "a letter or digit keeps its name" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("i", try menu_keys.gdkKeyName(&buffer, "i"));
    try std.testing.expectEqualStrings("0", try menu_keys.gdkKeyName(&buffer, "0"));
}

test "a function key gets a capital F" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("F12", try menu_keys.gdkKeyName(&buffer, "f12"));
    try std.testing.expectEqualStrings("F1", try menu_keys.gdkKeyName(&buffer, "f1"));
}

test "named keys become the names GDK knows" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("plus", try menu_keys.gdkKeyName(&buffer, "plus"));
    try std.testing.expectEqualStrings("Return", try menu_keys.gdkKeyName(&buffer, "enter"));
    try std.testing.expectEqualStrings("Page_Down", try menu_keys.gdkKeyName(&buffer, "pagedown"));
    try std.testing.expectEqualStrings("BackSpace", try menu_keys.gdkKeyName(&buffer, "backspace"));
}

test "an unknown key is an error" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectError(error.UnknownKey, menu_keys.gdkKeyName(&buffer, "banana"));
}

test "the modifier bits become GDK's flags" {
    try std.testing.expectEqual(@as(c_uint, 0), menu_keys.gdkModifiers(0));
    try std.testing.expectEqual(@as(c_uint, 4), menu_keys.gdkModifiers(1));
    try std.testing.expectEqual(@as(c_uint, 4 | 1), menu_keys.gdkModifiers(1 | 2));
    try std.testing.expectEqual(@as(c_uint, 8), menu_keys.gdkModifiers(4));
    try std.testing.expectEqual(@as(c_uint, 1 << 26), menu_keys.gdkModifiers(8));
}
