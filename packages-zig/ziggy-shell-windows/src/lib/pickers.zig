//
// The pure parts of the file and folder dialogs: what a kind of dialog asks for, and the answer's JSON.
//

const std = @import("std");

//
// What the core asks the shell to show. The numbers are the ZIGGY_PICK_ values in ziggy.h, which the shell checks.
//
pub const PickKind = enum(i32) {
    // Choose one or more existing files.
    open_files = 0,
    // Choose where to save a file.
    save_file = 1,
    // Choose a folder.
    folder = 2,
};

//
// Returns the kind for the number the core passed, or null when it is not one.
//
pub fn kindFromInt(value: i32) ?PickKind {
    return std.enums.fromInt(PickKind, value);
}

//
// The dialog option bit that allows choosing more than one item. The option bits are the FOS_ values of the Windows
// shell, which the shell checks.
//
pub const option_allow_multiselect: u32 = 0x200;

//
// The dialog option bit that makes the dialog choose a folder instead of a file.
//
pub const option_pick_folders: u32 = 0x20;

//
// The dialog option bit that limits the answer to items in the file system, so each has a path.
//
pub const option_force_file_system: u32 = 0x40;

//
// The dialog option bit that fails the answer when the folder it is in does not exist.
//
pub const option_path_must_exist: u32 = 0x800;

//
// The dialog option bit that fails the answer when the file does not exist.
//
pub const option_file_must_exist: u32 = 0x1000;

//
// The dialog option bit that asks before replacing a file.
//
pub const option_overwrite_prompt: u32 = 0x2;

//
// Returns the dialog options for a kind, keeping the bits the dialog already has.
//
pub fn dialogOptions(kind: PickKind, existing: u32) u32 {
    return existing | switch (kind) {
        .open_files => option_force_file_system | option_allow_multiselect | option_path_must_exist | option_file_must_exist,
        .save_file => option_force_file_system | option_path_must_exist | option_overwrite_prompt,
        .folder => option_force_file_system | option_pick_folders | option_path_must_exist,
    };
}

//
// Returns the dialog title to use when the core gave none.
//
pub fn defaultTitle(kind: PickKind) []const u8 {
    return switch (kind) {
        .open_files => "Open",
        .save_file => "Save",
        .folder => "Choose a folder",
    };
}

//
// Returns the JSON array of the chosen paths, such as ["C:\\a.txt"], with every string escaped. No paths is "[]", which is
// what a cancelled dialog answers. The caller owns the result.
//
pub fn pathsJson(allocator: std.mem.Allocator, paths: []const []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, paths, .{});
}
