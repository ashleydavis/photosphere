//
// Reading the menu the core describes in JSON.
//

const std = @import("std");

//
// One entry of a menu: an item, a separator, or an item that opens a submenu.
//
pub const MenuItem = struct {
    // The text shown, or null for a separator.
    label: ?[]const u8 = null,
    // The action performed, or null for a separator or an item that opens a submenu.
    action: ?[]const u8 = null,
    // The keyboard shortcut text, such as "CmdOrCtrl+Shift+I", or null for none.
    accelerator: ?[]const u8 = null,
    // True for a separator line.
    separator: bool = false,
    // The entries of the submenu, or null.
    items: ?[]MenuItem = null,
};

//
// One menu of the menu bar.
//
pub const Menu = struct {
    // The text shown in the menu bar.
    label: []const u8,
    // What the menu holds.
    items: []MenuItem,
};

//
// Reads the menu JSON of ziggy_menu_json. The text it holds is valid for as long as the result is.
//
pub fn parseMenu(allocator: std.mem.Allocator, json: []const u8) !std.json.Parsed([]Menu) {
    return std.json.parseFromSlice([]Menu, allocator, json, .{
        .ignore_unknown_fields = true,
    });
}

//
// Writes a menu label for Win32, where & starts a keyboard mnemonic, so a literal & is doubled. The caller owns the result.
//
pub fn escapeLabel(allocator: std.mem.Allocator, label: []const u8) ![]u8 {
    var escaped: std.ArrayList(u8) = .empty;
    errdefer escaped.deinit(allocator);
    for (label) |byte| {
        if (byte == '&') {
            try escaped.append(allocator, '&');
        }
        try escaped.append(allocator, byte);
    }
    return escaped.toOwnedSlice(allocator);
}
