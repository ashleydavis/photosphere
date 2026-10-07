const std = @import("std");
const node_utils = @import("node-utils-zig");
const api = @import("api-zig");
const app_config = @import("app-config.zig");
const path = node_utils.path;
const auto_import_settings = api.auto_import_settings;
const IAutoImportSettings = auto_import_settings.IAutoImportSettings;
const IAutoImportSource = auto_import_settings.IAutoImportSource;
const IAppConfig = app_config.IAppConfig;

//
// What the desktop app should do about automatic import, worked out from its config alone.
//
// The decisions live here rather than in the Electron main process so they can be unit tested: the
// main process is left with the parts that genuinely need Electron (where the application data
// directory is) and the parts that need the worker pool (creating the database, starting the task).
//

//
// The folder the default private database is created in, under the application data directory.
//
pub const DEFAULT_DATABASE_FOLDER_NAME = "photosphere-default";

//
// The name the default private database is listed under.
//
pub const DEFAULT_DATABASE_DISPLAY_NAME = "My Photos";

//
// The source tag every automatic import task is queued under, so it can be cancelled as a group
// when the setting is switched off or the app quits.
//
pub const AUTO_IMPORT_TASK_SOURCE = "auto-import";

//
// What the main process should do about automatic import right now.
//
pub const IDesktopAutoImportPlan = struct {
    // Whether the automatic import task should be running at all.
    shouldRun: bool,

    // The database automatic import writes to.
    databasePath: []const u8,

    // True when no default database has been chosen yet, so the path above is where a new one goes.
    isNewDefault: bool,

    // The settings the task should run with.
    settings: IAutoImportSettings,
};

//
// Turns the operating system's photo folders into watched sources.
//
pub fn foldersAsSources(allocator: std.mem.Allocator, folderPaths: []const []const u8) ![]const IAutoImportSource {
    const sources = try allocator.alloc(IAutoImportSource, folderPaths.len);
    for (folderPaths, 0..) |folderPath, index| {
        sources[index] = .{
            .folder = .{
                .path = folderPath,
                .recurse = true,
            },
        };
    }
    return sources;
}

//
// Where the default private database goes when the user has not chosen one.
//
pub fn getDefaultDatabasePath(allocator: std.mem.Allocator, appDataPath: []const u8) ![]const u8 {
    return path.join(allocator, &.{ appDataPath, DEFAULT_DATABASE_FOLDER_NAME });
}

//
// Decides what the main process should do about automatic import.
//
// When the user has switched automatic import on but named no places to watch, the operating
// system's own photo folders are used. Running with no sources at all would import nothing while
// looking like it was working, which is the worst of both.
// (Zig: a malformed stored source cannot reach this function. The config's sources are typed, and the config reader
// already drops a malformed one when it reads the file, so the normaliser below sees only well formed sources.)
//
pub fn planDesktopAutoImport(allocator: std.mem.Allocator, config: IAppConfig, defaultPhotoFolders: []const []const u8, appDataPath: []const u8) !IDesktopAutoImportPlan {
    const storedSources: []const IAutoImportSource = config.autoImportSources orelse &.{};

    // (Zig: the settings are normalised from the JSON the TypeScript builds as an object literal. `enabled` is left out when the
    // config has no value for it, as `undefined` is not a boolean to normaliseAutoImportSettings.)
    var rawSettings: std.json.ObjectMap = .empty;
    if (config.autoImportEnabled) |enabled| {
        try rawSettings.put(allocator, "enabled", .{ .bool = enabled });
    }
    try rawSettings.put(allocator, "sources", try auto_import_settings.autoImportSourcesToJson(allocator, storedSources));
    var settings = try auto_import_settings.normaliseAutoImportSettings(allocator, .{ .object = rawSettings });

    if (settings.sources.len == 0) {
        settings.sources = try foldersAsSources(allocator, defaultPhotoFolders);
    }

    const isNewDefault = config.defaultDatabasePath == null or config.defaultDatabasePath.?.len == 0;

    return .{
        // Nothing to watch means nothing to run. The interface says so; the task would throw.
        .shouldRun = settings.enabled and settings.sources.len > 0,
        .databasePath = if (isNewDefault) try getDefaultDatabasePath(allocator, appDataPath) else config.defaultDatabasePath.?,
        .isNewDefault = isNewDefault,
        .settings = settings,
    };
}
