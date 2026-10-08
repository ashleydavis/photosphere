const std = @import("std");
const api = @import("api-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const auto_import_desktop = node_api.auto_import_desktop;
const app_config = node_api.app_config;

const IAutoImportSource = api.auto_import_settings.IAutoImportSource;
const IAppConfig = app_config.IAppConfig;
const planDesktopAutoImport = auto_import_desktop.planDesktopAutoImport;
const foldersAsSources = auto_import_desktop.foldersAsSources;
const getDefaultDatabasePath = auto_import_desktop.getDefaultDatabasePath;

const APP_DATA_PATH = "/home/someone/.config/Photosphere";
const PHOTO_FOLDERS = [_][]const u8{"/home/someone/Pictures"};

fn expectFolderSource(source: IAutoImportSource, expected_path: []const u8, expected_recurse: bool) !void {
    try std.testing.expectEqualStrings("folder", source.sourceType());
    try std.testing.expectEqualStrings(expected_path, source.folder.path);
    try std.testing.expectEqual(expected_recurse, source.folder.recurse);
}

test "planDesktopAutoImport does not run when automatic import has never been switched on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const plan = try planDesktopAutoImport(arena.allocator(), .{}, &PHOTO_FOLDERS, APP_DATA_PATH);
    try std.testing.expect(!plan.shouldRun);
}

test "planDesktopAutoImport does not run when automatic import is switched off" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config: IAppConfig = .{ .autoImportEnabled = false };
    try std.testing.expect(!(try planDesktopAutoImport(arena.allocator(), config, &PHOTO_FOLDERS, APP_DATA_PATH)).shouldRun);
}

test "planDesktopAutoImport runs when automatic import is switched on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config: IAppConfig = .{ .autoImportEnabled = true };
    try std.testing.expect((try planDesktopAutoImport(arena.allocator(), config, &PHOTO_FOLDERS, APP_DATA_PATH)).shouldRun);
}

test "planDesktopAutoImport does not run when there is nothing at all to watch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config: IAppConfig = .{ .autoImportEnabled = true };
    const plan = try planDesktopAutoImport(arena.allocator(), config, &.{}, APP_DATA_PATH);
    try std.testing.expect(!plan.shouldRun);
    try std.testing.expectEqual(@as(usize, 0), plan.settings.sources.len);
}

test "planDesktopAutoImport falls back to the operating system's photo folders when none are configured" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config: IAppConfig = .{ .autoImportEnabled = true };
    const folders = [_][]const u8{ "/home/someone/Pictures", "/home/someone/Camera" };
    const plan = try planDesktopAutoImport(arena.allocator(), config, &folders, APP_DATA_PATH);
    try std.testing.expectEqual(@as(usize, 2), plan.settings.sources.len);
    try expectFolderSource(plan.settings.sources[0], "/home/someone/Pictures", true);
    try expectFolderSource(plan.settings.sources[1], "/home/someone/Camera", true);
}

test "planDesktopAutoImport uses the configured places rather than the operating system's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const stored = [_]IAutoImportSource{.{ .folder = .{ .path = "/mnt/photos", .recurse = false } }};
    const config: IAppConfig = .{
        .autoImportEnabled = true,
        .autoImportSources = &stored,
    };
    const plan = try planDesktopAutoImport(arena.allocator(), config, &PHOTO_FOLDERS, APP_DATA_PATH);
    try std.testing.expectEqual(@as(usize, 1), plan.settings.sources.len);
    try expectFolderSource(plan.settings.sources[0], "/mnt/photos", false);
}

test "planDesktopAutoImport chooses the default database location when none has been chosen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config: IAppConfig = .{ .autoImportEnabled = true };
    const plan = try planDesktopAutoImport(arena.allocator(), config, &PHOTO_FOLDERS, APP_DATA_PATH);
    try std.testing.expect(plan.isNewDefault);
    // Joined as the TypeScript test does (`path.join`): the Windows job failed expecting "/" separators.
    try std.testing.expectEqualStrings(try node_utils.path.join(arena.allocator(), &.{ APP_DATA_PATH, auto_import_desktop.DEFAULT_DATABASE_FOLDER_NAME }), plan.databasePath);
}

test "planDesktopAutoImport uses the chosen default database when there is one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config: IAppConfig = .{
        .autoImportEnabled = true,
        .defaultDatabasePath = "/home/someone/my-photos",
    };
    const plan = try planDesktopAutoImport(arena.allocator(), config, &PHOTO_FOLDERS, APP_DATA_PATH);
    try std.testing.expect(!plan.isNewDefault);
    try std.testing.expectEqualStrings("/home/someone/my-photos", plan.databasePath);
}

test "planDesktopAutoImport counts an empty stored default as none chosen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const config: IAppConfig = .{
        .autoImportEnabled = true,
        .defaultDatabasePath = "",
    };
    const plan = try planDesktopAutoImport(arena.allocator(), config, &PHOTO_FOLDERS, APP_DATA_PATH);
    try std.testing.expect(plan.isNewDefault);
    // Joined as the TypeScript test does (`path.join`): the Windows job failed expecting "/" separators.
    try std.testing.expectEqualStrings(try node_utils.path.join(arena.allocator(), &.{ APP_DATA_PATH, auto_import_desktop.DEFAULT_DATABASE_FOLDER_NAME }), plan.databasePath);
}

test "foldersAsSources turns folder paths into recursive folder sources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const folders = [_][]const u8{ "/one", "/two" };
    const sources = try foldersAsSources(arena.allocator(), &folders);
    try std.testing.expectEqual(@as(usize, 2), sources.len);
    try expectFolderSource(sources[0], "/one", true);
    try expectFolderSource(sources[1], "/two", true);
}

test "foldersAsSources with no folders gives no sources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try foldersAsSources(arena.allocator(), &.{})).len);
}

test "getDefaultDatabasePath sits under the application data directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Joined as the TypeScript test does (`path.join`): the Windows job failed expecting "/data/photosphere-default".
    try std.testing.expectEqualStrings(try node_utils.path.join(arena.allocator(), &.{ "/data", auto_import_desktop.DEFAULT_DATABASE_FOLDER_NAME }), try getDefaultDatabasePath(arena.allocator(), "/data"));
}

// A stored source cannot be malformed once it is typed, so the malformed entry goes in as the document the config is
// read from, as it would from the file.
test "planDesktopAutoImport drops a malformed stored source rather than failing to start" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const document = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        "{\"auto_import\":{\"enabled\":true,\"sources\":[{\"type\":\"folder\"},{\"type\":\"folder\",\"path\":\"/mnt/photos\",\"recurse\":true}]}}",
        .{},
    );
    const config = try node_api.app_config_format.yamlToAppConfig(allocator, document);

    const plan = try planDesktopAutoImport(allocator, config, &PHOTO_FOLDERS, APP_DATA_PATH);

    try std.testing.expectEqual(@as(usize, 1), plan.settings.sources.len);
    try expectFolderSource(plan.settings.sources[0], "/mnt/photos", true);
}
