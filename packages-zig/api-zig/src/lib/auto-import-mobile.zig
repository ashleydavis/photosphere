const std = @import("std");
const auto_import_settings = @import("auto-import-settings.zig");
const IAutoImportSettings = auto_import_settings.IAutoImportSettings;
pub const IAutoImportSource = auto_import_settings.IAutoImportSource;
const IRawAutoImportSettings = auto_import_settings.IRawAutoImportSettings;
const normaliseAutoImportSettings = auto_import_settings.normaliseAutoImportSettings;

//
// What the mobile app should do about automatic import, worked out from its settings alone.
//
// This mirrors the desktop planner: the decisions
// live here as plain functions so they can be unit tested, and the caller is left with the parts
// that need the app (creating the database, starting the task, asking for the permission).
//
// It lives in this package rather than in the mobile frontend because the native background import
// asks for the same plan, through a worker task, and the worker cannot reach the frontend's React
// code. One planner answers both, so a phone driving the import from its own service and a phone
// driving it from the WebView cannot decide different things.
//
// (Zig: a number the file holds (the pacing) is a std.json.Value that is a number, so an integer stays an integer when
// it is written back.)
//

//
// Everything the mobile automatic import settings file holds.
//
// The settings themselves, the database they are imported into, and the pacing of the background
// loop. It is here rather than beside the file's TOML conversion because the WebView holds these
// values and cannot reach the code that opens the file, so the type has to sit in a package with no
// platform of its own.
//
pub const IAutoImportFile = struct {
    // The settings automatic import runs with.
    settings: IAutoImportSettings,

    // The sandbox-relative path of the database automatic import writes to, or undefined when no
    // default database has been chosen yet.
    defaultDatabasePath: ?[]const u8,

    // The gap between background import passes, in milliseconds (a number value). Already resolved, so a file asking
    // for zero or a negative gap comes back holding the default.
    pauseBetweenRunsMs: std.json.Value,
};

//
// How long the background import waits between passes when the settings file does not say.
//
// A pass reads its sources to the end and stops, so this is the gap before the next one starts. Long
// enough that a phone is not scanning its library continuously, short enough that a photo taken now
// is backed up in the next minute or so.
//
pub const DEFAULT_AUTO_IMPORT_PAUSE_MS = 30000;

//
// The value of a number as a float, or null when it is not a number.
//
fn numberAsFloat(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch std.math.nan(f64),
        else => null,
    };
}

//
// The gap between background import passes, in milliseconds.
//
// Zero, a negative number, and anything that is not a finite number all fall back to the default.
// The value is read from a file the user may edit, and a gap of zero is a loop that starts a fresh
// pass the instant the last one ends, which on a phone is a flat battery rather than a fast backup.
//
pub fn resolveAutoImportPauseMs(pauseMs: ?std.json.Value) std.json.Value {
    const value = pauseMs orelse {
        return .{
            .integer = DEFAULT_AUTO_IMPORT_PAUSE_MS,
        };
    };
    const number = numberAsFloat(value) orelse {
        return .{
            .integer = DEFAULT_AUTO_IMPORT_PAUSE_MS,
        };
    };
    if (!std.math.isFinite(number) or number <= 0) {
        return .{
            .integer = DEFAULT_AUTO_IMPORT_PAUSE_MS,
        };
    }
    return value;
}

//
// The folder the default private database is created in, inside the app sandbox.
//
// The same fixed name the desktop app uses, so a user with both sees the same database name and a
// support answer about one applies to the other.
//
pub const DEFAULT_DATABASE_FOLDER_NAME = "photosphere-default";

//
// The name the default private database is listed under.
//
pub const DEFAULT_DATABASE_DISPLAY_NAME = "My Photos";

//
// The source tag every automatic import task is queued under, so it can be cancelled as a group when
// the setting is switched off.
//
pub const AUTO_IMPORT_TASK_SOURCE = "auto-import";

//
// The whole device photo library, which is what is watched before the user chooses albums.
//
pub const WHOLE_LIBRARY_SOURCES = [_]IAutoImportSource{
    .{
        .@"device-album" = .{
            .albumId = auto_import_settings.ALL_DEVICE_MEDIA_ALBUM_ID,
        },
    },
};

//
// What the app should do about automatic import right now.
//
pub const IMobileAutoImportPlan = struct {
    // Whether the automatic import task should be running at all.
    shouldRun: bool,

    // The sandbox-relative path of the database automatic import writes to.
    databasePath: []const u8,

    // True when no default database has been chosen yet, so the path above is where a new one goes.
    isNewDefault: bool,

    // The settings the task should run with.
    settings: IAutoImportSettings,
};

//
// Decides what the app should do about automatic import.
//
// When the user has switched automatic import on but named no albums, the whole photo library is
// watched. Running with no sources at all would import nothing while looking like it was working,
// which is the worst of both.
//
// (Zig has no untyped object, so the stored settings are the std.json.Value they were read as. A malformed source in them
// is dropped by normaliseAutoImportSettings, and normalising allocates.)
//
pub fn planMobileAutoImport(
    allocator: std.mem.Allocator,
    storedSettings: ?IRawAutoImportSettings,
    defaultDatabasePath: ?[]const u8,
) !IMobileAutoImportPlan {
    var settings = try normaliseAutoImportSettings(allocator, storedSettings);

    if (settings.sources.len == 0) {
        settings.sources = &WHOLE_LIBRARY_SOURCES;
    }

    const isNewDefault = defaultDatabasePath == null or defaultDatabasePath.?.len == 0;

    return .{
        .shouldRun = settings.enabled,
        .databasePath = if (isNewDefault) DEFAULT_DATABASE_FOLDER_NAME else defaultDatabasePath.?,
        .isNewDefault = isNewDefault,
        .settings = settings,
    };
}
