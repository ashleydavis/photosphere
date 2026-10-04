//
// Keyboard shortcuts: turning the core's parsed shortcut into Windows virtual key codes, matching a key press against it
// and writing it the way a Windows menu shows it.
//

const std = @import("std");

//
// The Control modifier bit. The four modifier bits are the same as the ZIGGY_MOD_ values in ziggy.h, which the shell checks.
//
pub const modifier_control: u32 = 1;

//
// The Shift modifier bit.
//
pub const modifier_shift: u32 = 2;

//
// The Alt modifier bit.
//
pub const modifier_alt: u32 = 4;

//
// The Windows key modifier bit.
//
pub const modifier_windows: u32 = 8;

//
// A keyboard shortcut in the terms of Windows key presses.
//
pub const Binding = struct {
    // The modifier bits that must be held.
    modifiers: u32,
    // The virtual key code of the key.
    virtual_key: u32,
    // The virtual key code of a second key that counts as the same key (the numeric keypad's), or zero for none.
    alternate_virtual_key: u32,
    // True when Shift may be held or not. A plus sign is Shift and the equals key on most keyboards, so a shortcut
    // written with Plus must work either way.
    shift_optional: bool,
};

//
// One name the core gives a key, and the virtual key codes it means.
//
const NamedKey = struct {
    // The name the core uses.
    name: []const u8,
    // How the Windows menu shows it.
    display: []const u8,
    // The virtual key code.
    virtual_key: u32,
    // The numeric keypad's virtual key code for the same key, or zero.
    alternate_virtual_key: u32,
};

//
// Every key the core names that is not a letter, a digit or a function key.
//
const named_keys = [_]NamedKey{
    .{ .name = "plus", .display = "+", .virtual_key = 0xBB, .alternate_virtual_key = 0x6B },
    .{ .name = "equal", .display = "=", .virtual_key = 0xBB, .alternate_virtual_key = 0 },
    .{ .name = "minus", .display = "-", .virtual_key = 0xBD, .alternate_virtual_key = 0x6D },
    .{ .name = "space", .display = "Space", .virtual_key = 0x20, .alternate_virtual_key = 0 },
    .{ .name = "enter", .display = "Enter", .virtual_key = 0x0D, .alternate_virtual_key = 0 },
    .{ .name = "tab", .display = "Tab", .virtual_key = 0x09, .alternate_virtual_key = 0 },
    .{ .name = "escape", .display = "Esc", .virtual_key = 0x1B, .alternate_virtual_key = 0 },
    .{ .name = "up", .display = "Up", .virtual_key = 0x26, .alternate_virtual_key = 0 },
    .{ .name = "down", .display = "Down", .virtual_key = 0x28, .alternate_virtual_key = 0 },
    .{ .name = "left", .display = "Left", .virtual_key = 0x25, .alternate_virtual_key = 0 },
    .{ .name = "right", .display = "Right", .virtual_key = 0x27, .alternate_virtual_key = 0 },
    .{ .name = "home", .display = "Home", .virtual_key = 0x24, .alternate_virtual_key = 0 },
    .{ .name = "end", .display = "End", .virtual_key = 0x23, .alternate_virtual_key = 0 },
    .{ .name = "pageup", .display = "PgUp", .virtual_key = 0x21, .alternate_virtual_key = 0 },
    .{ .name = "pagedown", .display = "PgDn", .virtual_key = 0x22, .alternate_virtual_key = 0 },
    .{ .name = "delete", .display = "Del", .virtual_key = 0x2E, .alternate_virtual_key = 0 },
    .{ .name = "backspace", .display = "Backspace", .virtual_key = 0x08, .alternate_virtual_key = 0 },
};

//
// Returns the function key number (1 to 24) when the name is one, such as "f12", and null otherwise.
//
fn functionKeyNumber(key_name: []const u8) ?u32 {
    if (key_name.len < 2 or key_name[0] != 'f') {
        return null;
    }
    const number = std.fmt.parseInt(u32, key_name[1..], 10) catch {
        return null;
    };
    if (number < 1 or number > 24) {
        return null;
    }
    return number;
}

//
// Builds the binding for the modifier bits and key name the core's parser gave. Returns null for a key name it does not
// know.
//
pub fn bindingFor(modifiers: u32, key_name: []const u8) ?Binding {
    if (key_name.len == 1 and key_name[0] >= 'a' and key_name[0] <= 'z') {
        return .{
            .modifiers = modifiers,
            .virtual_key = std.ascii.toUpper(key_name[0]),
            .alternate_virtual_key = 0,
            .shift_optional = false,
        };
    }
    if (key_name.len == 1 and key_name[0] >= '0' and key_name[0] <= '9') {
        return .{
            .modifiers = modifiers,
            .virtual_key = key_name[0],
            .alternate_virtual_key = 0x60 + @as(u32, key_name[0] - '0'),
            .shift_optional = false,
        };
    }
    if (functionKeyNumber(key_name)) |number| {
        return .{
            .modifiers = modifiers,
            .virtual_key = 0x70 + number - 1,
            .alternate_virtual_key = 0,
            .shift_optional = false,
        };
    }
    for (named_keys) |named| {
        if (std.mem.eql(u8, named.name, key_name)) {
            return .{
                .modifiers = modifiers,
                .virtual_key = named.virtual_key,
                .alternate_virtual_key = named.alternate_virtual_key,
                .shift_optional = std.mem.eql(u8, key_name, "plus"),
            };
        }
    }
    return null;
}

//
// Returns true when a key press is the binding: the key is its key (or its alternate) and the modifiers held are exactly
// its modifiers, except that Shift is ignored when the binding allows either.
//
pub fn matches(binding: Binding, virtual_key: u32, held_modifiers: u32) bool {
    if (virtual_key != binding.virtual_key and (binding.alternate_virtual_key == 0 or virtual_key != binding.alternate_virtual_key)) {
        return false;
    }
    if (binding.shift_optional) {
        return (held_modifiers & ~modifier_shift) == (binding.modifiers & ~modifier_shift);
    }
    return held_modifiers == binding.modifiers;
}

//
// Writes the shortcut the way a Windows menu shows it, such as "Ctrl+Shift+I", into the buffer and returns what it wrote.
// Fails for a key name it does not know, or when the buffer is too small.
//
pub fn formatShortcut(buffer: []u8, modifiers: u32, key_name: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    if (modifiers & modifier_control != 0) {
        try writer.writeAll("Ctrl+");
    }
    if (modifiers & modifier_alt != 0) {
        try writer.writeAll("Alt+");
    }
    if (modifiers & modifier_shift != 0) {
        try writer.writeAll("Shift+");
    }
    if (modifiers & modifier_windows != 0) {
        try writer.writeAll("Win+");
    }
    if (key_name.len == 1) {
        try writer.writeByte(std.ascii.toUpper(key_name[0]));
        return writer.buffered();
    }
    if (functionKeyNumber(key_name)) |number| {
        try writer.print("F{d}", .{number});
        return writer.buffered();
    }
    for (named_keys) |named| {
        if (std.mem.eql(u8, named.name, key_name)) {
            try writer.writeAll(named.display);
            return writer.buffered();
        }
    }
    return error.UnknownKey;
}
