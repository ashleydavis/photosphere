const std = @import("std");
const storage_zig = @import("storage-zig");
const encryption = @import("encryption-zig");
const helpers = @import("test-helpers.zig");
const RecordingStorage = @import("recording-storage.zig").RecordingStorage;

const EncryptedStorage = storage_zig.encrypted_storage.EncryptedStorage;
const FileStorage = storage_zig.file_storage.FileStorage;
const createStorage = storage_zig.storage_factory.createStorage;
const key_utils = encryption.key_utils;
const computeEncryptedLength = encryption.encrypt_stream.computeEncryptedLength;

//
// Loads the TypeScript fixture key of encryption-zig as storage options.
//
fn loadFixtureOptions(allocator: std.mem.Allocator) !encryption.encryption_types.IStorageOptions {
    const cwd = std.Io.Dir.cwd();
    const io = std.testing.io;
    const privateKeyPem = try cwd.readFileAlloc(io, "../encryption-zig/src/test/fixtures/ts-private.pem", allocator, .unlimited);
    const publicKeyPem = try cwd.readFileAlloc(io, "../encryption-zig/src/test/fixtures/ts-public.pem", allocator, .unlimited);
    const loaded = try key_utils.loadEncryptionKeysFromPem(allocator, &.{.{ .privateKeyPem = privateKeyPem, .publicKeyPem = publicKeyPem }});
    return loaded.options;
}

//
// Creates an EncryptedStorage over a storage with the fixture key.
//
fn makeEncryptedStorage(allocator: std.mem.Allocator, inner: storage_zig.storage.IStorage) !*EncryptedStorage {
    const options = try loadFixtureOptions(allocator);
    const encryptedStorage = try allocator.create(EncryptedStorage);
    encryptedStorage.* = EncryptedStorage.init(inner.location, inner, options.decryptionKeyMap.?, options.encryptionPublicKey.?);
    return encryptedStorage;
}

test "write encrypts, read decrypts and info returns the raw on-disk length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tempDir = try helpers.makeTempDir(allocator, io, "encrypted-storage-write");
    defer helpers.removeTempDir(io, tempDir);
    var fileStorage = FileStorage.init("fs:");
    const encryptedStorage = try makeEncryptedStorage(allocator, fileStorage.storage());
    const storage = encryptedStorage.storage();
    try std.testing.expectEqualStrings("fs:", storage.location);

    const plain = try helpers.makeData(allocator, 1000);
    const filePath = try std.fmt.allocPrint(allocator, "{s}/file.bin", .{tempDir});
    try storage.write(allocator, io, filePath, null, plain);

    const raw = (try fileStorage.read(allocator, io, filePath)).?;
    try std.testing.expectEqualStrings(encryption.encryption_constants.ENCRYPTION_TAG, raw[0..4]);
    try std.testing.expectEqual(computeEncryptedLength(plain.len), raw.len);
    try std.testing.expectEqualSlices(u8, plain, (try storage.read(allocator, io, filePath)).?);
    try std.testing.expectEqual(@as(u64, raw.len), (try storage.info(allocator, io, filePath)).?.length);
    try std.testing.expect((try storage.read(allocator, io, try std.fmt.allocPrint(allocator, "{s}/missing", .{tempDir}))) == null);
}

test "readStream decrypts and writeStream encrypts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tempDir = try helpers.makeTempDir(allocator, io, "encrypted-storage-stream");
    defer helpers.removeTempDir(io, tempDir);
    var fileStorage = FileStorage.init("fs:");
    const encryptedStorage = try makeEncryptedStorage(allocator, fileStorage.storage());

    const plain = try helpers.makeData(allocator, 300 * 1024 + 5);
    const filePath = try std.fmt.allocPrint(allocator, "{s}/stream.bin", .{tempDir});
    var input = std.Io.Reader.fixed(plain);
    try encryptedStorage.writeStream(allocator, io, filePath, null, &input, plain.len);
    const raw = (try fileStorage.read(allocator, io, filePath)).?;
    try std.testing.expectEqual(computeEncryptedLength(plain.len), raw.len);

    const stream = try encryptedStorage.readStream(allocator, io, filePath);
    defer stream.destroy(io);
    try std.testing.expectEqualSlices(u8, plain, try helpers.readAll(allocator, stream.reader()));
}

test "unencrypted files are read unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tempDir = try helpers.makeTempDir(allocator, io, "encrypted-storage-plain");
    defer helpers.removeTempDir(io, tempDir);
    var fileStorage = FileStorage.init("fs:");
    const encryptedStorage = try makeEncryptedStorage(allocator, fileStorage.storage());
    const filePath = try std.fmt.allocPrint(allocator, "{s}/plain.txt", .{tempDir});
    try fileStorage.write(allocator, io, filePath, null, "not encrypted");
    try std.testing.expectEqualStrings("not encrypted", (try encryptedStorage.read(allocator, io, filePath)).?);
}

test "the other methods forward to the wrapped storage unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var recording = RecordingStorage.init(allocator);
    const encryptedStorage = try makeEncryptedStorage(allocator, recording.storage());
    const storage = encryptedStorage.storage();
    _ = try storage.isEmpty(allocator, io, "p");
    _ = try storage.listFiles(allocator, io, "p", 1, null);
    _ = try storage.listDirs(allocator, io, "p", 1, null);
    _ = try storage.fileExists(allocator, io, "p");
    _ = try storage.dirExists(allocator, io, "p");
    _ = try storage.info(allocator, io, "p");
    try storage.deleteFile(allocator, io, "p");
    try storage.deleteDir(allocator, io, "p");
    try storage.copyTo(allocator, io, "p", "q");
    const expected = [_][]const u8{ "isEmpty p", "listFiles p", "listDirs p", "fileExists p", "dirExists p", "info p", "deleteFile p", "deleteDir p", "copyTo p q" };
    try std.testing.expectEqual(expected.len, recording.calls.items.len);
    for (expected, recording.calls.items) |expectedCall, actualCall| {
        try std.testing.expectEqualStrings(expectedCall, actualCall);
    }
}

//
// Runs the TypeScript interop script and fails the test when it reports a failure.
//
fn runInteropScript(allocator: std.mem.Allocator, mode: []const u8, dbDir: []const u8) !void {
    const result = std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "bun", "run", "src/test/fixtures/encrypted-storage-interop.ts", mode, dbDir },
    }) catch |err| {
        std.debug.print("Failed to run bun (it must be on PATH): {s}\n", .{@errorName(err)});
        return err;
    };
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("encrypted-storage-interop.ts {s} failed:\n{s}\n{s}\n", .{ mode, result.stdout, result.stderr });
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqualStrings("OK\n", result.stdout);
}

test "EncryptedStorage files are readable by TypeScript and TypeScript files are readable by Zig" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const dbDir = try helpers.makeTempDir(allocator, io, "encrypted-storage-interop");
    defer helpers.removeTempDir(io, dbDir);

    const plain = try helpers.makeData(allocator, 200 * 1024 + 17);
    const created = try createStorage(allocator, io, dbDir, null, try loadFixtureOptions(allocator));
    try std.testing.expectEqualStrings("encrypted-fs", created.@"type");
    try created.rawStorage.write(allocator, io, "plain.bin", null, plain);

    // Zig writes, TypeScript reads.
    try created.storage.write(allocator, io, "zig-write.bin", null, plain);
    var input = std.Io.Reader.fixed(plain);
    try created.storage.writeStream(allocator, io, "zig-stream.bin", null, &input, null);
    try runInteropScript(allocator, "verify", dbDir);

    // TypeScript writes, Zig reads.
    try runInteropScript(allocator, "write", dbDir);
    const fileNames = [_][]const u8{ "ts-write.bin", "ts-stream.bin" };
    for (fileNames) |fileName| {
        const raw = (try created.rawStorage.read(allocator, io, fileName)).?;
        try std.testing.expectEqualStrings("PSEN", raw[0..4]);
        try std.testing.expectEqualSlices(u8, plain, (try created.storage.read(allocator, io, fileName)).?);
        const stream = try created.storage.readStream(allocator, io, fileName);
        defer stream.destroy(io);
        try std.testing.expectEqualSlices(u8, plain, try helpers.readAll(allocator, stream.reader()));
        try std.testing.expectEqual(@as(u64, raw.len), (try created.storage.info(allocator, io, fileName)).?.length);
    }
}
