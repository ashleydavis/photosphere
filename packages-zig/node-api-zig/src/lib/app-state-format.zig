const std = @import("std");
const utils = @import("utils-zig");
const state_format = @import("state-format.zig");
const errors = utils.errors;

//
// The flat key/value view of state.json that the interface works in.
//
// The sibling of app-config-format.zig, and the same idea: `IConfig` in user-interface offers get and
// set over a plain string key, and the interface knows nothing about where any of them are kept. This
// module is the one definition of what the state keys mean, which section of state.json each one sits
// in, and what it is called on disk.
//
// Nothing decides which of the two files a key belongs to, because nothing has to: the interface has
// a context per store and the caller asks the one it means.
//
// It touches no filesystem, which is what lets it be bundled into the mobile worker. The functions
// that open the file are in state-file.zig.
//
// Like the config view it maps the raw document rather than filled-in defaults, so absent means
// absent and the interface can apply its own default to a key nobody has touched.
//
// (Zig: the YAML documents are std.json.Value objects, as in state-format.zig, and a value one of the flat keys can
// hold is a std.json.Value.)
//

//
// A value one of the flat state keys can hold: a boolean, a number, a string or an array of strings, as a
// std.json.Value.
//
pub const IAppStateValue = std.json.Value;

//
// Every state key the interface can reach by name, flattened into one namespace.
//
pub const IAppState = struct {
    //
    // The last folder that was opened in the file dialog.
    //
    lastFolder: ?[]const u8 = null,

    //
    // The last folder used when downloading assets.
    //
    lastDownloadFolder: ?[]const u8 = null,

    //
    // Whether the developer tools were open when the app closed, so they can be reopened on startup.
    //
    devToolsOpen: ?bool = null,

    //
    // Searches recently executed, most recent first.
    //
    recentSearches: ?[]const []const u8 = null,

    //
    // The field the gallery was last sorted by.
    //
    gallerySort: ?[]const u8 = null,

    //
    // The height of a gallery row, in pixels, as the user last dragged it (a number value, as in
    // IGalleryState.rowHeight).
    //
    galleryRowHeight: ?std.json.Value = null,
};

//
// How many searches the recent list keeps.
//
pub const MAX_RECENT_SEARCHES = 10;

