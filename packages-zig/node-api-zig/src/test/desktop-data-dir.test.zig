//
// Tests of the desktop app's data directory as the CLI works it out: the rule of each of Ziggy's desktop native apps, and the
// PHOTOSPHERE_DATA_DIR override. The rules are given the environment directly, so every operating system's rule is tested on any
// operating system. The override tests give the thread an environment of its own and put the thread's environment back when they end.
//

const std = @import("std");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const desktop_data_dir = node_api.desktop_data_dir;
const desktopDataDirFor = desktop_data_dir.desktopDataDirFor;
const APP_ID = desktop_data_dir.DESKTOP_APP_ID;

test "the app id is the one the Photosphere App's desktop native apps are given" {
    try std.testing.expectEqualStrings("au.com.codecapers.photosphere", APP_ID);
}

test "on Linux the data directory is the app id in XDG_DATA_HOME when it is set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const dataDir = try desktopDataDirFor(arena.allocator(), .linux, .{
        .xdgDataHome = "/home/someone/data",
        .home = "/home/someone",
        .cfFixedUserHome = null,
        .localAppData = null,
    }, APP_ID);

    try std.testing.expectEqualStrings("/home/someone/data/au.com.codecapers.photosphere", dataDir);
}

test "on Linux the data directory is the app id in .local/share of the home directory when XDG_DATA_HOME is not set or empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const unset = try desktopDataDirFor(arena.allocator(), .linux, .{
        .xdgDataHome = null,
        .home = "/home/someone",
        .cfFixedUserHome = null,
        .localAppData = null,
    }, APP_ID);
    const empty = try desktopDataDirFor(arena.allocator(), .linux, .{
        .xdgDataHome = "",
        .home = "/home/someone",
        .cfFixedUserHome = null,
        .localAppData = null,
    }, APP_ID);

    try std.testing.expectEqualStrings("/home/someone/.local/share/au.com.codecapers.photosphere", unset);
    try std.testing.expectEqualStrings("/home/someone/.local/share/au.com.codecapers.photosphere", empty);
}

test "on Linux with neither XDG_DATA_HOME nor HOME there is no data directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.Thrown, desktopDataDirFor(arena.allocator(), .linux, .{
        .xdgDataHome = null,
        .home = null,
        .cfFixedUserHome = null,
        .localAppData = null,
    }, APP_ID));
}

test "on MacOS the data directory is the bundle identifier in Application Support of the home directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const dataDir = try desktopDataDirFor(arena.allocator(), .macos, .{
        .xdgDataHome = "/ignored",
        .home = "/Users/someone",
        .cfFixedUserHome = null,
        .localAppData = null,
    }, APP_ID);

    try std.testing.expectEqualStrings("/Users/someone/Library/Application Support/au.com.codecapers.photosphere", dataDir);
}

test "on MacOS CFFIXED_USER_HOME replaces the home directory, as it does for Foundation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const dataDir = try desktopDataDirFor(arena.allocator(), .macos, .{
        .xdgDataHome = null,
        .home = "/Users/someone",
        .cfFixedUserHome = "/scenario/home",
        .localAppData = null,
    }, APP_ID);

    try std.testing.expectEqualStrings("/scenario/home/Library/Application Support/au.com.codecapers.photosphere", dataDir);
}

test "on Windows the data directory is the app id in LOCALAPPDATA, joined with a backslash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const dataDir = try desktopDataDirFor(arena.allocator(), .windows, .{
        .xdgDataHome = null,
        .home = "C:\\Users\\someone",
        .cfFixedUserHome = null,
        .localAppData = "C:\\Users\\someone\\AppData\\Local",
    }, APP_ID);

    try std.testing.expectEqualStrings("C:\\Users\\someone\\AppData\\Local\\au.com.codecapers.photosphere", dataDir);
}

test "on Windows without LOCALAPPDATA there is no data directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.Thrown, desktopDataDirFor(arena.allocator(), .windows, .{
        .xdgDataHome = null,
        .home = "C:\\Users\\someone",
        .cfFixedUserHome = null,
        .localAppData = null,
    }, APP_ID));
}

test "the CLI's data directory is the one PHOTOSPHERE_DATA_DIR names when it is set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    try environment.put("PHOTOSPHERE_DATA_DIR", "/tmp/cli-test-7/data");
    const previous = node_utils.process_env.getEnvironMap();
    node_utils.process_env.setEnvironMap(&environment);
    defer node_utils.process_env.setEnvironMap(previous);

    try std.testing.expectEqualStrings("/tmp/cli-test-7/data", try desktop_data_dir.commandLineDataDir(arena.allocator()));
}

test "the CLI's data directory is the desktop app's when PHOTOSPHERE_DATA_DIR is not set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    try environment.put("XDG_DATA_HOME", "/home/someone/data");
    try environment.put("HOME", "/home/someone");
    try environment.put("LOCALAPPDATA", "C:\\Users\\someone\\AppData\\Local");
    const previous = node_utils.process_env.getEnvironMap();
    node_utils.process_env.setEnvironMap(&environment);
    defer node_utils.process_env.setEnvironMap(previous);

    try std.testing.expectEqualStrings(try desktop_data_dir.desktopDataDir(arena.allocator()), try desktop_data_dir.commandLineDataDir(arena.allocator()));
}
