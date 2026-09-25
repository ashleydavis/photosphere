const std = @import("std");
const cli = @import("cli-zig");
const helpers = @import("test-helpers.zig");
const storage_helper = cli.storage_helper;

test "local paths never fetch S3 credentials" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(try storage_helper.fetchS3CredentialsForPath(arena.allocator(), std.testing.io, "/some/local/path") == null);
    try std.testing.expect(try storage_helper.fetchS3CredentialsForPath(arena.allocator(), std.testing.io, "fs:/data") == null);
}

test "createStorageForPath creates file storage for a local path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tmpDir = try helpers.makeTempDir(allocator, "storage-helper");
    defer std.Io.Dir.cwd().deleteTree(io, tmpDir) catch {};
    const result = try storage_helper.createStorageForPath(allocator, io, tmpDir, null);
    try std.testing.expectEqualStrings("fs", result.type);
    try result.storage.write(allocator, io, "hello.txt", null, "hi");
    try std.testing.expect(try result.storage.fileExists(allocator, io, "hello.txt"));
}
