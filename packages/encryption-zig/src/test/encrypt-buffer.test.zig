const std = @import("std");
const utils = @import("utils-zig");
const encryption = @import("encryption-zig");
const helpers = @import("test-helpers.zig");

const crypto = encryption.node_crypto;
const key_utils = encryption.key_utils;
const encrypt_buffer = encryption.encrypt_buffer;
const constants = encryption.encryption_constants;
const IPrivateKeyMap = encryption.encryption_types.IPrivateKeyMap;

//
// The key pair and key map used by the tests (the TypeScript tests generate a key pair; the Zig tests use the
// TypeScript fixture key because RSA-4096 generation is slow in Debug builds).
//
const TestKeys = struct {
    // The public key.
    publicKey: *const crypto.PublicKey,

    // The private key.
    privateKey: *const crypto.PrivateKey,

    // { default: privateKey, [hash]: privateKey }.
    keyMap: IPrivateKeyMap,

    // The hex hash of the public key.
    keyHashHex: []const u8,
};

//
// Loads the fixture key pair and builds the key map.
//
fn loadTestKeys(allocator: std.mem.Allocator) !TestKeys {
    const privateKey = try crypto.createPrivateKey(allocator, try helpers.readFixture(allocator, "ts-private.pem"));
    const publicKey = try crypto.createPublicKey(allocator, try helpers.readFixture(allocator, "ts-public.pem"));
    const keyHashHex = try allocator.dupe(u8, &std.fmt.bytesToHex(try key_utils.hashPublicKey(allocator, publicKey), .lower));
    var keyMap: IPrivateKeyMap = .empty;
    try keyMap.put(allocator, "default", privateKey);
    try keyMap.put(allocator, keyHashHex, privateKey);
    return TestKeys{ .publicKey = publicKey, .privateKey = privateKey, .keyMap = keyMap, .keyHashHex = keyHashHex };
}

test "encrypts and decrypts with key map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const plain = "hello world";
    const encrypted = try encrypt_buffer.encryptBuffer(allocator, std.testing.io, keys.publicKey, plain);
    try std.testing.expectEqualStrings(constants.ENCRYPTION_TAG, encrypted[0..4]);
    const decrypted = try encrypt_buffer.decryptBuffer(allocator, encrypted, &keys.keyMap);
    try std.testing.expectEqualStrings(plain, decrypted);
}

test "encryptBuffer writes the new-format header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const encrypted = try encrypt_buffer.encryptBuffer(allocator, std.testing.io, keys.publicKey, "0123456789abcdef");
    try std.testing.expectEqual(@as(usize, 44 + 512 + 16 + 32), encrypted.len);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, encrypted[4..8], .little));
    try std.testing.expectEqualStrings("A2CB", encrypted[8..12]);
    try std.testing.expectEqualStrings(keys.keyHashHex, &std.fmt.bytesToHex(encrypted[12..44].*, .lower));
}

test "decrypts legacy payload using default key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const plain = "legacy payload";
    const encrypted = try encrypt_buffer.encryptBuffer(allocator, std.testing.io, keys.publicKey, plain);
    const legacyPayload = encrypted[44..];
    const decrypted = try encrypt_buffer.decryptBuffer(allocator, legacyPayload, &keys.keyMap);
    try std.testing.expectEqualStrings(plain, decrypted);
}

test "decrypts new-format payload using hash key in map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const plain = "new format";
    const encrypted = try encrypt_buffer.encryptBuffer(allocator, std.testing.io, keys.publicKey, plain);
    var hashOnlyMap: IPrivateKeyMap = .empty;
    try hashOnlyMap.put(allocator, keys.keyHashHex, keys.privateKey);
    const decrypted = try encrypt_buffer.decryptBuffer(allocator, encrypted, &hashOnlyMap);
    try std.testing.expectEqualStrings(plain, decrypted);
}

test "is refused at the write rather than producing a file nothing can decrypt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 2048-bit RSA wraps the AES key into 256 bytes, and every reader slices it out of the file
    // at a fixed 512, which is an RSA-4096 block. So a file written with a smaller key can never
    // be decrypted by this codebase.
    const smallPublicKey = try crypto.createPublicKey(allocator, try helpers.readFixture(allocator, "ts-small-public.pem"));

    // The write is where this has to fail. Encrypting with such a key used to succeed and say
    // nothing, and making the read loud does not get the data back: by the time the read
    // fails the only copy of the plaintext is the unreadable file.
    try std.testing.expectError(error.Thrown, encrypt_buffer.encryptBuffer(allocator, std.testing.io, smallPublicKey, "secret"));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "wraps into 256 bytes and the file format requires 512") != null);
}

test "throws when the data says it is encrypted and the key is not in the map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);

    // It used to hand the ciphertext back, on the reading that a failed decryption means the
    // data was never encrypted. For data carrying the encryption tag that reading is wrong,
    // and it turns a missing key into a wrong answer somewhere else entirely: the caller
    // deserializes the ciphertext and reports whatever it happens to look like. A database
    // file read this way reports "Checksum mismatch", which names serialization and says
    // nothing about the key.
    const encrypted = try encrypt_buffer.encryptBuffer(allocator, std.testing.io, keys.publicKey, "secret");
    const emptyMap: IPrivateKeyMap = .empty;
    try std.testing.expectError(error.Thrown, encrypt_buffer.decryptBuffer(allocator, encrypted, &emptyMap));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "says it is encrypted") != null);

    // (Zig: the message and the cause are those of `new Error(message, { cause: err })`.)
    const expected = try std.fmt.allocPrint(allocator, "Could not decrypt data that says it is encrypted: No private key in map for key hash {s}", .{keys.keyHashHex});
    try std.testing.expectEqualStrings(expected, utils.errors.lastErrorMessage());
    const expectedCause = try std.fmt.allocPrint(allocator, "No private key in map for key hash {s}", .{keys.keyHashHex});
    try std.testing.expectEqualStrings(expectedCause, utils.errors.lastErrorCauseMessage());
}

test "throws when the data says it is encrypted and the wrong key is in the map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);

    // (Zig: the second TypeScript fixture key pair stands in for generateKeyPair.)
    const otherPrivateKey = try crypto.createPrivateKey(allocator, try helpers.readFixture(allocator, "ts2-private.pem"));
    const otherKeyHashHex = try helpers.readFixture(allocator, "ts2-public-hash.hex");
    const encrypted = try encrypt_buffer.encryptBuffer(allocator, std.testing.io, keys.publicKey, "secret");
    var wrongMap: IPrivateKeyMap = .empty;
    try wrongMap.put(allocator, "default", otherPrivateKey);
    try wrongMap.put(allocator, otherKeyHashHex, otherPrivateKey);
    try std.testing.expectError(error.Thrown, encrypt_buffer.decryptBuffer(allocator, encrypted, &wrongMap));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "says it is encrypted") != null);
}

test "still hands back a plaintext buffer unchanged, which is how an unencrypted file reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);

    // The case the fallback exists for, and the reason it cannot simply be removed: a
    // database can hold files that were never encrypted, read through the same storage.
    const plain = "this was never encrypted, and is long enough to look like a file";
    const result = try encrypt_buffer.decryptBuffer(allocator, plain, &keys.keyMap);
    try std.testing.expectEqualSlices(u8, plain, result);
}

test "returns data unchanged when legacy data and no default key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const encrypted = try encrypt_buffer.encryptBuffer(allocator, std.testing.io, keys.publicKey, "x");
    const legacyPayload = encrypted[44..];
    var noDefaultMap: IPrivateKeyMap = .empty;
    try noDefaultMap.put(allocator, keys.keyHashHex, keys.privateKey);
    const result = try encrypt_buffer.decryptBuffer(allocator, legacyPayload, &noDefaultMap);
    try std.testing.expectEqualSlices(u8, legacyPayload, result);
}

test "returns data unchanged when shorter than 4 bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const short = [_]u8{ 0, 0 };
    const result = try encrypt_buffer.decryptBuffer(allocator, &short, &keys.keyMap);
    try std.testing.expectEqualSlices(u8, &short, result);
}

test "returns plain data unchanged when the default key cannot decrypt it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const plain = try helpers.makePlaintext(allocator, 1000);
    const result = try encrypt_buffer.decryptBuffer(allocator, plain, &keys.keyMap);
    try std.testing.expectEqualSlices(u8, plain, result);
}

test "throws when data too short for header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    var short = [_]u8{0} ** (constants.NEW_FORMAT_HEADER_LENGTH - 1);
    @memcpy(short[0..4], constants.ENCRYPTION_TAG);
    try std.testing.expectError(error.Thrown, encrypt_buffer.decryptNewFormat(allocator, &short, &keys.keyMap));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "too short for header") != null);
}

test "throws when data does not start with encryption tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    var buffer = [_]u8{0} ** constants.NEW_FORMAT_HEADER_LENGTH;
    @memcpy(buffer[0..4], "XXXX");
    try std.testing.expectError(error.Thrown, encrypt_buffer.decryptNewFormat(allocator, &buffer, &keys.keyMap));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "does not start with encryption tag") != null);
}

test "throws when key not in map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const encrypted = try encrypt_buffer.encryptBuffer(allocator, std.testing.io, keys.publicKey, "secret");
    const emptyMap: IPrivateKeyMap = .empty;
    try std.testing.expectError(error.Thrown, encrypt_buffer.decryptNewFormat(allocator, encrypted, &emptyMap));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "No private key in map") != null);
}

test "throws for an unsupported version or type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const encrypted = try encrypt_buffer.encryptBuffer(allocator, std.testing.io, keys.publicKey, "secret");
    encrypted[4] = 2;
    try std.testing.expectError(error.Thrown, encrypt_buffer.decryptNewFormat(allocator, encrypted, &keys.keyMap));
    try std.testing.expectEqualStrings("Unsupported encryption format version=2 type=A2CB", utils.errors.lastErrorMessage());
}

test "decrypts valid new-format buffer when key in map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const plain = "new format payload";
    const encrypted = try encrypt_buffer.encryptBuffer(allocator, std.testing.io, keys.publicKey, plain);
    const decrypted = try encrypt_buffer.decryptNewFormat(allocator, encrypted, &keys.keyMap);
    try std.testing.expectEqualStrings(plain, decrypted);
}

test "throws when data too short for legacy header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const short = [_]u8{0} ** (constants.LEGACY_HEADER_LENGTH - 1);
    try std.testing.expectError(error.Thrown, encrypt_buffer.decryptLegacy(allocator, &short, keys.privateKey));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "too short") != null);
}

test "decrypts valid legacy payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const plain = "legacy content";
    const encrypted = try encrypt_buffer.encryptBuffer(allocator, std.testing.io, keys.publicKey, plain);
    const legacyPayload = encrypted[44..];
    const decrypted = try encrypt_buffer.decryptLegacy(allocator, legacyPayload, keys.privateKey);
    try std.testing.expectEqualStrings(plain, decrypted);
}

test "normalizeEncryptionType removes NUL characters and whitespace" {
    var buffer: [4]u8 = undefined;
    try std.testing.expectEqualStrings("A2", encrypt_buffer.normalizeEncryptionType(&buffer, &.{ 'A', 0, '2', ' ' }));
    try std.testing.expectEqualStrings("A2CB", encrypt_buffer.normalizeEncryptionType(&buffer, "A2CB"));
}

test "includesString finds a string in an array like Array.includes" {
    try std.testing.expect(encrypt_buffer.includesString(&.{ "A2CB", "XYZW" }, "A2CB"));
    try std.testing.expect(!encrypt_buffer.includesString(&.{"A2CB"}, "A2C"));
}
