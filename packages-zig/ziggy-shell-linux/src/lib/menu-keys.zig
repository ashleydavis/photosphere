//
// Turns the shortcut parts the core parses (see ziggy_parse_accelerator in ziggy.h) into what GTK wants: a key name that
// gdk_keyval_from_name understands, and GDK modifier flags.
//

const std = @import("std");

//
// The modifier bits the core uses. These match the ZIGGY_MOD_ values in ziggy.h.
//
const ziggy_mod_ctrl: u32 = 1;
const ziggy_mod_shift: u32 = 2;
const ziggy_mod_alt: u32 = 4;
const ziggy_mod_meta: u32 = 8;

//
// GDK's modifier flags, from gdktypes.h.
//
const gdk_shift_mask: c_uint = 1 << 0;
const gdk_control_mask: c_uint = 1 << 2;
const gdk_alt_mask: c_uint = 1 << 3;
const gdk_super_mask: c_uint = 1 << 26;

//
// The GDK name of each of the core's named keys.
//
const named_keys = [_]struct {
    // The core's name for the key.
    core_name: []const u8,
    // The name GDK knows it by.
    gdk_name: []const u8,
}{
    .{ .core_name = "plus", .gdk_name = "plus" },
    .{ .core_name = "minus", .gdk_name = "minus" },
    .{ .core_name = "equal", .gdk_name = "equal" },
    .{ .core_name = "space", .gdk_name = "space" },
    .{ .core_name = "enter", .gdk_name = "Return" },
    .{ .core_name = "tab", .gdk_name = "Tab" },
    .{ .core_name = "escape", .gdk_name = "Escape" },
    .{ .core_name = "up", .gdk_name = "Up" },
    .{ .core_name = "down", .gdk_name = "Down" },
    .{ .core_name = "left", .gdk_name = "Left" },
    .{ .core_name = "right", .gdk_name = "Right" },
    .{ .core_name = "home", .gdk_name = "Home" },
    .{ .core_name = "end", .gdk_name = "End" },
    .{ .core_name = "pageup", .gdk_name = "Page_Up" },
    .{ .core_name = "pagedown", .gdk_name = "Page_Down" },
    .{ .core_name = "delete", .gdk_name = "Delete" },
    .{ .core_name = "backspace", .gdk_name = "BackSpace" },
};

//
// The GDK name for a key the core named: a letter or digit stays as it is, f12 becomes F12, and the rest are looked up.
// The name is written into the buffer, NUL terminated, and the slice returned excludes the NUL.
//
pub fn gdkKeyName(buffer: *[32]u8, core_key: []const u8) error{UnknownKey}![:0]const u8 {
    if (core_key.len == 1) {
        buffer[0] = core_key[0];
        buffer[1] = 0;
        return buffer[0..1 :0];
    }
    if (core_key.len >= 2 and core_key[0] == 'f' and std.ascii.isDigit(core_key[1])) {
        buffer[0] = 'F';
        @memcpy(buffer[1..core_key.len], core_key[1..]);
        buffer[core_key.len] = 0;
        return buffer[0..core_key.len :0];
    }
    for (named_keys) |entry| {
        if (std.mem.eql(u8, entry.core_name, core_key)) {
            @memcpy(buffer[0..entry.gdk_name.len], entry.gdk_name);
            buffer[entry.gdk_name.len] = 0;
            return buffer[0..entry.gdk_name.len :0];
        }
    }
    return error.UnknownKey;
}

//
// GDK's modifier flags for the core's modifier bits.
//
pub fn gdkModifiers(core_modifiers: u32) c_uint {
    var result: c_uint = 0;
    if (core_modifiers & ziggy_mod_ctrl != 0) {
        result |= gdk_control_mask;
    }
    if (core_modifiers & ziggy_mod_shift != 0) {
        result |= gdk_shift_mask;
    }
    if (core_modifiers & ziggy_mod_alt != 0) {
        result |= gdk_alt_mask;
    }
    if (core_modifiers & ziggy_mod_meta != 0) {
        result |= gdk_super_mask;
    }
    return result;
}
