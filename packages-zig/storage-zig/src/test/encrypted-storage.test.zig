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
    try std.testing.expect((try storage.checkWriteLock(allocator, io, "p")) == null);
    try std.testing.expect(try storage.acquireWriteLock(allocator, io, "p", "owner-1"));
    try storage.releaseWriteLock(allocator, io, "p");
    const expected = [_][]const u8{
        "isEmpty p",
        "listFiles p",
        "listDirs p",
        "fileExists p",
        "dirExists p",
        "info p",
        "deleteFile p",
        "deleteDir p",
        "copyTo p q",
        "checkWriteLock p",
        "acquireWriteLock p owner-1",
        "releaseWriteLock p",
    };
    try std.testing.expectEqual(expected.len, recording.calls.items.len);
    for (expected, recording.calls.items) |expectedCall, actualCall| {
        try std.testing.expectEqualStrings(expectedCall, actualCall);
    }
}

//
// The directory of the encryption-zig golden fixtures that the TypeScript encryption package wrote with ts-public.pem.
//
const encryption_fixtures_dir = "../encryption-zig/src/test/fixtures";

//
// The 44-byte header TypeScript wrote at the start of every file it encrypted with ts-public.pem: "PSEN", version 1
// (little endian), "A2CB" and the SHA-256 hash of the public key (encryption-zig fixture ts-public-hash.hex).
//
const ts_key_header = "PSEN" ++ "\x01\x00\x00\x00" ++ "A2CB" ++
    "\x95\x12\x45\x25\x51\x10\x55\x81\x60\x76\x53\x9f\x2c\x22\x82\x12" ++
    "\x57\x39\x8d\x71\x17\x8a\x1f\x70\x96\x3e\x22\xd6\x96\x64\xbe\x2c";

//
// A file TypeScript encrypted, and the plaintext size and encrypted length of the fixture.
//
const TypeScriptEncryptedFile = struct {
    // The fixture file name in encryption-zig/src/test/fixtures.
    fileName: []const u8,

    // The size of the plaintext in bytes.
    plainSize: usize,

    // The length of the encrypted fixture file in bytes.
    encryptedLength: usize,
};

//
// The files the TypeScript encryption package wrote with encryptBuffer (new-*) and createEncryptionStream (stream-*).
//
const ts_encrypted_files = [_]TypeScriptEncryptedFile{
    .{ .fileName = "new-0.bin", .plainSize = 0, .encryptedLength = 588 },
    .{ .fileName = "new-17.bin", .plainSize = 17, .encryptedLength = 604 },
    .{ .fileName = "new-1048576.bin", .plainSize = 1048576, .encryptedLength = 1049164 },
    .{ .fileName = "stream-0.bin", .plainSize = 0, .encryptedLength = 588 },
    .{ .fileName = "stream-16.bin", .plainSize = 16, .encryptedLength = 604 },
    .{ .fileName = "stream-17.bin", .plainSize = 17, .encryptedLength = 604 },
};

//
// Creates the plaintext of the encryption-zig fixtures (makePlaintext of its generate.ts): byte i is (i * 31 + 7) mod 256.
//
fn makeFixturePlaintext(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const plain = try allocator.alloc(u8, size);
    for (plain, 0..) |*byte, index| {
        byte.* = @truncate(index *% 31 +% 7);
    }
    return plain;
}

test "EncryptedStorage reads the files TypeScript encrypted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const dbDir = try helpers.makeTempDir(allocator, io, "encrypted-storage-ts-files");
    defer helpers.removeTempDir(io, dbDir);
    const created = try createStorage(allocator, io, dbDir, null, try loadFixtureOptions(allocator));
    try std.testing.expectEqualStrings("encrypted-fs", created.@"type");

    // The plaintext fixture TypeScript wrote matches the formula of its generator.
    const plain17 = try std.Io.Dir.cwd().readFileAlloc(io, encryption_fixtures_dir ++ "/plain-17.bin", allocator, .unlimited);
    try std.testing.expectEqualSlices(u8, "\x07\x26\x45\x64\x83\xa2\xc1\xe0\xff\x1e\x3d\x5c\x7b\x9a\xb9\xd8\xf7", plain17);
    try std.testing.expectEqualSlices(u8, plain17, try makeFixturePlaintext(allocator, 17));

    for (ts_encrypted_files) |tsFile| {
        const fixturePath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ encryption_fixtures_dir, tsFile.fileName });
        const encrypted = try std.Io.Dir.cwd().readFileAlloc(io, fixturePath, allocator, .unlimited);
        try std.testing.expectEqual(tsFile.encryptedLength, encrypted.len);
        try created.rawStorage.write(allocator, io, tsFile.fileName, null, encrypted);

        const plain = try makeFixturePlaintext(allocator, tsFile.plainSize);
        try std.testing.expectEqualSlices(u8, plain, (try created.storage.read(allocator, io, tsFile.fileName)).?);
        const stream = try created.storage.readStream(allocator, io, tsFile.fileName);
        defer stream.destroy(io);
        try std.testing.expectEqualSlices(u8, plain, try helpers.readAll(allocator, stream.reader()));
        try std.testing.expectEqual(@as(u64, tsFile.encryptedLength), (try created.storage.info(allocator, io, tsFile.fileName)).?.length);
    }
}

test "EncryptedStorage writes files with the header and length TypeScript writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const dbDir = try helpers.makeTempDir(allocator, io, "encrypted-storage-zig-files");
    defer helpers.removeTempDir(io, dbDir);
    const created = try createStorage(allocator, io, dbDir, null, try loadFixtureOptions(allocator));

    for (ts_encrypted_files) |tsFile| {
        const plain = try makeFixturePlaintext(allocator, tsFile.plainSize);
        const writeName = try std.fmt.allocPrint(allocator, "zig-write-{s}", .{tsFile.fileName});
        try created.storage.write(allocator, io, writeName, null, plain);
        const streamName = try std.fmt.allocPrint(allocator, "zig-stream-{s}", .{tsFile.fileName});
        var input = std.Io.Reader.fixed(plain);
        try created.storage.writeStream(allocator, io, streamName, null, &input, null);

        for ([_][]const u8{ writeName, streamName }) |fileName| {
            const raw = (try created.rawStorage.read(allocator, io, fileName)).?;
            try std.testing.expectEqual(tsFile.encryptedLength, raw.len);
            try std.testing.expectEqualSlices(u8, ts_key_header, raw[0..ts_key_header.len]);
            try std.testing.expectEqualSlices(u8, plain, (try created.storage.read(allocator, io, fileName)).?);
            try std.testing.expectEqual(@as(u64, tsFile.encryptedLength), (try created.storage.info(allocator, io, fileName)).?.length);
        }
    }
}

//
// readableLength has no test of its own in TypeScript; what it says of an encrypted store is pinned here.
//
test "readableLength is undefined, because the plaintext length cannot be worked out from the stored length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var recording = RecordingStorage.init(allocator);
    const encryptedStorage = try makeEncryptedStorage(allocator, recording.storage());

    try std.testing.expectEqual(@as(?u64, null), encryptedStorage.storage().readableLength(.{
        .contentType = null,
        .length = 1234,
        .lastModified = 0,
    }));
}
