const std = @import("std");
const actions = @import("../lib/actions.zig");

test "the shell's own actions are recognised by name" {
    try std.testing.expectEqual(actions.Action.quit, actions.fromName("quit").?);
    try std.testing.expectEqual(actions.Action.toggle_devtools, actions.fromName("toggle-devtools").?);
    try std.testing.expectEqual(actions.Action.select_all, actions.fromName("select-all").?);
    try std.testing.expectEqual(actions.Action.zoom_reset, actions.fromName("zoom-reset").?);
    try std.testing.expectEqual(@as(?actions.Action, null), actions.fromName("start-short"));
}

test "editing actions name an execCommand command" {
    try std.testing.expectEqualStrings("selectAll", actions.editCommand(.select_all).?);
    try std.testing.expectEqualStrings("paste", actions.editCommand(.paste).?);
    try std.testing.expectEqual(@as(?[]const u8, null), actions.editCommand(.reload));
}

test "zoom steps by a tenth and stays in range" {
    try std.testing.expectEqual(@as(f64, 1.1), actions.nextZoom(1.0, 1));
    try std.testing.expectEqual(@as(f64, 0.9), actions.nextZoom(1.0, -1));
    try std.testing.expectEqual(@as(f64, 1.0), actions.nextZoom(2.3, 0));
    try std.testing.expectEqual(@as(f64, 5.0), actions.nextZoom(5.0, 1));
    try std.testing.expectEqual(@as(f64, 0.25), actions.nextZoom(0.3, -1));
}

test "repeated zoom steps do not drift" {
    var zoom: f64 = 1.0;
    for (0..7) |_| {
        zoom = actions.nextZoom(zoom, 1);
    }
    try std.testing.expectEqual(@as(f64, 1.7), zoom);
}

test "an app action becomes a menu-action message" {
    const message = try actions.menuActionMessage(std.testing.allocator, "about");
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("{\"channel\":\"menu-action\",\"data\":{\"action\":\"about\"}}", message);
}

test "an action name with quotes is escaped" {
    const message = try actions.menuActionMessage(std.testing.allocator, "a\"b");
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("{\"channel\":\"menu-action\",\"data\":{\"action\":\"a\\\"b\"}}", message);
}

test "pasted text becomes an insertText command with the text escaped" {
    const script = try actions.pasteScript(std.testing.allocator, "a \"b\"\nc");
    defer std.testing.allocator.free(script);
    try std.testing.expectEqualStrings("document.execCommand('insertText', false, \"a \\\"b\\\"\\nc\");", script);
}

test "the selected text is read from the script's JSON result" {
    const text = try actions.selectionText(std.testing.allocator, "\"hello\\nworld\"");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello\nworld", text);
}

test "a script result that is not a string is refused" {
    try std.testing.expectError(error.UnexpectedToken, actions.selectionText(std.testing.allocator, "null"));
}
