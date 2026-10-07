const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const app_state = node_api.app_state;
const IAppState = app_state.IAppState;

//
// Points PHOTOSPHERE_CONFIG_DIR at a new empty directory and returns it.
//
fn freshConfigDir(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    _ = try test_environment.setupEnvironment(io);
    const dir = try temp_dirs.makeTempDir(allocator, io, name);
    const configDir = try std.fmt.allocPrint(allocator, "{s}/config", .{dir});
    try test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", configDir);
    try std.Io.Dir.cwd().createDirPath(io, configDir);
    return configDir;
}

//
// The path of the state file in the config directory.
//
fn statePath(allocator: std.mem.Allocator, configDir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/state.yaml", .{configDir});
}

//
// Writes the state file in the config directory.
//
fn writeState(allocator: std.mem.Allocator, io: std.Io, configDir: []const u8, text: []const u8) !void {
    try test_files.writeFile(io, try statePath(allocator, configDir), text);
}

//
// The state file as the compact JSON of its document (what the TypeScript tests read from the writeYaml mock).
//
fn documentText(allocator: std.mem.Allocator, io: std.Io, configDir: []const u8) ![]const u8 {
    const document = try node_utils.fs.readYaml(allocator, io, try statePath(allocator, configDir));
    return std.json.Stringify.valueAlloc(allocator, document.?, .{});
}

//
// A mutator that sets devToolsOpen.
//
const DevToolsMutator = struct {
    //
    // Sets devToolsOpen.
    //
    pub fn run(self: *const DevToolsMutator, allocator: std.mem.Allocator, state: *IAppState) !void {
        _ = self;
        _ = allocator;
        state.devToolsOpen = true;
    }
};

//
// A mutator that sets the gallery fields.
//
const GalleryMutator = struct {
    //
    // Sets gallerySort and galleryRowHeight.
    //
    pub fn run(self: *const GalleryMutator, allocator: std.mem.Allocator, state: *IAppState) !void {
        _ = self;
        _ = allocator;
        state.gallerySort = "name";
        state.galleryRowHeight = .{
            .integer = 240,
        };
    }
};

//
// A mutator that stores one key by name, the way a handler for the page's set-state channel does.
//
const SetByNameMutator = struct {
    // The key to store.
    key: []const u8,

    // The value to store, or null to clear the key.
    value: ?std.json.Value,

    //
    // Stores the value under the key.
    //
    pub fn run(self: *const SetByNameMutator, allocator: std.mem.Allocator, state: *IAppState) !void {
        try app_state.setAppStateValue(allocator, state, self.key, self.value);
    }
};

//
// A mutator that fails after changing the state, to show that a failed edit writes nothing.
//
const FailingMutator = struct {
    //
    // Changes the state and then throws.
    //
    pub fn run(self: *const FailingMutator, allocator: std.mem.Allocator, state: *IAppState) !void {
        _ = self;
        _ = allocator;
        state.lastFolder = "/never-written";
        return utils.errors.throwError("The edit was refused.", .{});
    }
};

//
// The state file is what the app remembered so the interface comes back the way it was left. With no file every key is
// absent, and loading it does not create one.
//
test "loadAppState returns an empty state when no file exists and writes nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-missing");
    defer temp_dirs.removeTempDir(io, configDir);

    const state = try app_state.loadAppState(allocator, io);

    try std.testing.expect(state.lastFolder == null);
    try std.testing.expect(state.recentSearches == null);
    try std.testing.expect(state.ui == null);
    try std.testing.expect(!test_files.fileExists(io, try statePath(allocator, configDir)));
}

//
// The snake_case keys of the document come back as the camelCase fields.
//
test "loadAppState converts snake_case document keys to camelCase fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-load");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeState(allocator, io, configDir,
        \\desktop:
        \\  last_folder: /folder
        \\  last_download_folder: /downloads
        \\  dev_tools_open: true
        \\searches:
        \\  recent:
        \\    - cats
        \\gallery:
        \\  sort: name
        \\  row_height: 240
        \\
    );

    const state = try app_state.loadAppState(allocator, io);

    try std.testing.expectEqualStrings("/folder", state.lastFolder.?);
    try std.testing.expectEqualStrings("/downloads", state.lastDownloadFolder.?);
    try std.testing.expect(state.devToolsOpen.?);
    try std.testing.expectEqualStrings("cats", state.recentSearches.?[0]);
    try std.testing.expectEqualStrings("name", state.gallerySort.?);
    try std.testing.expectEqual(@as(i64, 240), state.galleryRowHeight.?.integer);
}

//
// A state file that is not YAML is an error that says so, rather than an empty state that the next edit would then
// overwrite.
//
test "loadAppState throws when the file cannot be parsed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-malformed");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeState(allocator, io, configDir, "desktop: [unclosed\n");

    try std.testing.expectError(error.Thrown, app_state.loadAppState(allocator, io));
}

//
// updateLastFolder sets desktop.last_folder and saves.
//
test "updateLastFolder sets lastFolder and saves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-last-folder");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeState(allocator, io, configDir, "{}\n");

    try app_state.updateLastFolder(allocator, io, "/new/folder");

    try std.testing.expectEqualStrings("{\"desktop\":{\"last_folder\":\"/new/folder\"}}", try documentText(allocator, io, configDir));
}

//
// With no state file the edit creates one.
//
test "updateLastFolder creates the state file when there is none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-create");
    defer temp_dirs.removeTempDir(io, configDir);

    try app_state.updateLastFolder(allocator, io, "/new/folder");

    try std.testing.expectEqualStrings("{\"desktop\":{\"last_folder\":\"/new/folder\"}}", try documentText(allocator, io, configDir));
}

//
// updateLastDownloadFolder sets desktop.last_download_folder and saves.
//
test "updateLastDownloadFolder sets lastDownloadFolder and saves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-last-download");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeState(allocator, io, configDir, "{}\n");

    try app_state.updateLastDownloadFolder(allocator, io, "/downloads");

    try std.testing.expectEqualStrings("{\"desktop\":{\"last_download_folder\":\"/downloads\"}}", try documentText(allocator, io, configDir));
}

//
// updateAppState writes devToolsOpen to dev_tools_open.
//
test "updateAppState writes devToolsOpen to dev_tools_open and loadAppState reads it back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-dev-tools");
    defer temp_dirs.removeTempDir(io, configDir);

    const mutator: DevToolsMutator = .{};
    try app_state.updateAppState(allocator, io, &mutator);

    try std.testing.expectEqualStrings("{\"desktop\":{\"dev_tools_open\":true}}", try documentText(allocator, io, configDir));
    try std.testing.expect((try app_state.loadAppState(allocator, io)).devToolsOpen.?);
}

//
// The gallery view state is written with snake_case keys under gallery.
//
test "updateAppState writes the gallery view state with snake_case keys under gallery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-gallery");
    defer temp_dirs.removeTempDir(io, configDir);

    const mutator: GalleryMutator = .{};
    try app_state.updateAppState(allocator, io, &mutator);

    try std.testing.expectEqualStrings("{\"gallery\":{\"sort\":\"name\",\"row_height\":240}}", try documentText(allocator, io, configDir));
}

//
// A row height that is not a number is dropped rather than handed to the interface.
//
test "loadAppState drops a gallery row height that is not a number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-row-height");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeState(allocator, io, configDir, "gallery:\n  row_height: tall\n");

    try std.testing.expect((try app_state.loadAppState(allocator, io)).galleryRowHeight == null);
}

//
// A mutator that throws leaves the file as it was, and the caller gets its error.
//
test "updateAppState leaves the file alone when the mutator throws" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-failing");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeState(allocator, io, configDir, "gallery:\n  sort: date\n");

    const mutator: FailingMutator = .{};
    try std.testing.expectError(error.Thrown, app_state.updateAppState(allocator, io, &mutator));

    try std.testing.expectEqualStrings("The edit was refused.", utils.errors.lastErrorMessage());
    try std.testing.expectEqualStrings("{\"gallery\":{\"sort\":\"date\"}}", try documentText(allocator, io, configDir));
}

//
// An edit made by key lands where loadAppState finds it, for a declared key and for an interface key, and clearing a
// key takes it off the disk.
//
test "updateAppState stores keys by name, and clearing a key removes it from the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-by-name");
    defer temp_dirs.removeTempDir(io, configDir);

    const setSort: SetByNameMutator = .{
        .key = "gallerySort",
        .value = .{
            .string = "name",
        },
    };
    try app_state.updateAppState(allocator, io, &setSort);
    const setCollapsed: SetByNameMutator = .{
        .key = "sidebar-collapsed-databases",
        .value = .{
            .bool = true,
        },
    };
    try app_state.updateAppState(allocator, io, &setCollapsed);

    try std.testing.expectEqualStrings(
        \\{"gallery":{"sort":"name"},"ui":{"sidebar-collapsed-databases":true}}
    , try documentText(allocator, io, configDir));
    const state = try app_state.loadAppState(allocator, io);
    try std.testing.expectEqualStrings("name", (try app_state.getAppStateValue(allocator, state, "gallerySort")).?.string);
    try std.testing.expect((try app_state.getAppStateValue(allocator, state, "sidebar-collapsed-databases")).?.bool);

    const clearSort: SetByNameMutator = .{
        .key = "gallerySort",
        .value = null,
    };
    try app_state.updateAppState(allocator, io, &clearSort);

    try std.testing.expectEqualStrings(
        \\{"ui":{"sidebar-collapsed-databases":true}}
    , try documentText(allocator, io, configDir));
}

//
// A value a key cannot hold fails the edit with the key named, and writes nothing.
//
test "updateAppState refuses a value a key cannot hold and writes nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-refused");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeState(allocator, io, configDir, "gallery:\n  sort: date\n");

    const mutator: SetByNameMutator = .{
        .key = "gallerySort",
        .value = .{
            .bool = true,
        },
    };
    try std.testing.expectError(error.Thrown, app_state.updateAppState(allocator, io, &mutator));

    try std.testing.expectEqualStrings("The state key \"gallerySort\" cannot hold that value, it holds a string.", utils.errors.lastErrorMessage());
    try std.testing.expectEqualStrings("{\"gallery\":{\"sort\":\"date\"}}", try documentText(allocator, io, configDir));
}

//
// An edit keeps what it does not own, and two edits in turn both survive.
//
test "updateAppState keeps the news state and the other keys across edits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-keeps");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeState(allocator, io, configDir, "news:\n  shown_news_ids:\n    - release-1\n");

    try app_state.updateLastFolder(allocator, io, "/photos");
    try app_state.updateLastDownloadFolder(allocator, io, "/downloads");

    try std.testing.expectEqualStrings(
        \\{"news":{"shown_news_ids":["release-1"]},"desktop":{"last_folder":"/photos","last_download_folder":"/downloads"}}
    , try documentText(allocator, io, configDir));
}

//
// With no recent searches stored the list is empty.
//
test "getRecentSearches returns an empty list when recent is unset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-searches-empty");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeState(allocator, io, configDir, "{}\n");

    try std.testing.expectEqual(@as(usize, 0), (try app_state.getRecentSearches(allocator, io)).len);
}

//
// The stored list comes back in order.
//
test "getRecentSearches returns the stored list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-searches-stored");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeState(allocator, io, configDir, "searches:\n  recent:\n    - cats\n    - dogs\n");

    const searches = try app_state.getRecentSearches(allocator, io);

    try std.testing.expectEqual(@as(usize, 2), searches.len);
    try std.testing.expectEqualStrings("cats", searches[0]);
    try std.testing.expectEqualStrings("dogs", searches[1]);
}

//
// A search already in the list moves to the front rather than appearing twice.
//
test "addRecentSearch deduplicates and prepends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-add-dedupe");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeState(allocator, io, configDir, "searches:\n  recent:\n    - dogs\n    - cats\n");

    try app_state.addRecentSearch(allocator, io, "cats");

    try std.testing.expectEqualStrings("{\"searches\":{\"recent\":[\"cats\",\"dogs\"]}}", try documentText(allocator, io, configDir));
}

//
// A new search goes at the front.
//
test "addRecentSearch prepends a new search at the front" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-add-front");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeState(allocator, io, configDir, "searches:\n  recent:\n    - cats\n");

    try app_state.addRecentSearch(allocator, io, "dogs");

    try std.testing.expectEqualStrings("{\"searches\":{\"recent\":[\"dogs\",\"cats\"]}}", try documentText(allocator, io, configDir));
}

//
// The list keeps only MAX_RECENT_SEARCHES entries, dropping the oldest.
//
test "addRecentSearch caps the list at MAX_RECENT_SEARCHES entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-add-cap");
    defer temp_dirs.removeTempDir(io, configDir);
    var existing: std.ArrayList(u8) = .empty;
    try existing.appendSlice(allocator, "searches:\n  recent:\n");
    for (0..app_state.MAX_RECENT_SEARCHES) |searchIndex| {
        try existing.appendSlice(allocator, try std.fmt.allocPrint(allocator, "    - search{d}\n", .{searchIndex}));
    }
    try writeState(allocator, io, configDir, existing.items);

    try app_state.addRecentSearch(allocator, io, "newest");

    const searches = try app_state.getRecentSearches(allocator, io);
    try std.testing.expectEqual(@as(usize, app_state.MAX_RECENT_SEARCHES), searches.len);
    try std.testing.expectEqualStrings("newest", searches[0]);
    const oldest = try std.fmt.allocPrint(allocator, "search{d}", .{app_state.MAX_RECENT_SEARCHES - 1});
    for (searches) |search| {
        try std.testing.expect(!std.mem.eql(u8, search, oldest));
    }
}

//
// With no file the first search creates the list.
//
test "addRecentSearch starts the list when nothing is stored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-add-first");
    defer temp_dirs.removeTempDir(io, configDir);

    try app_state.addRecentSearch(allocator, io, "cats");

    try std.testing.expectEqualStrings("{\"searches\":{\"recent\":[\"cats\"]}}", try documentText(allocator, io, configDir));
}

//
// removeRecentSearch filters out the given search.
//
test "removeRecentSearch filters out the given search" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-remove");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeState(allocator, io, configDir, "searches:\n  recent:\n    - cats\n    - dogs\n    - birds\n");

    try app_state.removeRecentSearch(allocator, io, "dogs");

    try std.testing.expectEqualStrings("{\"searches\":{\"recent\":[\"cats\",\"birds\"]}}", try documentText(allocator, io, configDir));
}

//
// Removing a search that is not in the list leaves the list as it was.
//
test "removeRecentSearch leaves the list alone when the search is not in it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-remove-missing");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeState(allocator, io, configDir, "searches:\n  recent:\n    - cats\n");

    try app_state.removeRecentSearch(allocator, io, "dogs");

    try std.testing.expectEqualStrings("{\"searches\":{\"recent\":[\"cats\"]}}", try documentText(allocator, io, configDir));
}

//
// Each key a folder picker is allowed to use comes back as itself.
//
test "asFolderStateKey returns each of the keys a folder picker is allowed to use" {
    for (app_state.FOLDER_STATE_KEYS) |folderKey| {
        try std.testing.expectEqual(folderKey, try app_state.asFolderStateKey(@tagName(folderKey)));
    }
}

//
// A key the state does not hold is refused, and the message names the keys it does accept so it says how to fix it.
//
test "asFolderStateKey throws on a key the state does not hold and names the keys it accepts" {
    try std.testing.expectError(error.Thrown, app_state.asFolderStateKey("lastFolde"));
    try std.testing.expectEqualStrings(
        "Unknown folder state key \"lastFolde\". Expected one of: lastFolder, lastDownloadFolder.",
        utils.errors.lastErrorMessage(),
    );

    try std.testing.expectError(error.Thrown, app_state.asFolderStateKey("theme"));
    try std.testing.expectEqualStrings(
        "Unknown folder state key \"theme\". Expected one of: lastFolder, lastDownloadFolder.",
        utils.errors.lastErrorMessage(),
    );
}

//
// An empty key is refused rather than treated as the default.
//
test "asFolderStateKey throws on an empty key" {
    try std.testing.expectError(error.Thrown, app_state.asFolderStateKey(""));
    try std.testing.expectEqualStrings(
        "Unknown folder state key \"\". Expected one of: lastFolder, lastDownloadFolder.",
        utils.errors.lastErrorMessage(),
    );
}

//
// The folder remembered under each key comes back for that key.
//
test "getFolderPath reads the folder remembered under the given key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-folder-read");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeState(allocator, io, configDir, "desktop:\n  last_folder: /photos\n  last_download_folder: /downloads\n");

    try std.testing.expectEqualStrings("/photos", (try app_state.getFolderPath(allocator, io, "lastFolder")).?);
    try std.testing.expectEqualStrings("/downloads", (try app_state.getFolderPath(allocator, io, "lastDownloadFolder")).?);
}

//
// Nothing remembered under a key, or no file at all, reads as undefined.
//
test "getFolderPath returns undefined when nothing is remembered under the key or there is no file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-folder-none");
    defer temp_dirs.removeTempDir(io, configDir);

    try std.testing.expect((try app_state.getFolderPath(allocator, io, "lastFolder")) == null);

    try writeState(allocator, io, configDir, "desktop:\n  last_folder: /photos\n");
    try std.testing.expect((try app_state.getFolderPath(allocator, io, "lastDownloadFolder")) == null);
}

//
// An unrecognised key is refused before the file is opened. The file here cannot be parsed, so a read would throw a
// different error.
//
test "getFolderPath throws on an unknown key without reading the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-folder-unknown");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeState(allocator, io, configDir, "desktop: [unclosed\n");

    try std.testing.expectError(error.Thrown, app_state.getFolderPath(allocator, io, "nonsense"));

    try std.testing.expectEqualStrings(
        "Unknown folder state key \"nonsense\". Expected one of: lastFolder, lastDownloadFolder.",
        utils.errors.lastErrorMessage(),
    );
}

//
// The chosen folder is written under the key it was chosen for.
//
test "updateFolderPath writes the chosen folder under the given key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-folder-write");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeState(allocator, io, configDir, "{}\n");

    try app_state.updateFolderPath(allocator, io, "lastDownloadFolder", "/new/downloads");

    try std.testing.expectEqualStrings("{\"desktop\":{\"last_download_folder\":\"/new/downloads\"}}", try documentText(allocator, io, configDir));
}

//
// The folder previously remembered under the key is replaced.
//
test "updateFolderPath replaces the folder previously remembered under that key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-folder-replace");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeState(allocator, io, configDir, "desktop:\n  last_folder: /old\n");

    try app_state.updateFolderPath(allocator, io, "lastFolder", "/new");

    try std.testing.expectEqualStrings("{\"desktop\":{\"last_folder\":\"/new\"}}", try documentText(allocator, io, configDir));
}

//
// A folder picker stays open for as long as the user takes to choose, so the file is written against its current
// contents rather than a copy read before the dialog opened.
//
test "updateFolderPath leaves everything else alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-folder-keeps");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeState(allocator, io, configDir, "gallery:\n  sort: name\nnews:\n  shown_news_ids:\n    - release-1\n");

    try app_state.updateFolderPath(allocator, io, "lastFolder", "/new/photos");

    try std.testing.expectEqualStrings(
        \\{"gallery":{"sort":"name"},"news":{"shown_news_ids":["release-1"]},"desktop":{"last_folder":"/new/photos"}}
    , try documentText(allocator, io, configDir));
}

//
// An unknown key writes nothing, not even an empty state file.
//
test "updateFolderPath throws on an unknown key and writes nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-folder-write-unknown");
    defer temp_dirs.removeTempDir(io, configDir);

    try std.testing.expectError(error.Thrown, app_state.updateFolderPath(allocator, io, "nonsense", "/x"));

    try std.testing.expectEqualStrings(
        "Unknown folder state key \"nonsense\". Expected one of: lastFolder, lastDownloadFolder.",
        utils.errors.lastErrorMessage(),
    );
    try std.testing.expect(!test_files.fileExists(io, try statePath(allocator, configDir)));
}

test "getStatePath returns a string ending with state.yaml, beside the config file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "app-state-path");
    defer temp_dirs.removeTempDir(io, configDir);

    const result = try node_api.state_file.getStatePath(allocator);

    try std.testing.expect(std.mem.endsWith(u8, result, "state.yaml"));
    try std.testing.expectEqualStrings(try statePath(allocator, configDir), result);
}
