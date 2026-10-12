const std = @import("std");
const encryption = @import("encryption-zig");
const utils = @import("utils-zig");
const fixtures = @import("fixtures.zig");

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
    var stdout: std.Io.Writer.Allocating = .init(allocator);
    var stderr: std.Io.Writer.Allocating = .init(allocator);
    utils.console.setCapture(&stdout.writer, &stderr.writer);
    defer utils.console.setCapture(null, null);
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();

    const keyFilePath = try std.fs.path.join(allocator, &.{ try tempDirPath(allocator, tmpDir), "bad" });
    try tmpDir.dir.writeFile(std.testing.io, .{
        .sub_path = "bad",
        .data = "not a key",
    });
    try std.testing.expect(key_utils.loadPrivateKey(allocator, std.testing.io, keyFilePath) == null);
    const expected = try std.mem.concat(allocator, u8, &.{ "Error loading private key from ", keyFilePath, ": Error: error:1E08010C:DECODER routines::unsupported\n" });
    try std.testing.expectEqualStrings(expected, stderr.written());
    try std.testing.expectEqualStrings("", stdout.written());
}

test "loadPublicKey returns null for a file that is not a key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var stdout: std.Io.Writer.Allocating = .init(allocator);
    var stderr: std.Io.Writer.Allocating = .init(allocator);
    utils.console.setCapture(&stdout.writer, &stderr.writer);
    defer utils.console.setCapture(null, null);
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();

    const keyFilePath = try std.fs.path.join(allocator, &.{ try tempDirPath(allocator, tmpDir), "bad.pub" });
    try tmpDir.dir.writeFile(std.testing.io, .{
        .sub_path = "bad.pub",
        .data = "not a key",
    });
    try std.testing.expect(key_utils.loadPublicKey(allocator, std.testing.io, keyFilePath) == null);
    try std.testing.expect(std.mem.startsWith(u8, stderr.written(), try std.mem.concat(allocator, u8, &.{ "Error loading public key from ", keyFilePath, ": Error: " })));
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

test "loadEncryptionKeys returns empty options when no key paths are provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = try key_utils.loadEncryptionKeys(allocator, std.testing.io, &.{}, false);
    try std.testing.expect(!result.isEncrypted);
    try std.testing.expect(result.options.decryptionKeyMap == null);
    try std.testing.expect(result.options.encryptionPublicKey == null);
}

test "loadEncryptionKeys builds decryptionKeyMap and encryptionPublicKey for a single key path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();

    const keyPath = try std.fs.path.join(allocator, &.{ try tempDirPath(allocator, tmpDir), "test-single-key-loadEncryptionKeys.key" });
    const result = try key_utils.loadEncryptionKeys(allocator, std.testing.io, &.{keyPath}, true);

    try std.testing.expect(result.isEncrypted);
    const map = result.options.decryptionKeyMap.?;
    const writeKey = result.options.encryptionPublicKey.?;
    const defaultKey = map.get("default").?;
    const hashHex = std.fmt.bytesToHex(try key_utils.hashPublicKey(allocator, writeKey), .lower);
    const entryKey = map.get(&hashHex).?;
    try std.testing.expect(entryKey == defaultKey);

    // The keys are usable: the AES key wrapped with the write key comes back with the default key.
    const encrypted = try crypto.publicEncrypt(allocator, std.testing.io, writeKey, "hello");
    try std.testing.expectEqualStrings("hello", try crypto.privateDecrypt(allocator, defaultKey, encrypted));
}

test "loadEncryptionKeys registers multiple keys and uses the first as default/write key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();

    const directory = try tempDirPath(allocator, tmpDir);
    const keyPath1 = try std.fs.path.join(allocator, &.{ directory, "test-multi-key-loadEncryptionKeys-1.key" });
    const keyPath2 = try std.fs.path.join(allocator, &.{ directory, "test-multi-key-loadEncryptionKeys-2.key" });

    const result = try key_utils.loadEncryptionKeys(allocator, std.testing.io, &.{ keyPath1, keyPath2 }, true);

    try std.testing.expect(result.isEncrypted);
    const map = result.options.decryptionKeyMap.?;
    const writeKey = result.options.encryptionPublicKey.?;
    try std.testing.expectEqual(@as(usize, 3), map.count());

    // The first key is the default and matches the encryptionPublicKey hash entry.
    const defaultPrivate = map.get("default").?;
    const writeHashHex = std.fmt.bytesToHex(try key_utils.hashPublicKey(allocator, writeKey), .lower);
    try std.testing.expect(map.get(&writeHashHex).? == defaultPrivate);
    const firstPair = (try key_utils.loadOrGenerateKeyPair(allocator, std.testing.io, keyPath1, false)).?;
    const firstHashHex = std.fmt.bytesToHex(try key_utils.hashPublicKey(allocator, firstPair.publicKey), .lower);
    try std.testing.expectEqualStrings(&firstHashHex, &writeHashHex);
}

test "loadEncryptionKeys derives a public key from a private key when .pub is missing (generateKey=false)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();

    const keyPem = try loadFixturePem(allocator, "ts");
    try tmpDir.dir.writeFile(std.testing.io, .{
        .sub_path = "test-private-only-loadEncryptionKeys.key",
        .data = keyPem.privateKeyPem,
    });
    const keyPath = try std.fs.path.join(allocator, &.{ try tempDirPath(allocator, tmpDir), "test-private-only-loadEncryptionKeys.key" });

    const result = try key_utils.loadEncryptionKeys(allocator, std.testing.io, &.{keyPath}, false);

    try std.testing.expect(result.isEncrypted);
    const map = result.options.decryptionKeyMap.?;
    const writeKey = result.options.encryptionPublicKey.?;
    const defaultKey = map.get("default").?;
    const writeHashHex = std.fmt.bytesToHex(try key_utils.hashPublicKey(allocator, writeKey), .lower);
    const entryKey = map.get(&writeHashHex).?;
    try std.testing.expect(entryKey == defaultKey);
    try std.testing.expectEqualStrings(try fixtures.readFixture(allocator, "ts-public-hash.hex"), &writeHashHex);
}

test "loadEncryptionKeys throws a fatal error naming the key when the private key is missing (generateKey=false)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();

    const keyPath = try std.fs.path.join(allocator, &.{ try tempDirPath(allocator, tmpDir), "missing.key" });
    try std.testing.expectError(error.FatalError, key_utils.loadEncryptionKeys(allocator, std.testing.io, &.{keyPath}, false));
    const expected = try std.mem.concat(allocator, u8, &.{ "Private key not found: ", keyPath, "\nUse --generate-key to create a new key or specify an existing key file either in the current directory or in the ~/.config/photosphere/keys directory." });
    try std.testing.expectEqualStrings(expected, utils.errors.lastErrorMessage());
}
