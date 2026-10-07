const std = @import("std");
const auto_import_settings = @import("auto-import-settings.zig");
const IAutoImportSettings = auto_import_settings.IAutoImportSettings;

//
// What the mobile app should do about automatic import, worked out from its settings alone.
//
// Only the part the config file needs is ported: the file's type and the pacing it holds. Not ported:
// DEFAULT_DATABASE_FOLDER_NAME, DEFAULT_DATABASE_DISPLAY_NAME, AUTO_IMPORT_TASK_SOURCE, WHOLE_LIBRARY_SOURCES, IMobileAutoImportPlan
// and planMobileAutoImport (the mobile apps' planner, which psi and the desktop app do not reach).
//
// (Zig: a number the file holds (the pacing) is a std.json.Value that is a number, so an integer stays an integer when
// it is written back, the way a JavaScript number does.)
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
// The value of a number as a float, or null when it is not a number (`typeof value === "number"`).
// (No TypeScript counterpart.)
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
