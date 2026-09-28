const std = @import("std");
const node_utils = @import("node-utils-zig");
const photo_folders = node_utils.photo_folders;
const path = node_utils.path;
const filterExistingFolders = photo_folders.filterExistingFolders;
const getDefaultPhotoFolders = photo_folders.getDefaultPhotoFolders;
const getPhotoFolderCandidates = photo_folders.getPhotoFolderCandidates;
const parseXdgPicturesDir = photo_folders.parseXdgPicturesDir;
const readXdgPicturesDir = photo_folders.readXdgPicturesDir;

const io = std.testing.io;

//
// Asserts that two lists of paths are equal (TypeScript: `toEqual`).
//
fn expectPaths(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expectedPath, actualPath| {
        try std.testing.expectEqualStrings(expectedPath, actualPath);
    }
}

//
// Gets the absolute path of a directory made by std.testing.tmpDir (TypeScript: createTestTempDir).
//
fn tempDirPath(allocator: std.mem.Allocator, tmpDir: std.testing.TmpDir) ![]const u8 {
    const currentPath = try std.process.currentPathAlloc(io, allocator);
    return path.join(allocator, &.{ currentPath, ".zig-cache", "tmp", &tmpDir.sub_path });
}

test "Windows offers Pictures and Camera Roll" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const candidates = try getPhotoFolderCandidates(allocator, "win32", try path.join(allocator, &.{ "C:", "Users", "someone" }), null);
    try expectPaths(&.{
        try path.join(allocator, &.{ "C:", "Users", "someone", "Pictures" }),
        try path.join(allocator, &.{ "C:", "Users", "someone", "Pictures", "Camera Roll" }),
    }, candidates);
}

test "macOS offers Pictures only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const candidates = try getPhotoFolderCandidates(allocator, "darwin", "/Users/someone", null);
    try expectPaths(&.{try path.join(allocator, &.{ "/Users/someone", "Pictures" })}, candidates);
}

test "Linux uses the XDG pictures directory when there is one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const candidates = try getPhotoFolderCandidates(allocator, "linux", "/home/someone", "/home/someone/Bilder");
    try expectPaths(&.{"/home/someone/Bilder"}, candidates);
}

test "Linux falls back to Pictures under the home directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const candidates = try getPhotoFolderCandidates(allocator, "linux", "/home/someone", null);
    try expectPaths(&.{try path.join(allocator, &.{ "/home/someone", "Pictures" })}, candidates);
}

test "a duplicate candidate appears once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const candidates = try getPhotoFolderCandidates(allocator, "linux", "/home/someone", try path.join(allocator, &.{ "/home/someone", "Pictures" }));
    try expectPaths(&.{try path.join(allocator, &.{ "/home/someone", "Pictures" })}, candidates);
}

test "expands $HOME in the value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const contents = "XDG_DESKTOP_DIR=\"$HOME/Desktop\"\nXDG_PICTURES_DIR=\"$HOME/Bilder\"\n";
    try std.testing.expectEqualStrings(try path.join(allocator, &.{ "/home/someone", "Bilder" }), (try parseXdgPicturesDir(allocator, contents, "/home/someone")).?);
}

test "accepts an absolute value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("/mnt/photos", (try parseXdgPicturesDir(allocator, "XDG_PICTURES_DIR=\"/mnt/photos\"\n", "/home/someone")).?);
}

test "accepts the home directory itself" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("/home/someone", (try parseXdgPicturesDir(allocator, "XDG_PICTURES_DIR=\"$HOME\"\n", "/home/someone")).?);
}

test "ignores comments and other keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const contents = "# XDG_PICTURES_DIR=\"$HOME/Wrong\"\nXDG_VIDEOS_DIR=\"$HOME/Videos\"\n";
    try std.testing.expect((try parseXdgPicturesDir(allocator, contents, "/home/someone")) == null);
}

test "an empty value is not a directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expect((try parseXdgPicturesDir(allocator, "XDG_PICTURES_DIR=\"\"\n", "/home/someone")) == null);
}

test "an empty file names nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expect((try parseXdgPicturesDir(allocator, "", "/home/someone")) == null);
}

test "reads the pictures directory from the user-dirs file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();
    const homeDir = try tempDirPath(allocator, tmpDir);
    try tmpDir.dir.createDirPath(io, ".config");
    try tmpDir.dir.writeFile(io, .{
        .sub_path = ".config/user-dirs.dirs",
        .data = "XDG_PICTURES_DIR=\"$HOME/Bilder\"\n",
    });

    try std.testing.expectEqualStrings(try path.join(allocator, &.{ homeDir, "Bilder" }), (try readXdgPicturesDir(allocator, io, homeDir)).?);
}

test "returns undefined rather than throwing when there is no user-dirs file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();
    const homeDir = try tempDirPath(allocator, tmpDir);

    try std.testing.expect((try readXdgPicturesDir(allocator, io, homeDir)) == null);
}

test "keeps only folders that exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();
    const tempDir = try tempDirPath(allocator, tmpDir);
    const presentDir = try path.join(allocator, &.{ tempDir, "Pictures" });
    const absentDir = try path.join(allocator, &.{ tempDir, "Nowhere" });
    try tmpDir.dir.createDirPath(io, "Pictures");

    try expectPaths(&.{presentDir}, try filterExistingFolders(allocator, io, &.{ presentDir, absentDir }));
}

test "a file is not a folder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();
    const tempDir = try tempDirPath(allocator, tmpDir);
    const filePath = try path.join(allocator, &.{ tempDir, "Pictures" });
    try tmpDir.dir.writeFile(io, .{
        .sub_path = "Pictures",
        .data = "not a directory",
    });

    try expectPaths(&.{}, try filterExistingFolders(allocator, io, &.{filePath}));
}

test "returns an empty list rather than throwing when none exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try expectPaths(&.{}, try filterExistingFolders(allocator, io, &.{ "/definitely/not/here", "/nor/here" }));
}

test "returns only folders that exist on this machine" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const folders = try getDefaultPhotoFolders(allocator, io);
    for (folders) |folder| {
        const stat = try std.Io.Dir.cwd().statFile(io, folder, .{});
        try std.testing.expectEqual(std.Io.File.Kind.directory, stat.kind);
    }
}

//
// TypeScript trims the line with String.prototype.trim and matches it with /\s*/, both of which take the Unicode
// spaces and line separators as whitespace.
//
test "treats Unicode spaces around the key and the value as whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const contents = "\u{00A0}XDG_PICTURES_DIR\u{3000}=\u{3000}\"$HOME/Pics\"\u{2028}\n";
    const result = try parseXdgPicturesDir(arena.allocator(), contents, "/home/user");
    try std.testing.expectEqualStrings(try path.join(arena.allocator(), &.{ "/home/user", "Pics" }), result.?);
}

test "a line that is not a quoted XDG_PICTURES_DIR assignment names nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // No "=", a value that is not quoted, and a value whose quote is not closed at the end of the line.
    for ([_][]const u8{ "XDG_PICTURES_DIR\n", "XDG_PICTURES_DIR \"$HOME/Pics\"\n", "XDG_PICTURES_DIR=$HOME/Pics\n", "XDG_PICTURES_DIR=\"$HOME/Pics\n", "XDG_PICTURES_DIR=\n" }) |contents| {
        errdefer std.debug.print("case: {s}\n", .{contents});
        try std.testing.expect((try parseXdgPicturesDir(allocator, contents, "/home/someone")) == null);
    }
}

test "readXdgPicturesDir reports running out of memory instead of reading it as not configured" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();
    const homeDir = try tempDirPath(allocator, tmpDir);
    try tmpDir.dir.createDirPath(io, ".config");
    try tmpDir.dir.writeFile(io, .{ .sub_path = ".config/user-dirs.dirs", .data = "XDG_PICTURES_DIR=\"$HOME/Bilder\"\n" });

    // Every allocation fails in turn, the read of the file among them, until one run gets through.
    var failIndex: usize = 0;
    while (true) : (failIndex += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = failIndex });
        if (readXdgPicturesDir(failing.allocator(), io, homeDir)) |picturesDir| {
            try std.testing.expectEqualStrings(try path.join(allocator, &.{ homeDir, "Bilder" }), picturesDir.?);
            break;
        }
        else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
    try std.testing.expect(failIndex > 1);
}

//
// `.` in the TypeScript regular expression matches no line terminator, so a value holding one does not match and
// the search carries on to the next line.
//
test "a value holding a line terminator does not match, as in the TypeScript regular expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expect(try parseXdgPicturesDir(allocator, "XDG_PICTURES_DIR=\"/a\rb\"", "/home/user") == null);
    try std.testing.expect(try parseXdgPicturesDir(allocator, "XDG_PICTURES_DIR=\"/a\u{2028}b\"", "/home/user") == null);
    const result = try parseXdgPicturesDir(allocator, "XDG_PICTURES_DIR=\"/a\u{2029}b\"\nXDG_PICTURES_DIR=\"/c\"", "/home/user");
    try std.testing.expectEqualStrings("/c", result.?);
}
