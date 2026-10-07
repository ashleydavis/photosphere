const std = @import("std");
const api_zig = @import("api-zig");
const sync_settings = api_zig.sync_settings;
const DEFAULT_SYNC_PAUSE_MS = sync_settings.DEFAULT_SYNC_PAUSE_MS;
const normaliseSyncSettings = sync_settings.normaliseSyncSettings;
const resolveSyncPauseMs = sync_settings.resolveSyncPauseMs;

//
// Parses a JSON literal (TypeScript: the object literal the test passes).
//
fn parseJson(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

test "nothing stored gives the defaults: syncing off and Wi-Fi only" {
    const settings = normaliseSyncSettings(null);
    try std.testing.expect(!settings.enabled);
    try std.testing.expect(settings.onlyOnWifi);
}

test "a blob that is not an object gives the defaults" {
    try std.testing.expect(!normaliseSyncSettings(.null).enabled);
    try std.testing.expect(!normaliseSyncSettings(.{
        .string = "on",
    }).enabled);
    try std.testing.expect(normaliseSyncSettings(.{
        .string = "on",
    }).onlyOnWifi);
}

test "stored booleans are kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const settings = normaliseSyncSettings(try parseJson(arena.allocator(),
        \\{"enabled":true,"onlyOnWifi":false}
    ));
    try std.testing.expect(settings.enabled);
    try std.testing.expect(!settings.onlyOnWifi);
}

// A string "false" read from a hand-edited file is truthy and would switch syncing on for somebody who wrote the
// opposite, so a value that is not a boolean falls back rather than being coerced.
test "a value that is not a boolean falls back to the default instead of being coerced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const settings = normaliseSyncSettings(try parseJson(arena.allocator(),
        \\{"enabled":"false","onlyOnWifi":0}
    ));
    try std.testing.expect(!settings.enabled);
    try std.testing.expect(settings.onlyOnWifi);
}

test "a missing field falls back to its own default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const settings = normaliseSyncSettings(try parseJson(arena.allocator(),
        \\{"enabled":true}
    ));
    try std.testing.expect(settings.enabled);
    try std.testing.expect(settings.onlyOnWifi);
}

test "a fresh installation starts with syncing on and Wi-Fi only" {
    try std.testing.expect(sync_settings.INITIAL_SYNC_SETTINGS.enabled);
    try std.testing.expect(sync_settings.INITIAL_SYNC_SETTINGS.onlyOnWifi);
}

test "a gap that is a positive number is kept as it is" {
    try std.testing.expectEqual(@as(i64, 5000), resolveSyncPauseMs(.{
        .integer = 5000,
    }).integer);
    try std.testing.expectEqual(@as(f64, 5000.5), resolveSyncPauseMs(.{
        .float = 5000.5,
    }).float);
    try std.testing.expectEqualStrings("5000", resolveSyncPauseMs(.{
        .number_string = "5000",
    }).number_string);
}

test "no gap at all means the default of five minutes" {
    try std.testing.expectEqual(@as(i64, 300000), DEFAULT_SYNC_PAUSE_MS);
    try std.testing.expectEqual(@as(i64, DEFAULT_SYNC_PAUSE_MS), resolveSyncPauseMs(null).integer);
}

test "a gap of zero or less falls back to the default rather than spinning" {
    try std.testing.expectEqual(@as(i64, DEFAULT_SYNC_PAUSE_MS), resolveSyncPauseMs(.{
        .integer = 0,
    }).integer);
    try std.testing.expectEqual(@as(i64, DEFAULT_SYNC_PAUSE_MS), resolveSyncPauseMs(.{
        .integer = -1,
    }).integer);
    try std.testing.expectEqual(@as(i64, DEFAULT_SYNC_PAUSE_MS), resolveSyncPauseMs(.{
        .float = -0.5,
    }).integer);
}

test "a gap that is not a usable number falls back to the default" {
    try std.testing.expectEqual(@as(i64, DEFAULT_SYNC_PAUSE_MS), resolveSyncPauseMs(.{
        .float = std.math.nan(f64),
    }).integer);
    try std.testing.expectEqual(@as(i64, DEFAULT_SYNC_PAUSE_MS), resolveSyncPauseMs(.{
        .float = std.math.inf(f64),
    }).integer);
    try std.testing.expectEqual(@as(i64, DEFAULT_SYNC_PAUSE_MS), resolveSyncPauseMs(.{
        .string = "soon",
    }).integer);
    try std.testing.expectEqual(@as(i64, DEFAULT_SYNC_PAUSE_MS), resolveSyncPauseMs(.{
        .number_string = "soon",
    }).integer);
    try std.testing.expectEqual(@as(i64, DEFAULT_SYNC_PAUSE_MS), resolveSyncPauseMs(.null).integer);
}
