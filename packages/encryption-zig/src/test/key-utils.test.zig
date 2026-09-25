const std = @import("std");
const encryption = @import("encryption-zig");
const utils = @import("utils-zig");
const helpers = @import("test-helpers.zig");

const key_utils = encryption.key_utils;
const crypto = encryption.node_crypto;

//
// Loads a fixture PEM pair written by fixtures/generate.ts ("ts" or "ts2").
//
fn loadFixturePem(allocator: std.mem.Allocator, prefix: []const u8) !key_utils.IEncryptionKeyPem {
    return key_utils.IEncryptionKeyPem{
        .privateKeyPem = try helpers.readFixture(allocator, try std.fmt.allocPrint(allocator, "{s}-private.pem", .{prefix})),
        .publicKeyPem = try helpers.readFixture(allocator, try std.fmt.allocPrint(allocator, "{s}-public.pem", .{prefix})),
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
    try std.testing.expectEqualSlices(u8, keyPair.privateKey.public_key.components.modulus, keyPair.publicKey.components.modulus);
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

test "hashPublicKey equals the TypeScript hash for the same key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const prefixes = [_][]const u8{ "ts", "ts2" };
    for (prefixes) |prefix| {
        const keyPem = try loadFixturePem(allocator, prefix);
        const expectedHex = try helpers.readFixture(allocator, try std.fmt.allocPrint(allocator, "{s}-public-hash.hex", .{prefix}));
        const fromPublic = try key_utils.hashPublicKey(allocator, try crypto.createPublicKey(allocator, keyPem.publicKeyPem));
        try std.testing.expectEqualStrings(expectedHex, &std.fmt.bytesToHex(fromPublic, .lower));
        const privateKey = try crypto.createPrivateKey(allocator, keyPem.privateKeyPem);
        const fromPrivate = try key_utils.hashPublicKey(allocator, crypto.createPublicKeyFromPrivateKey(privateKey));
        try std.testing.expectEqualStrings(expectedHex, &std.fmt.bytesToHex(fromPrivate, .lower));
    }
}

test "exportPublicKeyToPem reproduces the TypeScript PEM" {
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
    const hash1 = try helpers.readFixture(allocator, "ts-public-hash.hex");
    const hash2 = try helpers.readFixture(allocator, "ts2-public-hash.hex");
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

    // (Zig: the TypeScript fixture key pair stands in for generateKeyPair, which is slow in Debug builds.)
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
