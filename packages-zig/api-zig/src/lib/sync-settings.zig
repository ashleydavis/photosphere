const std = @import("std");

//
// Platform-neutral settings for automatic syncing.
//
// These are read by the app's interface and by the mobile background sync loop, so nothing in this
// file may depend on Node.js, Electron, Capacitor or the filesystem. The values arrive from a config
// file that a user may have hand-edited, or that an older version of the app wrote, so
// `normaliseSyncSettings` is the only supported way to turn a stored blob into settings.
//
// (Zig: a number the file holds (the pacing) is a std.json.Value that is a number, so an integer stays an integer when
// it is written back, the way a JavaScript number does.)
//

//
// The settings that control automatic syncing.
//
pub const ISyncSettings = struct {
    // Whether automatic syncing runs at all. The master switch: everything else is ignored while
    // this is off.
    enabled: bool,

    // Whether automatic syncing is refused while the connection is cellular.
    onlyOnWifi: bool,
};

//
// The settings a reader falls back to when it has nothing it can believe.
//
// Syncing off, deliberately. A file that is missing or will not parse is not a user saying "sync
// over anything you like": the app writes this file, so a copy nobody can read means something is
// wrong, and the safe answer to "should this phone start pushing photos over its cellular
// connection?" is no. The interface seeds the file with its own defaults the first time it runs,
// which is what stops a fresh install sitting here.
//
pub const DEFAULT_SYNC_SETTINGS: ISyncSettings = .{
    .enabled = false,
    .onlyOnWifi = true,
};

//
// The settings a fresh installation starts from.
//
// Syncing on and restricted to Wi-Fi, which is what the two toggles show before anyone touches
// them. Separate from DEFAULT_SYNC_SETTINGS above because they answer different questions: this one
// is what a new user should get, that one is what to do when a file cannot be read.
//
pub const INITIAL_SYNC_SETTINGS: ISyncSettings = .{
    .enabled = true,
    .onlyOnWifi = true,
};

//
// The stored form of the settings, as read from a file or a config store.
//
// Every field is optional and of unknown quality: this is what a hand-edited or older file may
// hold, before anything has checked it.
// (Zig: the std.json.Value it was read as, an object with the optional fields `enabled` and `onlyOnWifi`.)
//
pub const IRawSyncSettings = std.json.Value;

//
// Turns a stored blob into settings, filling anything missing or malformed from the defaults.
//
// A value that is not a boolean falls back rather than being coerced, because a string "false" read
// from a hand-edited file is truthy and would switch syncing on for somebody who wrote the opposite.
//
pub fn normaliseSyncSettings(stored: ?IRawSyncSettings) ISyncSettings {
    const settings = stored orelse {
        return DEFAULT_SYNC_SETTINGS;
    };
    if (settings != .object) {
        // (Zig: a JSON null, which is `!stored`, or a value that is not an object and so has no fields.)
        return DEFAULT_SYNC_SETTINGS;
    }
    const fields = settings.object;

    const enabled = fields.get("enabled");
    const onlyOnWifi = fields.get("onlyOnWifi");
    return .{
        .enabled = if (enabled != null and enabled.? == .bool) enabled.?.bool else DEFAULT_SYNC_SETTINGS.enabled,
        .onlyOnWifi = if (onlyOnWifi != null and onlyOnWifi.? == .bool) onlyOnWifi.?.bool else DEFAULT_SYNC_SETTINGS.onlyOnWifi,
    };
}

//
// Everything the syncing section of the config file holds.
//
// The settings themselves, the database the background loop pushes, and the pacing of that loop.
//
pub const ISyncFile = struct {
    // The settings automatic syncing runs with.
    settings: ISyncSettings,

    // The sandbox-relative path of the database the background sync pushes, or undefined when no
    // database has been opened yet.
    //
    // Recorded when a database is opened, so background syncing works for whatever the user is
    // actually using rather than only for the one automatic import made. Without it the background
    // sync would have nothing to push until automatic import had been switched on at least once,
    // which would tie two features together that are switched on separately.
    databasePath: ?[]const u8,

    // The gap between background sync passes, in milliseconds (a number value). Already resolved, so a file asking
    // for zero or a negative gap comes back holding the default.
    pauseBetweenRunsMs: std.json.Value,
};

//
// How long the background sync waits between passes when the settings file does not say.
//
// The same five minutes the desktop's periodic sync uses, and what the mobile WebView scheduler used
// before the loop moved to the native side. A pass where nothing has changed still costs a small
// read at the origin, which on a phone is a network request and a little battery, so the gap is what
// keeps an idle phone from paying for that every few seconds.
//
pub const DEFAULT_SYNC_PAUSE_MS = 5 * 60 * 1000;

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
// The gap between background sync passes, in milliseconds.
//
// Zero, a negative number, and anything that is not a finite number all fall back to the default.
// The value is read from a file a user may edit, and a gap of zero is a loop that starts a fresh
// pass the instant the last one ends, which on a phone is a flat battery rather than a fast backup.
//
pub fn resolveSyncPauseMs(pauseMs: ?std.json.Value) std.json.Value {
    const value = pauseMs orelse {
        return .{
            .integer = DEFAULT_SYNC_PAUSE_MS,
        };
    };
    const number = numberAsFloat(value) orelse {
        return .{
            .integer = DEFAULT_SYNC_PAUSE_MS,
        };
    };
    if (!std.math.isFinite(number) or number <= 0) {
        return .{
            .integer = DEFAULT_SYNC_PAUSE_MS,
        };
    }
    return value;
}
