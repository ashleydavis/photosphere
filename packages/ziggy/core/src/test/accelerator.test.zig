const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy-core");

const accelerator = ziggy.accelerator;

fn keyText(parsed: *const accelerator.Accelerator) []const u8 {
    return std.mem.sliceTo(&parsed.key, 0);
}

test "a letter with CmdOrCtrl and Shift" {
    const parsed = try accelerator.parse("CmdOrCtrl+Shift+I");
    const command_or_control = if (builtin.os.tag == .macos) accelerator.modifier_meta else accelerator.modifier_ctrl;
    try std.testing.expectEqual(command_or_control | accelerator.modifier_shift, parsed.modifiers);
    try std.testing.expectEqualStrings("i", keyText(&parsed));
}

test "a bare function key" {
    const parsed = try accelerator.parse("F12");
    try std.testing.expectEqual(@as(u32, 0), parsed.modifiers);
    try std.testing.expectEqualStrings("f12", keyText(&parsed));
}

test "Ctrl, Alt and Cmd are each their own modifier, in any case" {
    const parsed = try accelerator.parse("ctrl+ALT+cmd+x");
    try std.testing.expectEqual(accelerator.modifier_ctrl | accelerator.modifier_alt | accelerator.modifier_meta, parsed.modifiers);
    try std.testing.expectEqualStrings("x", keyText(&parsed));
}

test "named keys, digits and Plus are read" {
    try std.testing.expectEqualStrings("plus", keyText(&(try accelerator.parse("CmdOrCtrl+Plus"))));
    try std.testing.expectEqualStrings("minus", keyText(&(try accelerator.parse("CmdOrCtrl+Minus"))));
    try std.testing.expectEqualStrings("0", keyText(&(try accelerator.parse("CmdOrCtrl+0"))));
    try std.testing.expectEqualStrings("escape", keyText(&(try accelerator.parse("Escape"))));
    try std.testing.expectEqualStrings("pagedown", keyText(&(try accelerator.parse("Alt+PageDown"))));
}

test "bad shortcuts are errors that say what is wrong" {
    try std.testing.expectError(error.EmptyShortcut, accelerator.parse(""));
    try std.testing.expectError(error.MissingKey, accelerator.parse("Ctrl+Shift"));
    try std.testing.expectError(error.UnknownKey, accelerator.parse("Ctrl+Banana"));
    try std.testing.expectError(error.UnknownKey, accelerator.parse("Ctrl+F99"));
    try std.testing.expectError(error.UnknownKey, accelerator.parse("Ctrl+A+B"));
}
