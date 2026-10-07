const std = @import("std");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_files = @import("test-files.zig");
const test_environment = @import("test-environment.zig");
const state_file = node_api.state_file;
const state_format = node_api.state_format;
const std_json = std.json;

//
// Points PHOTOSPHERE_CONFIG_DIR at a new empty directory and returns it.
//
fn freshConfigDir(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    _ = try test_environment.setupEnvironment(io);
    const dir = try temp_dirs.makeTempDir(allocator, io, name);
    const configDir = try std.fmt.allocPrint(allocator, "{s}/config", .{dir});
    try test_environment.setEnv("PHOTOSPHERE_CONFIG_DIR", configDir);
    return configDir;
}

//
// Writes the state file in the config directory.
//
fn writeState(allocator: std.mem.Allocator, io: std.Io, configDir: []const u8, text: []const u8) !void {
    try test_files.writeFile(io, try std.fmt.allocPrint(allocator, "{s}/state.yaml", .{configDir}), text);
}

//
// The desktop section as JSON (what the TypeScript tests compare with toEqual).
//
fn desktopJson(allocator: std.mem.Allocator, state: state_format.IStateFile) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, state.desktop, .{ .emit_null_optional_fields = false });
}

//
// loadStateFile hands readYaml whatever is on disk, and yamlToStateFile turns a document that is not one into every
// section's own defaults, so an install that has never run the app reads as empty rather than throwing.
//
test "loadStateFile returns the defaults when the state file does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "state-file-missing");
    defer temp_dirs.removeTempDir(io, configDir);
    try std.Io.Dir.cwd().createDirPath(io, configDir);

    const state = try state_file.loadStateFile(allocator, io);
    try std.testing.expectEqualStrings("{}", try desktopJson(allocator, state));
    try std.testing.expect(state.searches.recentSearches == null);
    try std.testing.expect(state.gallery.sort == null);
    try std.testing.expectEqual(@as(usize, 0), state.news.shownNewsIds.len);
    try std.testing.expectEqual(@as(usize, 0), state.ui.count());
}

//
// A state file the app wrote is read back into the sections it holds, and a section that is not an object falls back to
// its own defaults rather than taking the rest of the document down with it.
//
test "loadStateFile reads the sections of the file and keeps a malformed section out of the way" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const configDir = try freshConfigDir(allocator, io, "state-file-sections");
    defer temp_dirs.removeTempDir(io, configDir);
    try writeState(allocator, io, configDir,
        \\desktop:
        \\  last_folder: /home/me/photos
        \\  dev_tools_open: true
        \\searches: not-a-section
        \\ui:
        \\  sidebar-collapsed: true
        \\  sidebar-size: 320
);

    const state = try state_file.loadStateFile(allocator, io);
    try std.testing.expectEqualStrings("/home/me/photos", state.desktop.lastFolder.?);
    try std.testing.expect(state.desktop.devToolsOpen.?);
    try std.testing.expect(state.desktop.lastDownloadFolder == null);
    try std.testing.expect(state.searches.recentSearches == null);
    try std.testing.expectEqual(@as(usize, 2), state.ui.count());
    try std.testing.expectEqualStrings("sidebar-collapsed", state.ui.keys()[0]);
}

//
// isUiStateValue decides which of the interface's own keys survive a read. A boolean, a number, a string or an array of
// strings is one; an array holding anything else is not, and neither is a nested object, a null or nothing at all. An
// empty array is one, because every element of it is a string.
//
test "isUiStateValue takes booleans, numbers, strings and arrays of strings, and nothing else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expect(state_format.isUiStateValue(.{ .bool = true }));
    try std.testing.expect(state_format.isUiStateValue(.{ .float = 1.5 }));
    try std.testing.expect(state_format.isUiStateValue(.{ .integer = 7 }));
    try std.testing.expect(state_format.isUiStateValue(.{ .string = "value" }));

    var strings = std_json.Array.init(allocator);
    try strings.append(.{ .string = "a" });
    try strings.append(.{ .string = "b" });
    try std.testing.expect(state_format.isUiStateValue(.{ .array = strings }));

    var mixed = std_json.Array.init(allocator);
    try mixed.append(.{ .string = "a" });
    try mixed.append(.{ .bool = true });
    try std.testing.expect(!state_format.isUiStateValue(.{ .array = mixed }));

    var nulls = std_json.Array.init(allocator);
    try nulls.append(.null);
    try std.testing.expect(!state_format.isUiStateValue(.{ .array = nulls }));

    try std.testing.expect(!state_format.isUiStateValue(.null));
    try std.testing.expect(!state_format.isUiStateValue(.{ .object = .empty }));
}

//
// The ui section keeps the keys whose values the interface is allowed to hold and drops the rest, so a nested object or
// a list of numbers left in the file by an older build does not reach the interface.
//
test "yamlToStateFile keeps the interface keys it can hold and drops the ones it cannot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = try std.json.parseFromSliceLeaky(std_json.Value, allocator,
        \\{"ui":{"collapsed":["a"],"width":320,"name":"gallery","numbers":[1,2],"nested":{"a":1},"nothing":null}}
    , .{});
    const state = try state_format.yamlToStateFile(allocator, document);
    try std.testing.expectEqual(@as(usize, 3), state.ui.count());
    try std.testing.expectEqualStrings("collapsed", state.ui.keys()[0]);
    try std.testing.expectEqualStrings("width", state.ui.keys()[1]);
    try std.testing.expectEqualStrings("name", state.ui.keys()[2]);
}