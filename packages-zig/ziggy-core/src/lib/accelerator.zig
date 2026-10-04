//
// Parses the keyboard shortcut text a menu item carries, such as "CmdOrCtrl+Shift+I", into modifiers and a key name, so every
// shell reads shortcuts the same way and each only has to turn the result into its own platform's form.
//
// A shortcut is modifiers and one key joined by plus signs. The modifiers are CmdOrCtrl (Command on MacOS and Control
// everywhere else), Cmd, Ctrl, Alt (also Option) and Shift. The key is a letter, a digit, a function key such as F12, or one of
// Plus, Minus, Equal, Space, Enter, Tab, Escape, Up, Down, Left, Right, Home, End, PageUp, PageDown, Delete and Backspace.
//

const std = @import("std");
const builtin = @import("builtin");

//
// The modifier bits of a parsed shortcut.
//
pub const modifier_ctrl: u32 = 1;
pub const modifier_shift: u32 = 2;
pub const modifier_alt: u32 = 4;
// Command on MacOS, and the Windows or Super key elsewhere.
pub const modifier_meta: u32 = 8;

//
// The longest key name a shortcut can carry.
//
pub const key_capacity: usize = 16;

//
// A parsed shortcut.
//
pub const Accelerator = extern struct {
    // Which modifier keys are held, as a mix of the modifier bits.
    modifiers: u32,
    // The key's name, NUL terminated: a lower case letter or digit, a function key name, or one of the names listed above.
    key: [key_capacity]u8,
};

//
// Why a shortcut could not be read.
//
pub const ParseError = error{
    EmptyShortcut,
    UnknownModifier,
    MissingKey,
    UnknownKey,
};

//
// Parses shortcut text. CmdOrCtrl becomes Command on MacOS and Control elsewhere, decided by what the core was built for.
//
pub fn parse(text: []const u8) ParseError!Accelerator {
    if (text.len == 0) {
        return error.EmptyShortcut;
    }
    var result = Accelerator{
        .modifiers = 0,
        .key = std.mem.zeroes([key_capacity]u8),
    };
    var key_text: ?[]const u8 = null;
    var parts = std.mem.splitScalar(u8, text, '+');
    while (parts.next()) |part| {
        if (key_text != null) {
            // Anything after the key means the key itself was a modifier name or a plus sign that was not spelled Plus.
            return error.UnknownKey;
        }
        if (std.ascii.eqlIgnoreCase(part, "CmdOrCtrl") or std.ascii.eqlIgnoreCase(part, "CommandOrControl")) {
            result.modifiers |= if (builtin.os.tag == .macos) modifier_meta else modifier_ctrl;
        }
        else if (std.ascii.eqlIgnoreCase(part, "Cmd") or std.ascii.eqlIgnoreCase(part, "Command") or std.ascii.eqlIgnoreCase(part, "Super")) {
            result.modifiers |= modifier_meta;
        }
        else if (std.ascii.eqlIgnoreCase(part, "Ctrl") or std.ascii.eqlIgnoreCase(part, "Control")) {
            result.modifiers |= modifier_ctrl;
        }
        else if (std.ascii.eqlIgnoreCase(part, "Alt") or std.ascii.eqlIgnoreCase(part, "Option")) {
            result.modifiers |= modifier_alt;
        }
        else if (std.ascii.eqlIgnoreCase(part, "Shift")) {
            result.modifiers |= modifier_shift;
        }
        else {
            key_text = part;
        }
    }
    const key = key_text orelse {
        return error.MissingKey;
    };
    try writeKey(&result.key, key);
    return result;
}

const named_keys = [_][]const u8{
    "plus", "minus", "equal", "space", "enter", "tab", "escape", "up", "down", "left", "right", "home", "end", "pageup", "pagedown", "delete", "backspace",
};

fn writeKey(destination: *[key_capacity]u8, key: []const u8) ParseError!void {
    if (key.len == 0) {
        return error.MissingKey;
    }
    if (key.len == 1 and std.ascii.isAlphanumeric(key[0])) {
        destination[0] = std.ascii.toLower(key[0]);
        return;
    }
    if ((key[0] == 'F' or key[0] == 'f') and key.len >= 2 and key.len <= 3) {
        const number = std.fmt.parseInt(u8, key[1..], 10) catch {
            return error.UnknownKey;
        };
        if (number >= 1 and number <= 24) {
            destination[0] = 'f';
            @memcpy(destination[1 .. key.len], key[1..]);
            return;
        }
        return error.UnknownKey;
    }
    for (named_keys) |name| {
        if (std.ascii.eqlIgnoreCase(key, name)) {
            for (name, 0..) |character, index| {
                destination[index] = character;
            }
            return;
        }
    }
    return error.UnknownKey;
}
