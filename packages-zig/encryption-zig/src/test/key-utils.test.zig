const std = @import("std");
const encryption = @import("encryption-zig");
const utils = @import("utils-zig");
const fixtures = @import("fixtures.zig");
const mock_log = @import("mock-log.zig");

const key_utils = encryption.key_utils;
const crypto = encryption.node_crypto;

//
// Loads a committed fixture PEM pair ("ts" or "ts2").
//
fn loadFixturePem(allocator: std.mem.Allocator, prefix: []const u8) !key_utils.IEncryptionKeyPem {
    return key_utils.IEncryptionKeyPem{
        .privateKeyPem = try fixtures.readFixture(allocator, try std.mem.concat(allocator, u8, &.{ prefix, "-private.pem" })),
        .publicKeyPem = try fixtures.readFixture(allocator, try std.mem.concat(allocator, u8, &.{ prefix, "-public.pem" })),
    };
}

test "returns a 32-byte buffer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keyPair = try key_utils.generateKeyPair(allocator, std.testing.io);
    const hash = try key_utils.hashPublicKey(allocator, keyPair.publicKey);
    try std.testing.expectEqual(@as(usize, 32), hash.len);

    //
    // The generated key pair is RSA-4096 and its public key matches the private key.
    //
    try std.testing.expectEqual(@as(usize, 512), keyPair.publicKey.modulusLength());
    try std.testing.expectEqualSlices(u8, keyPair.privateKey.public_key.spki, keyPair.publicKey.spki);
    const encrypted = try crypto.publicEncrypt(allocator, std.testing.io, keyPair.publicKey, "key");
    try std.testing.expectEqualStrings("key", try crypto.privateDecrypt(allocator, keyPair.privateKey, encrypted));
}

test "is deterministic for the same key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keyPem = try loadFixturePem(allocator, "ts");
    const publicKey = try crypto.createPublicKey(allocator, keyPem.publicKeyPem);
    const hash1 = try key_utils.hashPublicKey(allocator, publicKey);
    const hash2 = try key_utils.hashPublicKey(allocator, publicKey);
    try std.testing.expectEqualSlices(u8, &hash1, &hash2);
}

test "produces different hashes for different keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const publicKey1 = try crypto.createPublicKey(allocator, (try loadFixturePem(allocator, "ts")).publicKeyPem);
    const publicKey2 = try crypto.createPublicKey(allocator, (try loadFixturePem(allocator, "ts2")).publicKeyPem);
    const hash1 = try key_utils.hashPublicKey(allocator, publicKey1);
    const hash2 = try key_utils.hashPublicKey(allocator, publicKey2);
    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash2));
}

test "hashPublicKey equals the fixture hash for the same key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const prefixes = [_][]const u8{ "ts", "ts2" };
    for (prefixes) |prefix| {
        const keyPem = try loadFixturePem(allocator, prefix);
        const expectedHex = try fixtures.readFixture(allocator, try std.mem.concat(allocator, u8, &.{ prefix, "-public-hash.hex" }));
        const fromPublic = try key_utils.hashPublicKey(allocator, try crypto.createPublicKey(allocator, keyPem.publicKeyPem));
        try std.testing.expectEqualStrings(expectedHex, &std.fmt.bytesToHex(fromPublic, .lower));
        const privateKey = try crypto.createPrivateKey(allocator, keyPem.privateKeyPem);
        const fromPrivate = try key_utils.hashPublicKey(allocator, crypto.createPublicKeyFromPrivateKey(privateKey));
        try std.testing.expectEqualStrings(expectedHex, &std.fmt.bytesToHex(fromPrivate, .lower));
    }
}

test "exportPublicKeyToPem reproduces the fixture PEM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keyPem = try loadFixturePem(allocator, "ts");
    const privateKey = try crypto.createPrivateKey(allocator, keyPem.privateKeyPem);
    const exported = try key_utils.exportPublicKeyToPem(allocator, crypto.createPublicKeyFromPrivateKey(privateKey));
    try std.testing.expectEqualStrings(keyPem.publicKeyPem, exported);
}

test "returns empty options when no key pems are provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = try key_utils.loadEncryptionKeysFromPem(allocator, &.{});
    try std.testing.expect(!result.isEncrypted);
    try std.testing.expect(result.options.decryptionKeyMap == null);
    try std.testing.expect(result.options.encryptionPublicKey == null);
}

test "builds decryptionKeyMap and encryptionPublicKey for a single key pem" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keyPem = try loadFixturePem(allocator, "ts");
    const result = try key_utils.loadEncryptionKeysFromPem(allocator, &.{keyPem});
    try std.testing.expect(result.isEncrypted);
    const map = result.options.decryptionKeyMap.?;
    const writeKey = result.options.encryptionPublicKey.?;
    const defaultKey = map.get("default").?;
    const hashHex = std.fmt.bytesToHex(try key_utils.hashPublicKey(allocator, writeKey), .lower);
    const entryKey = map.get(&hashHex).?;
    try std.testing.expect(entryKey == defaultKey);
    try std.testing.expectEqual(@as(usize, 2), map.count());
}

test "registers multiple keys and uses the first as default/write key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keyPem1 = try loadFixturePem(allocator, "ts");
    const keyPem2 = try loadFixturePem(allocator, "ts2");
    const result = try key_utils.loadEncryptionKeysFromPem(allocator, &.{ keyPem1, keyPem2 });
    try std.testing.expect(result.isEncrypted);
    const map = result.options.decryptionKeyMap.?;
    try std.testing.expectEqual(@as(usize, 3), map.count());
    const hash1 = try fixtures.readFixture(allocator, "ts-public-hash.hex");
    const hash2 = try fixtures.readFixture(allocator, "ts2-public-hash.hex");
    try std.testing.expect(map.get(hash1).? == map.get("default").?);
    try std.testing.expect(map.get(hash2).? != map.get("default").?);
    const writeHash = std.fmt.bytesToHex(try key_utils.hashPublicKey(allocator, result.options.encryptionPublicKey.?), .lower);
    try std.testing.expectEqualStrings(hash1, &writeHash);
}

test "loadEncryptionKeysFromPem throws for an invalid PEM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keyPem = key_utils.IEncryptionKeyPem{ .privateKeyPem = "not a key", .publicKeyPem = "not a key" };
    try std.testing.expectError(error.Thrown, key_utils.loadEncryptionKeysFromPem(allocator, &.{keyPem}));
    try std.testing.expectEqualStrings("error:1E08010C:DECODER routines::unsupported", utils.errors.lastErrorMessage());
}

test "builds encrypting storage options from a key pair" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // (The fixture key pair stands in for a generated key pair, which is slow in Debug builds.)
    const keyPem = try loadFixturePem(allocator, "ts");
    const result = try key_utils.loadEncryptionKeysFromPem(allocator, &.{keyPem});

    try std.testing.expect(result.isEncrypted);
    try std.testing.expect(result.options.encryptionPublicKey != null);
}

test "reports no encryption for an empty key list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // An unencrypted database goes through here with nothing in the list, every time a storage is
    // built, so this path must stay quiet.
    const result = try key_utils.loadEncryptionKeysFromPem(allocator, &.{});
    try std.testing.expect(!result.isEncrypted);
    try std.testing.expect(result.options.decryptionKeyMap == null);
    try std.testing.expect(result.options.encryptionPublicKey == null);
}

//
// Gets the absolute path of a directory made by std.testing.tmpDir.
//
fn tempDirPath(allocator: std.mem.Allocator, tmpDir: std.testing.TmpDir) ![]const u8 {
    const currentPath = try std.process.currentPathAlloc(std.testing.io, allocator);
    return std.fs.path.join(allocator, &.{ currentPath, ".zig-cache", "tmp", &tmpDir.sub_path });
}

//
// Builds a key pair from a committed fixture, because generating one is slow in Debug builds.
//
fn fixtureKeyPair(allocator: std.mem.Allocator) !key_utils.IKeyPair {
    const keyPem = try loadFixturePem(allocator, "ts");
    return key_utils.IKeyPair{
        .privateKey = try crypto.createPrivateKey(allocator, keyPem.privateKeyPem),
        .publicKey = try crypto.createPublicKey(allocator, keyPem.publicKeyPem),
    };
}

test "saveKeyPair writes the private key and the public key beside it, creating the directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();

    const keyFilePath = try std.fs.path.join(allocator, &.{ try tempDirPath(allocator, tmpDir), "nested", "key" });
    const keyPair = try fixtureKeyPair(allocator);
    try key_utils.saveKeyPair(allocator, std.testing.io, keyPair, keyFilePath);

    const keyPem = try loadFixturePem(allocator, "ts");
    const privateOnDisk = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, keyFilePath, allocator, .unlimited);
    const publicOnDisk = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, try std.mem.concat(allocator, u8, &.{ keyFilePath, ".pub" }), allocator, .unlimited);
    try std.testing.expectEqualStrings(try crypto.exportPrivateKey(allocator, keyPair.privateKey, .pem), privateOnDisk);
    try std.testing.expectEqualStrings(keyPem.publicKeyPem, publicOnDisk);
}

test "loadPrivateKey and loadPublicKey return null for a file that does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();

    const missingPath = try std.fs.path.join(allocator, &.{ try tempDirPath(allocator, tmpDir), "missing" });
    try std.testing.expect(key_utils.loadPrivateKey(allocator, std.testing.io, missingPath) == null);
    try std.testing.expect(key_utils.loadPublicKey(allocator, std.testing.io, missingPath) == null);
}

test "loadPrivateKey returns null for a file that is not a key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var mockLog: mock_log.MockLog = .{};
    mockLog.install();
    defer mockLog.uninstall();
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();

    const keyFilePath = try std.fs.path.join(allocator, &.{ try tempDirPath(allocator, tmpDir), "bad" });
    try tmpDir.dir.writeFile(std.testing.io, .{
        .sub_path = "bad",
        .data = "not a key",
    });
    try std.testing.expect(key_utils.loadPrivateKey(allocator, std.testing.io, keyFilePath) == null);
    try std.testing.expectEqual(@as(u32, 1), mockLog.exceptionCalls);
}

test "loadOrGenerateKeyPair loads a saved pair and does not generate when disabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();

    const keyFilePath = try std.fs.path.join(allocator, &.{ try tempDirPath(allocator, tmpDir), "key" });
    try std.testing.expect((try key_utils.loadOrGenerateKeyPair(allocator, std.testing.io, keyFilePath, false)) == null);

    const keyPair = try fixtureKeyPair(allocator);
    try key_utils.saveKeyPair(allocator, std.testing.io, keyPair, keyFilePath);
    const loaded = (try key_utils.loadOrGenerateKeyPair(allocator, std.testing.io, keyFilePath, false)).?;
    const savedHash = try key_utils.hashPublicKey(allocator, keyPair.publicKey);
    const loadedHash = try key_utils.hashPublicKey(allocator, loaded.publicKey);
    try std.testing.expectEqualSlices(u8, &savedHash, &loadedHash);
}

test "loadOrGenerateKeyPair generates and saves a pair when none exists and generation is enabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();

    const keyFilePath = try std.fs.path.join(allocator, &.{ try tempDirPath(allocator, tmpDir), "key" });
    const generated = (try key_utils.loadOrGenerateKeyPair(allocator, std.testing.io, keyFilePath, true)).?;
    try std.testing.expectEqual(@as(usize, 512), generated.publicKey.modulusLength());

    const reloaded = (try key_utils.loadOrGenerateKeyPair(allocator, std.testing.io, keyFilePath, false)).?;
    const generatedHash = try key_utils.hashPublicKey(allocator, generated.publicKey);
    const reloadedHash = try key_utils.hashPublicKey(allocator, reloaded.publicKey);
    try std.testing.expectEqualSlices(u8, &generatedHash, &reloadedHash);
}
