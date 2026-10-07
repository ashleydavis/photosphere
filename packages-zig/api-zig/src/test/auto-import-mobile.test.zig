const std = @import("std");
const api_zig = @import("api-zig");
const auto_import_mobile = api_zig.auto_import_mobile;
const DEFAULT_AUTO_IMPORT_PAUSE_MS = auto_import_mobile.DEFAULT_AUTO_IMPORT_PAUSE_MS;
const resolveAutoImportPauseMs = auto_import_mobile.resolveAutoImportPauseMs;

test "a gap that is a positive number is kept as it is" {
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

test "no gap at all means the default" {
    try std.testing.expectEqual(@as(i64, DEFAULT_AUTO_IMPORT_PAUSE_MS), resolveAutoImportPauseMs(null).integer);
}

// Zero is a loop that starts a fresh pass the instant the last one ends, which on a phone is a flat battery rather
// than a fast backup.
test "a gap of zero falls back to the default rather than spinning" {
    try std.testing.expectEqual(@as(i64, DEFAULT_AUTO_IMPORT_PAUSE_MS), resolveAutoImportPauseMs(.{
        .integer = 0,
    }).integer);
    try std.testing.expectEqual(@as(i64, DEFAULT_AUTO_IMPORT_PAUSE_MS), resolveAutoImportPauseMs(.{
        .float = 0.0,
    }).integer);
}

test "a negative gap falls back to the default" {
    try std.testing.expectEqual(@as(i64, DEFAULT_AUTO_IMPORT_PAUSE_MS), resolveAutoImportPauseMs(.{
        .integer = -1,
    }).integer);
}

// The value comes from a file a person may have edited, so it can be anything at all.
test "a gap that is not a usable number falls back to the default" {
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
