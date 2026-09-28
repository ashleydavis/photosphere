//
// The operating system's photo locations, for use as the starting source list for automatic
// import. The candidate list is separated from the existence check so the per-platform decision can
// be unit tested on any machine, rather than only on the platform it describes.
//

const std = @import("std");
const builtin = @import("builtin");
const path = @import("path.zig");
const fs = @import("fs.zig");
const js_string = @import("utils-zig").js_string;

//
// Where the XDG user directories file lives, relative to the user's home directory. Linux desktops
// record the user's chosen Pictures folder here, which is often not "Pictures" in an English
// install and is frequently not "Pictures" at all in a translated one.
//
const XDG_USER_DIRS_PATH = ".config/user-dirs.dirs";

//
// Pulls the pictures directory out of the contents of an XDG user-dirs file, or returns undefined
// when the file does not name one. The file is shell-like: lines of KEY="value", where the value
// usually starts with $HOME, and lines starting with # are comments.
//
pub fn parseXdgPicturesDir(allocator: std.mem.Allocator, fileContents: []const u8, homeDir: []const u8) !?[]const u8 {
    var rawLines = std.mem.splitScalar(u8, fileContents, '\n');
    while (rawLines.next()) |rawLine| {
        const line = js_string.trim(rawLine);
        if (line.len == 0 or std.mem.startsWith(u8, line, "#")) {
            continue;
        }

        const value = matchXdgPicturesDir(line) orelse {
            continue;
        };

        if (value.len == 0) {
            return null;
        }

        if (std.mem.eql(u8, value, "$HOME")) {
            return homeDir;
        }

        if (std.mem.startsWith(u8, value, "$HOME/")) {
            return try path.join(allocator, &.{ homeDir, value["$HOME/".len..] });
        }

        return value;
    }

    return null;
}

//
// Matches a line against /^XDG_PICTURES_DIR\s*=\s*"(.*)"\s*$/ (where \s is JavaScript whitespace) and returns the
// captured value, or null when it does not match. (No TypeScript counterpart: TypeScript runs the regular expression inline.)
//
fn matchXdgPicturesDir(line: []const u8) ?[]const u8 {
    const key = "XDG_PICTURES_DIR";
    if (!std.mem.startsWith(u8, line, key)) {
        return null;
    }
    var rest = js_string.trimStart(line[key.len..]);
    if (rest.len == 0 or rest[0] != '=') {
        return null;
    }
    rest = js_string.trimStart(rest[1..]);
    if (rest.len == 0 or rest[0] != '"') {
        return null;
    }
    rest = js_string.trimEnd(rest[1..]);

    // `(.*)"` is greedy, so the value runs to the last quote, which has to end the line.
    if (rest.len == 0 or rest[rest.len - 1] != '"') {
        return null;
    }
    const value = rest[0 .. rest.len - 1];

    // `.` matches no line terminator (the line has no "\n", which it was split on).
    if (std.mem.indexOfScalar(u8, value, '\r') != null or std.mem.indexOf(u8, value, "\u{2028}") != null or std.mem.indexOf(u8, value, "\u{2029}") != null) {
        return null;
    }
    return value;
}

//
// Reads the user's XDG pictures directory, or returns undefined when there is no XDG user-dirs file
// or it does not name one. Never throws: a missing or unreadable file simply means "not configured".
//
pub fn readXdgPicturesDir(allocator: std.mem.Allocator, io: std.Io, homeDir: []const u8) !?[]const u8 {
    const userDirsPath = try path.join(allocator, &.{ homeDir, XDG_USER_DIRS_PATH });
    const fileContents = std.Io.Dir.cwd().readFileAlloc(io, userDirsPath, allocator, .unlimited) catch |err| {
        if (err == error.OutOfMemory) {
            return err;
        }
        return null;
    };

    return parseXdgPicturesDir(allocator, fileContents, homeDir);
}

//
// The photo locations an operating system is expected to have, before checking which of them are
// actually present on this machine. Duplicates are removed, so a Linux machine whose XDG pictures
// directory is the ordinary "Pictures" folder yields one entry rather than two.
// (Zig: the platform is the value of Node's `process.platform`, e.g. "win32", "darwin" or "linux".)
//
pub fn getPhotoFolderCandidates(allocator: std.mem.Allocator, platform: []const u8, homeDir: []const u8, xdgPicturesDir: ?[]const u8) ![]const []const u8 {
    var candidates: std.ArrayList([]const u8) = .empty;

    if (std.mem.eql(u8, platform, "win32")) {
        const picturesDir = try path.join(allocator, &.{ homeDir, "Pictures" });
        try candidates.append(allocator, picturesDir);
        try candidates.append(allocator, try path.join(allocator, &.{ picturesDir, "Camera Roll" }));
    }
    else if (std.mem.eql(u8, platform, "darwin")) {
        try candidates.append(allocator, try path.join(allocator, &.{ homeDir, "Pictures" }));
    }
    else {
        if (xdgPicturesDir != null and xdgPicturesDir.?.len > 0) {
            try candidates.append(allocator, xdgPicturesDir.?);
        }
        else {
            try candidates.append(allocator, try path.join(allocator, &.{ homeDir, "Pictures" }));
        }
    }

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var unique: std.ArrayList([]const u8) = .empty;
    for (candidates.items) |candidate| {
        if (!seen.contains(candidate)) {
            try seen.put(allocator, candidate, {});
            try unique.append(allocator, candidate);
        }
    }
    return unique.items;
}

//
// Keeps only the candidates that exist on disk as directories. Never throws: a path that cannot be
// stat'ed at all is treated the same as one that is not there.
//
pub fn filterExistingFolders(allocator: std.mem.Allocator, io: std.Io, candidates: []const []const u8) ![]const []const u8 {
    var existing: std.ArrayList([]const u8) = .empty;
    for (candidates) |candidate| {
        const stat = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch {
            // Not there, or not readable. Either way it is not a photo folder we can watch.
            continue;
        };
        if (stat.kind == .directory) {
            try existing.append(allocator, candidate);
        }
    }
    return existing.items;
}

//
// Node's `process.platform` for the platform this program was built for.
// (No TypeScript counterpart: TypeScript reads `process.platform`.)
//
pub fn processPlatform() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "win32",
        .macos => "darwin",
        .linux => "linux",
        else => @tagName(builtin.os.tag),
    };
}

//
// The operating system's photo locations that exist on this machine. Returns an empty list rather
// than throwing when none of them are present.
//
pub fn getDefaultPhotoFolders(allocator: std.mem.Allocator, io: std.Io) ![]const []const u8 {
    const homeDir = fs.osHomedir();
    const platform = processPlatform();
    const xdgPicturesDir = if (std.mem.eql(u8, platform, "win32") or std.mem.eql(u8, platform, "darwin"))
        null
    else
        try readXdgPicturesDir(allocator, io, homeDir);
    return filterExistingFolders(allocator, io, try getPhotoFolderCandidates(allocator, platform, homeDir, xdgPicturesDir));
}
