//
// The data directory of the Photosphere App on a desktop operating system, worked out without the native app, so the CLI can use the
// same one. The CLI keeps its databases in the same place the desktop app does, `<data dir>/dbs` (see database-base-dir.zig).
//
// THIS MUST MATCH ZIGGY'S DESKTOP NATIVE APPS. Each one makes its data directory from the app id by its own operating system's rule:
// - Linux (native/linux, native-app.zig): GLib's g_get_user_data_dir() joined with the app id. GLib's user data directory is
//   XDG_DATA_HOME when it is set and not empty, otherwise `.local/share` in the home directory.
// - MacOS (native/macos, ZiggyBridge.swift): the user's Application Support directory joined with the bundle identifier. Foundation
//   finds Application Support in the home directory, which CFFIXED_USER_HOME replaces when it is set.
// - Windows (native/windows, native-app.zig): LOCALAPPDATA and the app id joined with a backslash.
// The CLI links neither GLib nor Foundation, so the same rules are written out here. A change to the rules in Ziggy, or to the app id
// the Photosphere App's native apps are given, has to be made here too.
//

const std = @import("std");
const builtin = @import("builtin");
const node_utils = @import("node-utils-zig");
const errors = @import("utils-zig").errors;

//
// The app id the Photosphere App's desktop native apps give Ziggy: `.app_id` in apps/photosphere/native/{linux,windows}/src/main.zig
// and PRODUCT_BUNDLE_IDENTIFIER in the MacOS Xcode project.
//
pub const DESKTOP_APP_ID = "au.com.codecapers.photosphere";

//
// The environment variables the rules read, each null when it is not set.
//
pub const IDesktopEnvironment = struct {
    // XDG_DATA_HOME, the user data directory on Linux.
    xdgDataHome: ?[]const u8,

    // HOME, the home directory on Linux and MacOS.
    home: ?[]const u8,

    // CFFIXED_USER_HOME, which replaces the home directory Foundation uses on MacOS.
    cfFixedUserHome: ?[]const u8,

    // LOCALAPPDATA, the local application data directory on Windows.
    localAppData: ?[]const u8,
};

//
// The data directory Ziggy's desktop native app of the given operating system makes for the app id, given the environment, allocated
// with the given allocator. Fails, naming what is missing, when the environment does not have what the rule needs, and for an
// operating system that has no desktop native app.
//
pub fn desktopDataDirFor(allocator: std.mem.Allocator, osTag: std.Target.Os.Tag, environment: IDesktopEnvironment, appId: []const u8) ![]const u8 {
    switch (osTag) {
        .linux => {
            if (nonEmpty(environment.xdgDataHome)) |xdgDataHome| {
                return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ xdgDataHome, appId });
            }
            const home = nonEmpty(environment.home) orelse {
                return errors.throwError("Cannot find the Photosphere data directory: neither XDG_DATA_HOME nor HOME is set.", .{});
            };
            return try std.fmt.allocPrint(allocator, "{s}/.local/share/{s}", .{ home, appId });
        },
        .macos => {
            const home = nonEmpty(environment.cfFixedUserHome) orelse nonEmpty(environment.home) orelse {
                return errors.throwError("Cannot find the Photosphere data directory: HOME is not set.", .{});
            };
            return try std.fmt.allocPrint(allocator, "{s}/Library/Application Support/{s}", .{ home, appId });
        },
        .windows => {
            const localAppData = nonEmpty(environment.localAppData) orelse {
                return errors.throwError("Cannot find the Photosphere data directory: LOCALAPPDATA is not set.", .{});
            };
            return try std.fmt.allocPrint(allocator, "{s}\\{s}", .{ localAppData, appId });
        },
        else => {
            return errors.throwError("Photosphere has no desktop data directory on {s}.", .{@tagName(osTag)});
        },
    }
}

//
// The data directory of the Photosphere desktop app on the operating system this program runs on, from this thread's environment,
// allocated with the given allocator.
//
pub fn desktopDataDir(allocator: std.mem.Allocator) ![]const u8 {
    return try desktopDataDirFor(allocator, builtin.os.tag, .{
        .xdgDataHome = node_utils.process_env.getEnv("XDG_DATA_HOME"),
        .home = node_utils.process_env.getEnv("HOME"),
        .cfFixedUserHome = node_utils.process_env.getEnv("CFFIXED_USER_HOME"),
        .localAppData = node_utils.process_env.getEnv("LOCALAPPDATA"),
    }, DESKTOP_APP_ID);
}

//
// The data directory of a program that has no native app to give it one (the CLI): the directory PHOTOSPHERE_DATA_DIR names when it
// is set, as it overrides the app's in databaseBaseDir, otherwise the desktop app's data directory.
//
pub fn commandLineDataDir(allocator: std.mem.Allocator) ![]const u8 {
    if (node_utils.process_env.getEnv("PHOTOSPHERE_DATA_DIR")) |dataDir| {
        return dataDir;
    }
    return try desktopDataDir(allocator);
}

//
// The value when it is set and not empty, otherwise null.
//
fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    if (value) |text| {
        if (text.len > 0) {
            return text;
        }
    }
    return null;
}
