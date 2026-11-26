const std = @import("std");
const api_zig = @import("api-zig");
const auto_import = api_zig.auto_import;
const DEFAULT_AUTO_IMPORT_PAUSE_MS = auto_import.DEFAULT_AUTO_IMPORT_PAUSE_MS;
const DEFAULT_DATABASE_FOLDER_NAME = auto_import.DEFAULT_DATABASE_FOLDER_NAME;
const WHOLE_LIBRARY_SOURCES = auto_import.WHOLE_LIBRARY_SOURCES;
const planAutoImport = auto_import.planAutoImport;
const resolveAutoImportPauseMs = auto_import.resolveAutoImportPauseMs;
const json = @import("ziggy").json;

//
// The automatic import settings as they are stored.
//
const IStoredAutoImportSettings = struct {
    // True when automatic import is switched on.
    enabled: bool,

    // The list of sources, as the JSON text the test gives.
    sources: json.Raw,
};

//
// Settings with automatic import switched on (or off) and the sources the JSON text gives, as they would be stored.
// (Zig: the settings are the JSON they were stored as.)
//
fn settingsWith(allocator: std.mem.Allocator, enabled: bool, sourcesJson: []const u8) !std.json.Value {
    const settings: IStoredAutoImportSettings = .{
        .enabled = enabled,
        .sources = .{
            .text = sourcesJson,
        },
    };
    const text = try json.stringify(allocator, settings);
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

test "planAutoImport does not run when nothing has been stored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(false, (try planAutoImport(arena.allocator(), null, null, &WHOLE_LIBRARY_SOURCES)).shouldRun);
}

test "planAutoImport does not run when automatic import is switched off" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqual(false, (try planAutoImport(allocator, try settingsWith(allocator, false, "[]"), null, &WHOLE_LIBRARY_SOURCES)).shouldRun);
}

test "planAutoImport runs when automatic import is switched on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqual(true, (try planAutoImport(allocator, try settingsWith(allocator, true, "[]"), null, &WHOLE_LIBRARY_SOURCES)).shouldRun);
}

test "planAutoImport watches the whole library when no albums are chosen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const plan = try planAutoImport(allocator, try settingsWith(allocator, true, "[]"), null, &WHOLE_LIBRARY_SOURCES);

    try std.testing.expectEqualDeep(@as([]const auto_import.IAutoImportSource, &WHOLE_LIBRARY_SOURCES), plan.settings.sources);
}

test "planAutoImport watches the given default sources when none are chosen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const folder_default = [_]auto_import.IAutoImportSource{
        .{
            .folder = .{
                .path = "/photos",
                .recurse = true,
            },
        },
    };
    const plan = try planAutoImport(allocator, try settingsWith(allocator, true, "[]"), null, &folder_default);

    try std.testing.expectEqualDeep(@as([]const auto_import.IAutoImportSource, &folder_default), plan.settings.sources);
}

test "planAutoImport watches the chosen albums when there are some" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const plan = try planAutoImport(allocator, try settingsWith(allocator, true, "[{\"type\":\"device-album\",\"albumId\":\"camera\"}]"), null, &WHOLE_LIBRARY_SOURCES);

    try std.testing.expectEqual(@as(usize, 1), plan.settings.sources.len);
    try std.testing.expectEqualStrings("camera", plan.settings.sources[0].@"device-album".albumId);
}

test "planAutoImport drops a malformed stored source rather than failing to start" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const stored = try settingsWith(allocator, true, "[{\"type\":\"device-album\"},{\"type\":\"device-album\",\"albumId\":\"camera\"}]");

    const plan = try planAutoImport(allocator, stored, null, &WHOLE_LIBRARY_SOURCES);

    try std.testing.expectEqual(@as(usize, 1), plan.settings.sources.len);
    try std.testing.expectEqualStrings("camera", plan.settings.sources[0].@"device-album".albumId);
}

test "planAutoImport chooses the default database location when none has been chosen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const plan = try planAutoImport(allocator, try settingsWith(allocator, true, "[]"), null, &WHOLE_LIBRARY_SOURCES);

    try std.testing.expectEqual(true, plan.isNewDefault);
    try std.testing.expectEqualStrings(DEFAULT_DATABASE_FOLDER_NAME, plan.databasePath);
}

test "planAutoImport uses the chosen default database when there is one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const plan = try planAutoImport(allocator, try settingsWith(allocator, true, "[]"), "my-photos", &WHOLE_LIBRARY_SOURCES);

    try std.testing.expectEqual(false, plan.isNewDefault);
    try std.testing.expectEqualStrings("my-photos", plan.databasePath);
}

test "planAutoImport an empty stored default counts as none chosen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const plan = try planAutoImport(allocator, try settingsWith(allocator, true, "[]"), "", &WHOLE_LIBRARY_SOURCES);

    try std.testing.expectEqual(true, plan.isNewDefault);
    try std.testing.expectEqualStrings(DEFAULT_DATABASE_FOLDER_NAME, plan.databasePath);
}

// A user with both should see the same database name, and a support answer about one should apply to the other.
test "planAutoImport the default database has the same name as the desktop one" {
    try std.testing.expectEqualStrings("photosphere-default", DEFAULT_DATABASE_FOLDER_NAME);
}

test "the gap between background import passes: a gap the file asked for is used as it is" {
    try std.testing.expectEqual(@as(i64, 1500), resolveAutoImportPauseMs(.{
        .integer = 1500,
    }).integer);
    try std.testing.expectEqual(@as(f64, 1500.5), resolveAutoImportPauseMs(.{
        .float = 1500.5,
    }).float);
    try std.testing.expectEqualStrings("1500", resolveAutoImportPauseMs(.{
        .number_string = "1500",
    }).number_string);
}

test "the gap between background import passes: no gap at all means the default" {
    try std.testing.expectEqual(@as(i64, DEFAULT_AUTO_IMPORT_PAUSE_MS), resolveAutoImportPauseMs(null).integer);
}

// Zero is a loop that starts a fresh pass the instant the last one ends, which on a mobile is a flat battery rather
// than a fast backup.
test "the gap between background import passes: a gap of zero falls back to the default rather than spinning" {
    try std.testing.expectEqual(@as(i64, DEFAULT_AUTO_IMPORT_PAUSE_MS), resolveAutoImportPauseMs(.{
        .integer = 0,
    }).integer);
    try std.testing.expectEqual(@as(i64, DEFAULT_AUTO_IMPORT_PAUSE_MS), resolveAutoImportPauseMs(.{
        .float = 0.0,
    }).integer);
}

test "the gap between background import passes: a negative gap falls back to the default" {
    try std.testing.expectEqual(@as(i64, DEFAULT_AUTO_IMPORT_PAUSE_MS), resolveAutoImportPauseMs(.{
        .integer = -1,
    }).integer);
}

// The value comes from a file a person may have edited, so it can be anything at all.
test "the gap between background import passes: a gap that is not a usable number falls back to the default" {
    try std.testing.expectEqual(@as(i64, DEFAULT_AUTO_IMPORT_PAUSE_MS), resolveAutoImportPauseMs(.{
        .float = std.math.nan(f64),
    }).integer);
    try std.testing.expectEqual(@as(i64, DEFAULT_AUTO_IMPORT_PAUSE_MS), resolveAutoImportPauseMs(.{
        .float = std.math.inf(f64),
    }).integer);
    try std.testing.expectEqual(@as(i64, DEFAULT_AUTO_IMPORT_PAUSE_MS), resolveAutoImportPauseMs(.{
        .string = "soon",
    }).integer);
    try std.testing.expectEqual(@as(i64, DEFAULT_AUTO_IMPORT_PAUSE_MS), resolveAutoImportPauseMs(.{
        .number_string = "soon",
    }).integer);
    try std.testing.expectEqual(@as(i64, DEFAULT_AUTO_IMPORT_PAUSE_MS), resolveAutoImportPauseMs(.{
        .bool = true,
    }).integer);
    try std.testing.expectEqual(@as(i64, DEFAULT_AUTO_IMPORT_PAUSE_MS), resolveAutoImportPauseMs(.null).integer);
}

test "the default gap between import passes is thirty seconds" {
    try std.testing.expectEqual(@as(i64, 30000), DEFAULT_AUTO_IMPORT_PAUSE_MS);
}
