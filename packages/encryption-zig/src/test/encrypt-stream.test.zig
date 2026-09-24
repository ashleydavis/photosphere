const std = @import("std");
const utils = @import("utils-zig");
const encryption = @import("encryption-zig");
const helpers = @import("test-helpers.zig");

const crypto = encryption.node_crypto;
const key_utils = encryption.key_utils;
const encrypt_buffer = encryption.encrypt_buffer;
const encrypt_stream = encryption.encrypt_stream;
const constants = encryption.encryption_constants;
const IPrivateKeyMap = encryption.encryption_types.IPrivateKeyMap;

//
// The key pair and key map used by the tests (the TypeScript fixture key; see encrypt-buffer.test.zig).
//
const TestKeys = struct {
    // The public key.
    publicKey: *const crypto.PublicKey,

    // The private key.
    privateKey: *const crypto.PrivateKey,

    // { default: privateKey, [hash]: privateKey }.
    keyMap: IPrivateKeyMap,
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
    return TestKeys{ .publicKey = publicKey, .privateKey = privateKey, .keyMap = keyMap };
}

//
// Encrypts data through an encryption stream (TypeScript: Readable.from(plain).pipe(enc) then streamToBuffer).
//
fn encryptThroughStream(allocator: std.mem.Allocator, publicKey: *const crypto.PublicKey, plain: []const u8) ![]u8 {
    const input = try allocator.create(std.Io.Reader);
    input.* = std.Io.Reader.fixed(plain);
    const encryptionStream = try encrypt_stream.createEncryptionStream(allocator, std.testing.io, publicKey, input);
    return helpers.readAll(allocator, encryptionStream.reader());
}

//
// Decrypts data through a decryption stream.
//
fn decryptThroughStream(allocator: std.mem.Allocator, keyMap: *const IPrivateKeyMap, encrypted: []const u8) ![]u8 {
    const input = try allocator.create(std.Io.Reader);
    input.* = std.Io.Reader.fixed(encrypted);
    const decryptionStream = try encrypt_stream.createDecryptionStream(allocator, keyMap, input);
    return helpers.readAll(allocator, decryptionStream.reader());
}

//
// Feeds data to a decryption stream's transform in chunks of the given size, then flushes, and returns the output
// (exercises the header handling when chunks split the header).
//
fn decryptInChunks(allocator: std.mem.Allocator, keyMap: *const IPrivateKeyMap, encrypted: []const u8, chunkSize: usize) ![]u8 {
    const decryptionStream = try encrypt_stream.createDecryptionStream(allocator, keyMap, std.Io.Reader.ending);
    const transform = &decryptionStream.transform;
    var offset: usize = 0;
    while (offset < encrypted.len) {
        const end = @min(offset + chunkSize, encrypted.len);
        try transform.transform_function(transform, encrypted[offset..end]);
        offset = end;
    }
    try transform.flush_function(transform);
    return allocator.dupe(u8, transform.pending.items);
}

test "returns correct length for empty input" {
    try std.testing.expectEqual(@as(u64, 588), encrypt_stream.computeEncryptedLength(0));
}

test "returns correct length for non-block-aligned input" {
    try std.testing.expectEqual(@as(u64, 588), encrypt_stream.computeEncryptedLength(1));
    try std.testing.expectEqual(@as(u64, 588), encrypt_stream.computeEncryptedLength(15));
    try std.testing.expectEqual(@as(u64, 604), encrypt_stream.computeEncryptedLength(17));
}

test "returns correct length for block-aligned input" {
    try std.testing.expectEqual(@as(u64, 604), encrypt_stream.computeEncryptedLength(16));
    try std.testing.expectEqual(@as(u64, 620), encrypt_stream.computeEncryptedLength(32));
}

test "matches actual encrypted stream output length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const lengths = [_]usize{ 0, 1, 15, 16, 17, 32, 100 };
    for (lengths) |plainLength| {
        const plain = try allocator.alloc(u8, plainLength);
        @memset(plain, 0x42);
        const encrypted = try encryptThroughStream(allocator, keys.publicKey, plain);
        try std.testing.expectEqual(encrypt_stream.computeEncryptedLength(plainLength), encrypted.len);
    }
}

test "encrypts and decrypts stream with key map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const plain = "hello stream world";
    const encrypted = try encryptThroughStream(allocator, keys.publicKey, plain);
    const out = try decryptThroughStream(allocator, &keys.keyMap, encrypted);
    try std.testing.expectEqualStrings(plain, out);
}

test "stream output starts with new-format header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const encrypted = try encryptThroughStream(allocator, keys.publicKey, "x");
    try std.testing.expect(encrypted.len >= 4);
    try std.testing.expectEqualStrings(constants.ENCRYPTION_TAG, encrypted[0..4]);
}

test "decrypts legacy payload using default key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const plain = "legacy stream payload";
    const fullEncrypted = try encrypt_buffer.encryptBuffer(allocator, std.testing.io, keys.publicKey, plain);
    const legacyPayload = fullEncrypted[44..];
    const out = try decryptThroughStream(allocator, &keys.keyMap, legacyPayload);
    try std.testing.expectEqualStrings(plain, out);
}

test "decrypts new-format stream using hash key in map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const plain = "new format stream";
    const encrypted = try encryptThroughStream(allocator, keys.publicKey, plain);
    const out = try decryptThroughStream(allocator, &keys.keyMap, encrypted);
    try std.testing.expectEqualStrings(plain, out);
}

test "decrypts buffer-encrypted new format with stream" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const plain = "buffer then stream";
    const encrypted = try encrypt_buffer.encryptBuffer(allocator, std.testing.io, keys.publicKey, plain);
    const out = try decryptThroughStream(allocator, &keys.keyMap, encrypted);
    try std.testing.expectEqualStrings(plain, out);
}

test "passes plain data through when key map has no default key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const plain = "plain file content";
    const emptyMap: IPrivateKeyMap = .empty;
    const out = try decryptThroughStream(allocator, &emptyMap, plain);
    try std.testing.expectEqualStrings(plain, out);
}

test "passes data through when new-format header present but no matching key in map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const encrypted = try encrypt_buffer.encryptBuffer(allocator, std.testing.io, keys.publicKey, "secret");
    const emptyMap: IPrivateKeyMap = .empty;
    const out = try decryptThroughStream(allocator, &emptyMap, encrypted);
    try std.testing.expectEqualSlices(u8, encrypted, out);
}

test "passes plain data through when default key present but data is not encrypted (legacy decrypt throws)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const plain = "plain file content that is not encrypted";
    const out = try decryptThroughStream(allocator, &keys.keyMap, plain);
    try std.testing.expectEqualStrings(plain, out);

    //
    // Also for plain data longer than the legacy header.
    //
    const longPlain = try helpers.makePlaintext(allocator, 5000);
    try std.testing.expectEqualSlices(u8, longPlain, try decryptThroughStream(allocator, &keys.keyMap, longPlain));
}

test "decrypts correctly for every chunk size that splits the header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const plain = try helpers.makePlaintext(allocator, 100);
    const encrypted = try encrypt_buffer.encryptBuffer(allocator, std.testing.io, keys.publicKey, plain);
    const legacyPayload = encrypted[44..];
    const emptyMap: IPrivateKeyMap = .empty;
    const chunkSizes = [_]usize{ 1, 3, 4, 5, 43, 44, 45, 527, 528, 529, 571, 572, 573, 1000 };
    for (chunkSizes) |chunkSize| {
        try std.testing.expectEqualSlices(u8, plain, try decryptInChunks(allocator, &keys.keyMap, encrypted, chunkSize));
        try std.testing.expectEqualSlices(u8, plain, try decryptInChunks(allocator, &keys.keyMap, legacyPayload, chunkSize));
        try std.testing.expectEqualSlices(u8, encrypted, try decryptInChunks(allocator, &emptyMap, encrypted, chunkSize));
        try std.testing.expectEqualSlices(u8, plain, try decryptInChunks(allocator, &emptyMap, plain, chunkSize));
    }
}

test "short plain data is flushed unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    try std.testing.expectEqualStrings("ab", try decryptThroughStream(allocator, &keys.keyMap, "ab"));
    try std.testing.expectEqualStrings("", try decryptThroughStream(allocator, &keys.keyMap, ""));
}

test "reading the decrypted stream in small pieces returns all data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const plain = try helpers.makePlaintext(allocator, 200_000);
    const encrypted = try encryptThroughStream(allocator, keys.publicKey, plain);
    var input = std.Io.Reader.fixed(encrypted);
    const decryptionStream = try encrypt_stream.createDecryptionStream(allocator, &keys.keyMap, &input);
    var output: std.ArrayList(u8) = .empty;
    var piece: [777]u8 = undefined;
    while (true) {
        const count = try decryptionStream.reader().readSliceShort(&piece);
        try output.appendSlice(allocator, piece[0..count]);
        if (count < piece.len) {
            break;
        }
    }
    try std.testing.expectEqualSlices(u8, plain, output.items);
}

test "a wrong key makes the decryption stream fail with the Node error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadTestKeys(allocator);
    const otherKey = try crypto.createPrivateKey(allocator, try helpers.readFixture(allocator, "ts2-private.pem"));
    const encrypted = try encrypt_buffer.encryptBuffer(allocator, std.testing.io, keys.publicKey, "secret");

    //
    // A key registered under the header's hash that cannot decrypt it.
    //
    const keyHashHex = std.fmt.bytesToHex(encrypted[12..44].*, .lower);
    var wrongMap: IPrivateKeyMap = .empty;
    try wrongMap.put(allocator, &keyHashHex, otherKey);
    var input = std.Io.Reader.fixed(encrypted);
    const decryptionStream = try encrypt_stream.createDecryptionStream(allocator, &wrongMap, &input);
    try std.testing.expectError(error.ReadFailed, helpers.readAll(allocator, decryptionStream.reader()));
    try std.testing.expectEqual(error.Thrown, decryptionStream.transform.err.?);

    //
    // Depending on the random key, OpenSSL reports an OAEP error or a value larger than the modulus.
    //
    const message = utils.errors.lastErrorMessage();
    const isOaepError = std.mem.eql(u8, message, "error:02000079:rsa routines::oaep decoding error");
    const isModulusError = std.mem.eql(u8, message, "error:02000084:rsa routines::data too large for modulus");
    try std.testing.expect(isOaepError or isModulusError);
}
