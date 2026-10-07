//
// Writing a stream to storage, when that stream is reading a file and when it is not (port of
// src/tests/file-storage-write-stream.test.ts).
//
// A stream that carries the path of the file it is reading is copied file to file rather than piped
// through. Both paths have to produce identical bytes, because one of them is used for every photo taken into a
// database and the other for everything that is transformed on its way in, such as an encrypted write.
//

const test_files = @import("test-files.zig");
const std = @import("std");
const storage_zig = @import("storage-zig");

const FileStorage = storage_zig.file_storage.FileStorage;

test "a file-backed stream is written byte for byte" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tempDir = try test_files.makeTempDir(allocator, io, "temp-test-write-stream");
    defer test_files.removeTempDir(io, tempDir);
    var storage = FileStorage.init(tempDir);

    const contents = try allocator.alloc(u8, 3 * 1024 * 1024);
    for (contents, 0..) |*byte, index| {
        byte.* = @intCast(index % 251);
    }
    const sourcePath = try std.fmt.allocPrint(allocator, "{s}/source.bin", .{tempDir});
    const copiedPath = try std.fmt.allocPrint(allocator, "{s}/copied.bin", .{tempDir});
    try test_files.writeFile(io, sourcePath, contents);

    const stream = try storage.readStream(allocator, io, sourcePath);
    defer stream.destroy(io);
    try storage.writeStream(allocator, io, copiedPath, "application/octet-stream", stream.reader(), null);

    const written = (try storage.read(allocator, io, copiedPath)).?;
    try std.testing.expectEqualSlices(u8, contents, written);
}

test "a stream with no path behind it is still piped through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tempDir = try test_files.makeTempDir(allocator, io, "temp-test-write-stream");
    defer test_files.removeTempDir(io, tempDir);
    var storage = FileStorage.init(tempDir);

    // An encrypting stream is one of these: it carries no path, because what it produces is not any file on disk.
    // Taking the copy path for it would write the wrong bytes.
    const contents = "not backed by any file";
    const pipedPath = try std.fmt.allocPrint(allocator, "{s}/piped.bin", .{tempDir});
    var input = std.Io.Reader.fixed(contents);
    try storage.writeStream(allocator, io, pipedPath, "application/octet-stream", &input, null);

    const written = (try storage.read(allocator, io, pipedPath)).?;
    try std.testing.expectEqualSlices(u8, contents, written);
}

test "an empty file-backed stream produces an empty file, not a missing one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tempDir = try test_files.makeTempDir(allocator, io, "temp-test-write-stream");
    defer test_files.removeTempDir(io, tempDir);
    var storage = FileStorage.init(tempDir);

    const sourcePath = try std.fmt.allocPrint(allocator, "{s}/empty-source.bin", .{tempDir});
    const copyPath = try std.fmt.allocPrint(allocator, "{s}/empty-copy.bin", .{tempDir});
    try test_files.writeFile(io, sourcePath, "");

    const stream = try storage.readStream(allocator, io, sourcePath);
    defer stream.destroy(io);
    try storage.writeStream(allocator, io, copyPath, "application/octet-stream", stream.reader(), null);

    const written = (try storage.read(allocator, io, copyPath)).?;
    try std.testing.expectEqual(@as(usize, 0), written.len);
}
