const std = @import("std");
const utils = @import("utils-zig");
const state_format = @import("state-format.zig");
const errors = utils.errors;
const isUiStateValue = state_format.isUiStateValue;

//
// The flat key/value view of state.yaml that the interface works in.
//
// The sibling of app-config-format.ts, and the same idea: `IConfig` in user-interface offers get and
// set over a plain string key, and the interface knows nothing about where any of them are kept. This
// module is the one definition of what the state keys mean, which section of state.yaml each one sits
// in, and what it is called on disk.
//
// Nothing decides which of the two files a key belongs to, because nothing has to: the interface has
// a context per store and the caller asks the one it means.
//
// It touches no filesystem, which is what lets it be bundled into the mobile worker. The functions
// that open the file are in state-file.ts.
//
// Like the config view it maps the raw document rather than filled-in defaults, so absent means
// absent and the interface can apply its own default to a key nobody has touched.
//
// (Zig: the YAML documents are std.json.Value objects, as in state-format.zig, and a value one of the flat keys can
// hold is a std.json.Value.)
//

//
// The interface's own keys, under the names the interface uses (the `ui` section of the state file).
//
pub const IUiSection = state_format.IUiSection;

//
// A value one of the flat state keys can hold: a boolean, a number, a string or an array of strings, as a
// std.json.Value. (TypeScript: IAppStateValue is IUiStateValue.)
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

    //
    // Every key above is one this module places in a section of its own. This holds the rest: the
    // interface's own working state, under whatever key the interface chose for it.
    //
    ui: ?IUiSection = null,
};

//
// How many searches the recent list keeps.
//
pub const MAX_RECENT_SEARCHES = 10;

//
// The flat keys this module places in a section of the document.
//
// Everything else the interface asks for goes to the `ui` section under its own name, which is what
// lets a collapsible section store its state under a key built from its id. This list is the only
// thing that decides which of the two a key gets, so a key cannot be read from one place and written
// to another.
//
pub const DECLARED_APP_STATE_KEYS = [_][]const u8{
    "lastFolder",
    "lastDownloadFolder",
    "devToolsOpen",
    "recentSearches",
    "gallerySort",
    "galleryRowHeight",
};

//
// True when the key is one of DECLARED_APP_STATE_KEYS (`DECLARED_APP_STATE_KEYS.includes(key)`).
// (No TypeScript counterpart.)
//
fn isDeclaredKey(key: []const u8) bool {
    for (DECLARED_APP_STATE_KEYS) |declaredKey| {
        if (std.mem.eql(u8, declaredKey, key)) {
            return true;
        }
    }
    return false;
}

//
// Makes a JSON string from an optional string. (No TypeScript counterpart: TypeScript holds the value as it is.)
//
fn optionalString(text: ?[]const u8) ?std.json.Value {
    if (text) |value| {
        return .{
            .string = value,
        };
    }
    return null;
}

//
// Makes a JSON array of strings. (No TypeScript counterpart: TypeScript holds the array as it is.)
//
fn stringsToJson(allocator: std.mem.Allocator, strings: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (strings) |text| {
        try array.append(.{
            .string = text,
        });
    }
    return .{
        .array = array,
    };
}

//
// The strings of a JSON array, or undefined when any element is not a string. (No TypeScript counterpart.)
//
fn stringsFromJson(allocator: std.mem.Allocator, array: std.json.Array) !?[]const []const u8 {
    var strings: std.ArrayList([]const u8) = .empty;
    for (array.items) |entry| {
        if (entry != .string) {
            return null;
        }
        try strings.append(allocator, entry.string);
    }
    return strings.items;
}

//
// True when the value is a finite number (`typeof value === "number" && Number.isFinite(value)`).
// (No TypeScript counterpart.)
//
fn isFiniteNumber(value: std.json.Value) bool {
    return switch (value) {
        .integer => true,
        .float => |float| std.math.isFinite(float),
        .number_string => true,
        else => false,
    };
}

//
// Gets a declared key as the value the flat view holds it as, or undefined when nothing is stored.
// (No TypeScript counterpart: TypeScript indexes the state object by the key.)
//
fn declaredValue(allocator: std.mem.Allocator, state: IAppState, key: []const u8) !?IAppStateValue {
    if (std.mem.eql(u8, key, "lastFolder")) {
        return optionalString(state.lastFolder);
    }
    if (std.mem.eql(u8, key, "lastDownloadFolder")) {
        return optionalString(state.lastDownloadFolder);
    }
    if (std.mem.eql(u8, key, "devToolsOpen")) {
        if (state.devToolsOpen) |devToolsOpen| {
            return .{
                .bool = devToolsOpen,
            };
        }
        return null;
    }
    if (std.mem.eql(u8, key, "recentSearches")) {
        if (state.recentSearches) |recentSearches| {
            return try stringsToJson(allocator, recentSearches);
        }
        return null;
    }
    if (std.mem.eql(u8, key, "gallerySort")) {
        return optionalString(state.gallerySort);
    }
    if (std.mem.eql(u8, key, "galleryRowHeight")) {
        return state.galleryRowHeight;
    }
    unreachable;
}

//
// Reads one flat state key, wherever this module keeps it. undefined when nothing is stored under it.
//
pub fn getAppStateValue(allocator: std.mem.Allocator, state: IAppState, key: []const u8) !?IAppStateValue {
    if (isDeclaredKey(key)) {
        return declaredValue(allocator, state, key);
    }
    if (state.ui) |ui| {
        return ui.get(key);
    }
    return null;
}

//
// Throws that a key was given a value it cannot hold. (No TypeScript counterpart: TypeScript's types refuse the value
// before the program runs, and here the value arrives as JSON.)
//
fn throwCannotHold(key: []const u8, expected: []const u8) errors.ThrownError {
    return errors.throwError("The state key \"{s}\" cannot hold that value, it holds {s}.", .{
        key,
        expected,
    });
}

//
// Stores a value into a declared key. (No TypeScript counterpart: TypeScript assigns the field by the key.)
//
// TypeScript assigns whatever it is given. The value arrives as JSON here, so one of the wrong kind is refused with an
// error naming the key rather than stored where the next read would drop it.
//
fn setDeclaredValue(allocator: std.mem.Allocator, state: *IAppState, key: []const u8, value: IAppStateValue) !void {
    if (std.mem.eql(u8, key, "lastFolder")) {
        if (value != .string) {
            return throwCannotHold(key, "a string");
        }
        state.lastFolder = value.string;
        return;
    }
    if (std.mem.eql(u8, key, "lastDownloadFolder")) {
        if (value != .string) {
            return throwCannotHold(key, "a string");
        }
        state.lastDownloadFolder = value.string;
        return;
    }
    if (std.mem.eql(u8, key, "devToolsOpen")) {
        if (value != .bool) {
            return throwCannotHold(key, "a boolean");
        }
        state.devToolsOpen = value.bool;
        return;
    }
    if (std.mem.eql(u8, key, "recentSearches")) {
        if (value != .array) {
            return throwCannotHold(key, "a list of strings");
        }
        state.recentSearches = try stringsFromJson(allocator, value.array) orelse {
            return throwCannotHold(key, "a list of strings");
        };
        return;
    }
    if (std.mem.eql(u8, key, "gallerySort")) {
        if (value != .string) {
            return throwCannotHold(key, "a string");
        }
        state.gallerySort = value.string;
        return;
    }
    if (std.mem.eql(u8, key, "galleryRowHeight")) {
        if (!isFiniteNumber(value)) {
            return throwCannotHold(key, "a number");
        }
        state.galleryRowHeight = value;
        return;
    }
    unreachable;
}

//
// Removes a declared key. (No TypeScript counterpart: TypeScript deletes the field by the key.)
//
fn clearDeclaredValue(state: *IAppState, key: []const u8) void {
    if (std.mem.eql(u8, key, "lastFolder")) {
        state.lastFolder = null;
    }
    else if (std.mem.eql(u8, key, "lastDownloadFolder")) {
        state.lastDownloadFolder = null;
    }
    else if (std.mem.eql(u8, key, "devToolsOpen")) {
        state.devToolsOpen = null;
    }
    else if (std.mem.eql(u8, key, "recentSearches")) {
        state.recentSearches = null;
    }
    else if (std.mem.eql(u8, key, "gallerySort")) {
        state.gallerySort = null;
    }
    else if (std.mem.eql(u8, key, "galleryRowHeight")) {
        state.galleryRowHeight = null;
    }
    else {
        unreachable;
    }
}

//
// Writes one flat state key, wherever this module keeps it. undefined removes it, which is what
// IConfig.clear means.
//
pub fn setAppStateValue(allocator: std.mem.Allocator, state: *IAppState, key: []const u8, value: ?IAppStateValue) !void {
    if (isDeclaredKey(key)) {
        if (value) |declaredValueToStore| {
            try setDeclaredValue(allocator, state, key, declaredValueToStore);
        }
        else {
            clearDeclaredValue(state, key);
        }
        return;
    }

    if (value == null) {
        if (state.ui) |*ui| {
            _ = ui.orderedRemove(key);
        }
        return;
    }

    // (Zig: TypeScript's types keep anything but a boolean, a number, a string or an array of strings out of here, and
    // the value arrives as JSON, so it is checked.)
    if (!isUiStateValue(value.?)) {
        return throwCannotHold(key, "a boolean, a number, a string or a list of strings");
    }

    if (state.ui == null) {
        state.ui = .empty;
    }
    try state.ui.?.put(allocator, key, value.?);
}

//
// Every state key that has a value, under the name the interface uses for it.
//
// The whole store in one object, for a caller that wants to read by name without knowing which
// section each key sits in. A key kept in the `ui` section appears here beside the declared ones, and
// the two can never collide because setAppStateValue sends a declared key to its own field and
// everything else to `ui`.
//
pub fn appStateSettings(allocator: std.mem.Allocator, state: IAppState) !std.json.ObjectMap {
    var settings: std.json.ObjectMap = .empty;

    for (DECLARED_APP_STATE_KEYS) |key| {
        const value = try declaredValue(allocator, state, key);
        if (value) |declaredValueToList| {
            try settings.put(allocator, key, declaredValueToList);
        }
    }

    if (state.ui) |ui| {
        var iterator = ui.iterator();
        while (iterator.next()) |entry| {
            try settings.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    return settings;
}

//
// True when the value is an object we can read keys off, and not an array or null.
//
fn isSection(value: ?std.json.Value) bool {
    return value != null and value.? == .object;
}

//
// Gets a string field of a section (`typeof section.key === "string"`). (No TypeScript counterpart.)
//
fn stringField(section: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = section.get(key) orelse {
        return null;
    };
    return if (value == .string) value.string else null;
}

//
// Flattens the on-disk document into the key/value view the interface works in.
//
pub fn yamlToAppState(allocator: std.mem.Allocator, document: ?std.json.Value) !IAppState {
    var state: IAppState = .{};
    if (!isSection(document)) {
        return state;
    }

    const parsed = document.?.object;

    if (isSection(parsed.get("desktop"))) {
        const desktop = parsed.get("desktop").?.object;
        if (stringField(desktop, "last_folder")) |lastFolder| {
            state.lastFolder = lastFolder;
        }
        if (stringField(desktop, "last_download_folder")) |lastDownloadFolder| {
            state.lastDownloadFolder = lastDownloadFolder;
        }
        if (desktop.get("dev_tools_open")) |devToolsOpen| {
            if (devToolsOpen == .bool) {
                state.devToolsOpen = devToolsOpen.bool;
            }
        }
    }

    if (isSection(parsed.get("searches"))) {
        const searches = parsed.get("searches").?.object;
        if (searches.get("recent")) |recent| {
            if (recent == .array) {
                var recentSearches: std.ArrayList([]const u8) = .empty;
                for (recent.array.items) |search| {
                    if (search == .string) {
                        try recentSearches.append(allocator, search.string);
                    }
                }
                state.recentSearches = recentSearches.items;
            }
        }
    }

    if (isSection(parsed.get("gallery"))) {
        const gallery = parsed.get("gallery").?.object;
        if (stringField(gallery, "sort")) |sort| {
            state.gallerySort = sort;
        }
        if (gallery.get("row_height")) |rowHeight| {
            if (isFiniteNumber(rowHeight)) {
                state.galleryRowHeight = rowHeight;
            }
        }
    }

    if (isSection(parsed.get("ui"))) {
        var ui: IUiSection = .empty;
        var iterator = parsed.get("ui").?.object.iterator();
        while (iterator.next()) |entry| {
            if (isUiStateValue(entry.value_ptr.*)) {
                try ui.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        state.ui = ui;
    }

    return state;
}

//
// Writes one field into a section, or removes it from the section when it has been cleared.
//
// Removing matters because this view is built from the document: a field that is absent here was
// absent there, so writing "nothing" back has to mean the key goes, or IConfig.clear would report
// success and change nothing on disk.
//
fn writeField(allocator: std.mem.Allocator, section: *std.json.ObjectMap, key: []const u8, value: ?std.json.Value) !void {
    if (value) |fieldValue| {
        try section.put(allocator, key, fieldValue);
        return;
    }
    _ = section.orderedRemove(key);
}

//
// Writes a section into the document, or leaves the document without it when it holds nothing.
//
fn writeSection(allocator: std.mem.Allocator, document: *std.json.ObjectMap, name: []const u8, section: std.json.ObjectMap) !void {
    if (section.count() > 0) {
        try document.put(allocator, name, .{
            .object = section,
        });
        return;
    }
    _ = document.orderedRemove(name);
}

//
// A copy of a section of the document to write into, or an empty one when the document has none that is an object
// (`isSection(merged.desktop) ? { ...merged.desktop } : {}`). (No TypeScript counterpart.)
//
fn copyOfSection(allocator: std.mem.Allocator, merged: std.json.ObjectMap, name: []const u8) !std.json.ObjectMap {
    if (isSection(merged.get(name))) {
        return merged.get(name).?.object.clone(allocator);
    }
    return .empty;
}

//
// Writes the flat view back into the document, leaving everything this view does not own where it is.
//
// The merge matters: the document also carries the news state, which does not appear in the flat view.
// Rebuilding the document from the flat view alone would drop it every time a sidebar section was
// collapsed.
//
pub fn appStateToYaml(allocator: std.mem.Allocator, state: IAppState, document: std.json.Value) !std.json.Value {
    var merged: std.json.ObjectMap = if (isSection(document)) try document.object.clone(allocator) else .empty;

    var desktop = try copyOfSection(allocator, merged, "desktop");
    try writeField(allocator, &desktop, "last_folder", optionalString(state.lastFolder));
    try writeField(allocator, &desktop, "last_download_folder", optionalString(state.lastDownloadFolder));
    try writeField(allocator, &desktop, "dev_tools_open", if (state.devToolsOpen) |devToolsOpen| std.json.Value{
        .bool = devToolsOpen,
    } else null);
    try writeSection(allocator, &merged, "desktop", desktop);

    var searches = try copyOfSection(allocator, merged, "searches");
    try writeField(allocator, &searches, "recent", if (state.recentSearches) |recentSearches| try stringsToJson(allocator, recentSearches) else null);
    try writeSection(allocator, &merged, "searches", searches);

    var gallery = try copyOfSection(allocator, merged, "gallery");
    try writeField(allocator, &gallery, "sort", optionalString(state.gallerySort));
    try writeField(allocator, &gallery, "row_height", state.galleryRowHeight);
    try writeSection(allocator, &merged, "gallery", gallery);

    const ui: IUiSection = if (state.ui) |stateUi| try stateUi.clone(allocator) else .empty;
    try writeSection(allocator, &merged, "ui", ui);

    return .{
        .object = merged,
    };
}
