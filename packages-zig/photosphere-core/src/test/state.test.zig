const std = @import("std");
const ziggy = @import("ziggy");
const support = @import("test-support.zig");

const TestApp = support.TestApp;

test "the state store round trips a value through the typed API" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = try app.statePath(allocator);
    try ziggy.config_state.state.set(allocator, std.testing.io, state_path, "gallery.sort", "date");
    try std.testing.expectEqualStrings("date", try ziggy.config_state.state.get([]const u8, allocator, std.testing.io, state_path, "gallery.sort"));
}

test "an absent state key is null for an optional type" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const state_path = try app.statePath(arena.allocator());
    try std.testing.expectEqual(@as(?[]const u8, null), try ziggy.config_state.state.get(?[]const u8, arena.allocator(), std.testing.io, state_path, "desktop.last_folder"));
}

test "the page's own keys live under ui, with a dot in the key kept in one key" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = try app.statePath(allocator);
    try ziggy.config_state.state.set(allocator, std.testing.io, state_path, "ui.sidebar%2Ecollapsed", true);
    try std.testing.expect(try ziggy.config_state.state.get(bool, allocator, std.testing.io, state_path, "ui.sidebar%2Ecollapsed"));
    try ziggy.config_state.state.set(allocator, std.testing.io, state_path, "ui.recent", &[_][]const u8{ "a", "b" });
    const recent = try ziggy.config_state.state.get([]const []const u8, allocator, std.testing.io, state_path, "ui.recent");
    try std.testing.expectEqual(@as(usize, 2), recent.len);
}

test "a null removes a state key" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const state_path = try app.statePath(allocator);
    try ziggy.config_state.state.set(allocator, std.testing.io, state_path, "gallery.sort", "date");
    try ziggy.config_state.state.set(allocator, std.testing.io, state_path, "gallery.sort", @as(?[]const u8, null));
    try std.testing.expectEqual(@as(?[]const u8, null), try ziggy.config_state.state.get(?[]const u8, allocator, std.testing.io, state_path, "gallery.sort"));
}

