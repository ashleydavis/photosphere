const std = @import("std");
const storage_zig = @import("storage-zig");
const utils = @import("utils-zig");
const helpers = @import("test-helpers.zig");

const FileStorage = storage_zig.file_storage.FileStorage;

//
// The fixture every test works on: a file storage and a unique temporary directory.
//
const Fixture = struct {
    // The arena for the test.
    arena: std.heap.ArenaAllocator,

    // The storage under test.
    fileStorage: FileStorage,

    // The temporary directory.
    tempDir: []const u8,

    //
    // Creates the fixture.
    //
    fn init(fixture: *Fixture, name: []const u8) !void {
        fixture.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        fixture.fileStorage = FileStorage.init("fs:");
        fixture.tempDir = try helpers.makeTempDir(fixture.arena.allocator(), std.testing.io, name);
    }

    //
    // Deletes the temporary directory and frees the arena.
    //
    fn deinit(fixture: *Fixture) void {
        helpers.removeTempDir(std.testing.io, fixture.tempDir);
        fixture.arena.deinit();
    }

    //
    // Gets a path inside the temporary directory.
    //
    fn path(fixture: *Fixture, relativePath: []const u8) ![]const u8 {
        return std.fmt.allocPrint(fixture.arena.allocator(), "{s}/{s}", .{ fixture.tempDir, relativePath });
    }
};

test "storage() exposes the location and forwards to the FileStorage methods" {
    var fixture: Fixture = undefined;
    try fixture.init("file-storage-interface");
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const storage = fixture.fileStorage.storage();
    try std.testing.expectEqualStrings("fs:", storage.location);
    try storage.write(allocator, std.testing.io, try fixture.path("a.txt"), null, "hello");
    try std.testing.expectEqualStrings("hello", (try storage.read(allocator, std.testing.io, try fixture.path("a.txt"))).?);
}

test "isEmpty returns true for a missing or empty directory and false otherwise" {
    var fixture: Fixture = undefined;
    try fixture.init("file-storage-is-empty");
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    try std.testing.expect(try fixture.fileStorage.isEmpty(allocator, io, try fixture.path("missing")));
    try std.testing.expect(try fixture.fileStorage.isEmpty(allocator, io, fixture.tempDir));
    try helpers.writeFile(io, try fixture.path("sub/file.txt"), "x");
    try std.testing.expect(!try fixture.fileStorage.isEmpty(allocator, io, fixture.tempDir));
    try std.testing.expect(!try fixture.fileStorage.isEmpty(allocator, io, try fixture.path("sub")));
}

test "listFiles lists only files, sorted like localeCompare with numeric ordering, in one page" {
    var fixture: Fixture = undefined;
    try fixture.init("file-storage-list-files");
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const fileNames = [_][]const u8{ "file10", "file2", "File1", "file1", "b.txt", "a.txt", "_x", "10", "9" };
    for (fileNames) |fileName| {
        try helpers.writeFile(io, try fixture.path(fileName), "x");
    }
    try std.Io.Dir.cwd().createDirPath(io, try fixture.path("dir"));

    const result = try fixture.fileStorage.listFiles(allocator, io, fixture.tempDir, 2, null);
    const expected = [_][]const u8{ "_x", "9", "10", "a.txt", "b.txt", "file1", "File1", "file2", "file10" };
    try std.testing.expectEqual(expected.len, result.names.len);
    for (expected, result.names) |expectedName, actualName| {
        try std.testing.expectEqualStrings(expectedName, actualName);
    }
    try std.testing.expect(result.next == null);
}

test "listFiles returns no names for a missing directory" {
    var fixture: Fixture = undefined;
    try fixture.init("file-storage-list-files-missing");
    defer fixture.deinit();
    const result = try fixture.fileStorage.listFiles(fixture.arena.allocator(), std.testing.io, try fixture.path("missing"), 1000, null);
    try std.testing.expectEqual(@as(usize, 0), result.names.len);
    try std.testing.expect(result.next == null);
}

test "listDirs lists only directories, sorted" {
    var fixture: Fixture = undefined;
    try fixture.init("file-storage-list-dirs");
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const dirNames = [_][]const u8{ "shard11", "shard2", "shard1" };
    for (dirNames) |dirName| {
        try std.Io.Dir.cwd().createDirPath(io, try fixture.path(dirName));
    }
    try helpers.writeFile(io, try fixture.path("file.txt"), "x");

    const result = try fixture.fileStorage.listDirs(allocator, io, fixture.tempDir, 1000, null);
    const expected = [_][]const u8{ "shard1", "shard2", "shard11" };
    try std.testing.expectEqual(expected.len, result.names.len);
    for (expected, result.names) |expectedName, actualName| {
        try std.testing.expectEqualStrings(expectedName, actualName);
    }
    const missing = try fixture.fileStorage.listDirs(allocator, io, try fixture.path("missing"), 1000, null);
    try std.testing.expectEqual(@as(usize, 0), missing.names.len);
}

test "fileExists is true only for files and dirExists only for directories" {
    var fixture: Fixture = undefined;
    try fixture.init("file-storage-exists");
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    try helpers.writeFile(io, try fixture.path("dir/file.txt"), "x");
    try std.testing.expect(try fixture.fileStorage.fileExists(allocator, io, try fixture.path("dir/file.txt")));
    try std.testing.expect(!try fixture.fileStorage.fileExists(allocator, io, try fixture.path("dir")));
    try std.testing.expect(!try fixture.fileStorage.fileExists(allocator, io, try fixture.path("missing")));
    try std.testing.expect(try fixture.fileStorage.dirExists(allocator, io, try fixture.path("dir")));
    try std.testing.expect(!try fixture.fileStorage.dirExists(allocator, io, try fixture.path("dir/file.txt")));
    try std.testing.expect(!try fixture.fileStorage.dirExists(allocator, io, try fixture.path("missing")));
}

test "info returns the length and last modified time of a file, and null for directories and missing files" {
    var fixture: Fixture = undefined;
    try fixture.init("file-storage-info");
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const before = std.Io.Clock.real.now(io).toMilliseconds();
    try helpers.writeFile(io, try fixture.path("file.bin"), "12345");
    const after = std.Io.Clock.real.now(io).toMilliseconds();
    const fileInfo = (try fixture.fileStorage.info(allocator, io, try fixture.path("file.bin"))).?;
    try std.testing.expectEqual(@as(u64, 5), fileInfo.length);
    try std.testing.expect(fileInfo.contentType == null);
    try std.testing.expect(fileInfo.lastModified >= before - 1000 and fileInfo.lastModified <= after + 1000);
    try std.testing.expect((try fixture.fileStorage.info(allocator, io, fixture.tempDir)) == null);
    try std.testing.expect((try fixture.fileStorage.info(allocator, io, try fixture.path("missing"))) == null);
}

test "read returns the file contents or null when missing" {
    var fixture: Fixture = undefined;
    try fixture.init("file-storage-read");
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    try helpers.writeFile(io, try fixture.path("file.bin"), "contents");
    try std.testing.expectEqualStrings("contents", (try fixture.fileStorage.read(allocator, io, try fixture.path("file.bin"))).?);
    try std.testing.expect((try fixture.fileStorage.read(allocator, io, try fixture.path("missing"))) == null);
}

test "write creates the directory, replaces the file and leaves no .tmp file" {
    var fixture: Fixture = undefined;
    try fixture.init("file-storage-write");
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const filePath = try fixture.path("nested/deeper/file.bin");
    try fixture.fileStorage.write(allocator, io, filePath, "application/octet-stream", "first");
    try fixture.fileStorage.write(allocator, io, filePath, null, "second");
    try std.testing.expectEqualStrings("second", (try fixture.fileStorage.read(allocator, io, filePath)).?);
    const names = (try fixture.fileStorage.listFiles(allocator, io, try fixture.path("nested/deeper"), 1000, null)).names;
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("file.bin", names[0]);
}

test "readStream streams the file contents" {
    var fixture: Fixture = undefined;
    try fixture.init("file-storage-read-stream");
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const data = try helpers.makeData(allocator, 300 * 1024);
    try helpers.writeFile(io, try fixture.path("big.bin"), data);
    const stream = try fixture.fileStorage.readStream(allocator, io, try fixture.path("big.bin"));
    defer stream.destroy(io);
    try std.testing.expectEqualSlices(u8, data, try helpers.readAll(allocator, stream.reader()));
}

test "readStream fails with the Node ENOENT message for a missing file" {
    var fixture: Fixture = undefined;
    try fixture.init("file-storage-read-stream-missing");
    defer fixture.deinit();
    const missingPath = try fixture.path("missing.bin");
    try std.testing.expectError(error.Thrown, fixture.fileStorage.readStream(fixture.arena.allocator(), std.testing.io, missingPath));
    const expected = try std.fmt.allocPrint(fixture.arena.allocator(), "ENOENT: no such file or directory, open '{s}'", .{missingPath});
    try std.testing.expectEqualStrings(expected, utils.errors.lastErrorMessage());
}

test "writeStream writes the stream to the file and leaves no .tmp file" {
    var fixture: Fixture = undefined;
    try fixture.init("file-storage-write-stream");
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const data = try helpers.makeData(allocator, 200 * 1024 + 3);
    var input = std.Io.Reader.fixed(data);
    const filePath = try fixture.path("out/file.bin");
    try fixture.fileStorage.writeStream(allocator, io, filePath, null, &input, null);
    try std.testing.expectEqualSlices(u8, data, (try fixture.fileStorage.read(allocator, io, filePath)).?);
    try std.testing.expect(!try fixture.fileStorage.fileExists(allocator, io, try fixture.path("out/file.bin.tmp")));
}

test "deleteFile deletes a file and ignores a missing file" {
    var fixture: Fixture = undefined;
    try fixture.init("file-storage-delete-file");
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    try helpers.writeFile(io, try fixture.path("file.bin"), "x");
    try fixture.fileStorage.deleteFile(allocator, io, try fixture.path("file.bin"));
    try std.testing.expect(!try fixture.fileStorage.fileExists(allocator, io, try fixture.path("file.bin")));
    try fixture.fileStorage.deleteFile(allocator, io, try fixture.path("file.bin"));
}

test "deleteDir deletes a directory tree and ignores a missing directory" {
    var fixture: Fixture = undefined;
    try fixture.init("file-storage-delete-dir");
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    try helpers.writeFile(io, try fixture.path("dir/a/b.txt"), "x");
    try fixture.fileStorage.deleteDir(allocator, io, try fixture.path("dir"));
    try std.testing.expect(!try fixture.fileStorage.dirExists(allocator, io, try fixture.path("dir")));
    try fixture.fileStorage.deleteDir(allocator, io, try fixture.path("dir"));
}

test "copyTo copies a file and creates the destination directory" {
    var fixture: Fixture = undefined;
    try fixture.init("file-storage-copy-to");
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    try helpers.writeFile(io, try fixture.path("source.bin"), "copied");
    try fixture.fileStorage.copyTo(allocator, io, try fixture.path("source.bin"), try fixture.path("dest/copy.bin"));
    try std.testing.expectEqualStrings("copied", (try fixture.fileStorage.read(allocator, io, try fixture.path("dest/copy.bin"))).?);
}
