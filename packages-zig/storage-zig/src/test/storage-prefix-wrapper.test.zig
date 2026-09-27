const std = @import("std");
const storage_zig = @import("storage-zig");
const utils = @import("utils-zig");
const encryption = @import("encryption-zig");
const RecordingStorage = @import("recording-storage.zig").RecordingStorage;

const StoragePrefixWrapper = storage_zig.storage_prefix_wrapper.StoragePrefixWrapper;

test "throws when the prefix is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var recording = RecordingStorage.init(allocator);
    try std.testing.expectError(error.Thrown, StoragePrefixWrapper.init(allocator, recording.storage(), ""));
    try std.testing.expectEqualStrings("Prefix must not be empty.", utils.errors.lastErrorMessage());
}

test "location joins the wrapped location and the prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var recording = RecordingStorage.init(allocator);
    var wrapper = try StoragePrefixWrapper.init(allocator, recording.storage(), "/db/path/");
    try std.testing.expectEqualStrings("rec:/db/path", wrapper.location);
    try std.testing.expectEqualStrings("rec:/db/path", wrapper.storage().location);
}

test "every method joins the prefix and the path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var recording = RecordingStorage.init(allocator);
    var wrapper = try StoragePrefixWrapper.init(allocator, recording.storage(), "/db");
    const storage = wrapper.storage();
    _ = try storage.isEmpty(allocator, io, "/");
    _ = try storage.isEmpty(allocator, io, "./");
    _ = try storage.listFiles(allocator, io, ".db/bson", 1000, null);
    _ = try storage.listDirs(allocator, io, "", 1000, null);
    _ = try storage.fileExists(allocator, io, "asset/1");
    _ = try storage.dirExists(allocator, io, "asset");
    try std.testing.expectEqual(@as(u64, 42), (try storage.info(allocator, io, "asset/1")).?.length);
    try std.testing.expectEqualStrings("data", (try storage.read(allocator, io, "asset/1")).?);
    try storage.write(allocator, io, "asset/1", null, "x");
    try std.testing.expectError(error.NotImplemented, storage.readStream(allocator, io, "asset/2"));
    var input = std.Io.Reader.fixed("x");
    try storage.writeStream(allocator, io, "asset/2", null, &input, null);
    try storage.deleteFile(allocator, io, "asset//3");
    try storage.deleteDir(allocator, io, "asset/");
    try storage.copyTo(allocator, io, "a", "b");
    try std.testing.expect((try storage.checkWriteLock(allocator, io, ".db/write.lock")) == null);
    try std.testing.expect(try storage.acquireWriteLock(allocator, io, ".db/write.lock", "owner-1"));
    try storage.releaseWriteLock(allocator, io, ".db/write.lock");

    const expected = [_][]const u8{
        "isEmpty /db",
        "isEmpty /db/.",
        "listFiles /db/.db/bson",
        "listDirs /db",
        "fileExists /db/asset/1",
        "dirExists /db/asset",
        "info /db/asset/1",
        "read /db/asset/1",
        "write /db/asset/1",
        "readStream /db/asset/2",
        "writeStream /db/asset/2",
        "deleteFile /db/asset/3",
        "deleteDir /db/asset",
        "copyTo /db/a /db/b",
        "checkWriteLock /db/.db/write.lock",
        "acquireWriteLock /db/.db/write.lock owner-1",
        "releaseWriteLock /db/.db/write.lock",
    };
    try std.testing.expectEqual(expected.len, recording.calls.items.len);
    for (expected, recording.calls.items) |expectedCall, actualCall| {
        try std.testing.expectEqualStrings(expectedCall, actualCall);
    }
}

test "a prefix that ends with a colon is concatenated with the path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var recording = RecordingStorage.init(allocator);
    var wrapper = try StoragePrefixWrapper.init(allocator, recording.storage(), "fs:");
    _ = try wrapper.fileExists(allocator, std.testing.io, "/some//path");
    try std.testing.expectEqualStrings("fileExists fs:/some//path", recording.calls.items[0]);
}

//
// readableLength has no test of its own in TypeScript; that the wrapper asks the storage underneath is
// pinned here, with an encrypted storage underneath because it is the one store that answers differently
// from the length in the info.
//
test "readableLength asks the storage underneath" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var recording = RecordingStorage.init(allocator);
    const fileInfo: storage_zig.storage.IFileInfo = .{
        .contentType = null,
        .length = 1234,
        .lastModified = 0,
    };

    var plainWrapper = try StoragePrefixWrapper.init(allocator, recording.storage(), "/db");
    try std.testing.expectEqual(@as(?u64, 1234), plainWrapper.storage().readableLength(fileInfo));

    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    const privateKeyPem = try cwd.readFileAlloc(io, "../encryption-zig/src/test/fixtures/ts-private.pem", allocator, .unlimited);
    const publicKeyPem = try cwd.readFileAlloc(io, "../encryption-zig/src/test/fixtures/ts-public.pem", allocator, .unlimited);
    const loaded = try encryption.key_utils.loadEncryptionKeysFromPem(allocator, &.{.{
        .privateKeyPem = privateKeyPem,
        .publicKeyPem = publicKeyPem,
    }});
    var encryptedStorage = storage_zig.encrypted_storage.EncryptedStorage.init(recording.storage().location, recording.storage(), loaded.options.decryptionKeyMap.?, loaded.options.encryptionPublicKey.?);
    var encryptedWrapper = try StoragePrefixWrapper.init(allocator, encryptedStorage.storage(), "/db");
    try std.testing.expectEqual(@as(?u64, null), encryptedWrapper.storage().readableLength(fileInfo));
}
