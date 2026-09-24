const std = @import("std");
const node_api = @import("node-api-zig");
const config = @import("config.zig");
const fetch = node_api.fetch.fetch;
const getLastShownUpdateVersion = node_api.news_state.getLastShownUpdateVersion;
const setLastShownUpdateVersion = node_api.news_state.setLastShownUpdateVersion;

//
// URL of the GitHub API endpoint that returns the latest non-prerelease release.
//
const LATEST_RELEASE_URL = "https://api.github.com/repos/ashleydavis/photosphere/releases/latest";

// Not ported: IGitHubReleaseResponse (the response is a std.json.Value here).

//
// The tag_name of the release response, or null when it is missing or not a string.
//
fn tagName(allocator: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const data = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch return null;
    if (data != .object) {
        return null;
    }
    const tag = data.object.get("tag_name") orelse return null;
    if (tag != .string or tag.string.len == 0) {
        return null;
    }
    return tag.string;
}

//
// The body of checkForUpdates inside its try block (errors become undefined).
//
fn checkForUpdatesUnsafe(allocator: std.mem.Allocator, io: std.Io, currentVersion: []const u8) !?[]const u8 {
    const response = try fetch(allocator, io, LATEST_RELEASE_URL);
    if (!response.ok) {
        return null;
    }
    const tag = tagName(allocator, response.body) orelse return null;
    const latestVersion = if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
    if (std.mem.eql(u8, latestVersion, currentVersion)) {
        return null;
    }
    const lastShown = try getLastShownUpdateVersion(allocator, io);
    if (lastShown != null and std.mem.eql(u8, lastShown.?, latestVersion)) {
        return null;
    }
    return latestVersion;
}

//
// Checks GitHub for the latest Photosphere release and returns the version string
// (without leading "v") when it differs from the running version AND has not
// already been notified to the user (per news.yaml's last_shown_update_version).
// Returns undefined when the running version is current, when it is a non-release
// build ("dev" or nightly), when the user has already been notified about this
// version, or when the network/parse step fails.
//
pub fn checkForUpdates(allocator: std.mem.Allocator, io: std.Io) ?[]const u8 {
    const currentVersion: []const u8 = config.version;
    if (std.mem.eql(u8, currentVersion, "dev") or std.mem.indexOf(u8, currentVersion, "nightly") != null) {
        return null;
    }

    return checkForUpdatesUnsafe(allocator, io, currentVersion) catch null;
}

//
// Records that the user has been notified about the given update version, so
// subsequent checkForUpdates() calls suppress the notification until a newer
// version ships. Persistence failures are swallowed silently.
//
pub fn markUpdateAsShown(allocator: std.mem.Allocator, io: std.Io, latestVersion: []const u8) void {
    setLastShownUpdateVersion(allocator, io, latestVersion) catch {
        // Update persistence failures must never block the user.
    };
}

// Not ported: getLatestVersion (only used by psi news).
