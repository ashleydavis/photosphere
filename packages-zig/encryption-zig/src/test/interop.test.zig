const std = @import("std");
const encryption = @import("encryption-zig");
const helpers = @import("test-helpers.zig");

//
// Golden interop tests between the TypeScript encryption package and this port, in both directions.
// The TypeScript side of the fixtures is written by fixtures/generate.ts; the Zig output is checked against the
// header, lengths and PEM layout of those committed fixtures and decrypted back with the fixture keys.
//

const crypto = encryption.node_crypto;
const key_utils = encryption.key_utils;
const encrypt_buffer = encryption.encrypt_buffer;
const encrypt_stream = encryption.encrypt_stream;
const IPrivateKeyMap = encryption.encryption_types.IPrivateKeyMap;

//
// The plaintext sizes covered by the fixtures.
//
const sizes = [_]usize{ 0, 1, 15, 16, 17, 1048576 };

//
// The size whose plaintext and legacy ciphertext are not stored in the fixtures.
//
const large_size = 1048576;

//
// Builds a key map with "default" and the hash of the key.
//
fn buildKeyMap(allocator: std.mem.Allocator, privateKey: *const crypto.PrivateKey) !IPrivateKeyMap {
    const publicKey = crypto.createPublicKeyFromPrivateKey(privateKey);
    const keyHashHex = try allocator.dupe(u8, &std.fmt.bytesToHex(try key_utils.hashPublicKey(allocator, publicKey), .lower));
    var keyMap: IPrivateKeyMap = .empty;
    try keyMap.put(allocator, "default", privateKey);
    try keyMap.put(allocator, keyHashHex, privateKey);
    return keyMap;
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
// Encrypts data through an encryption stream.
//
fn encryptThroughStream(allocator: std.mem.Allocator, publicKey: *const crypto.PublicKey, plain: []const u8) ![]u8 {
    const input = try allocator.create(std.Io.Reader);
    input.* = std.Io.Reader.fixed(plain);
    const encryptionStream = try encrypt_stream.createEncryptionStream(allocator, std.testing.io, publicKey, input);
    return helpers.readAll(allocator, encryptionStream.reader());
}

test "Zig decrypts every TypeScript fixture (new format, legacy format and stream output)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const privateKey = try crypto.createPrivateKey(allocator, try helpers.readFixture(allocator, "ts-private.pem"));
    const keyMap = try buildKeyMap(allocator, privateKey);
    var hashOnlyMap = try keyMap.clone(allocator);
    _ = hashOnlyMap.swapRemove("default");

    for (sizes) |size| {
        const plain = try helpers.makePlaintext(allocator, size);
        const newFormat = try helpers.readFixture(allocator, try std.fmt.allocPrint(allocator, "new-{d}.bin", .{size}));
        try std.testing.expectEqualSlices(u8, plain, try encrypt_buffer.decryptBuffer(allocator, newFormat, &keyMap));
        try std.testing.expectEqualSlices(u8, plain, try encrypt_buffer.decryptNewFormat(allocator, newFormat, &hashOnlyMap));
        try std.testing.expectEqualSlices(u8, plain, try decryptThroughStream(allocator, &keyMap, newFormat));

        var legacy: []const u8 = newFormat[44..];
        if (size != large_size) {
            const storedPlain = try helpers.readFixture(allocator, try std.fmt.allocPrint(allocator, "plain-{d}.bin", .{size}));
            try std.testing.expectEqualSlices(u8, plain, storedPlain);
            legacy = try helpers.readFixture(allocator, try std.fmt.allocPrint(allocator, "legacy-{d}.bin", .{size}));

            const streamed = try helpers.readFixture(allocator, try std.fmt.allocPrint(allocator, "stream-{d}.bin", .{size}));
            try std.testing.expectEqual(encrypt_stream.computeEncryptedLength(size), streamed.len);
            try std.testing.expectEqualSlices(u8, plain, try encrypt_buffer.decryptBuffer(allocator, streamed, &keyMap));
            try std.testing.expectEqualSlices(u8, plain, try decryptThroughStream(allocator, &keyMap, streamed));
        }
        try std.testing.expectEqualSlices(u8, plain, try encrypt_buffer.decryptBuffer(allocator, legacy, &keyMap));
        try std.testing.expectEqualSlices(u8, plain, try encrypt_buffer.decryptLegacy(allocator, legacy, privateKey));
        try std.testing.expectEqualSlices(u8, plain, try decryptThroughStream(allocator, &keyMap, legacy));
    }
}

test "Zig encrypts and decrypts its own output for every size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const privateKey = try crypto.createPrivateKey(allocator, try helpers.readFixture(allocator, "ts-private.pem"));
    const publicKey = try crypto.createPublicKey(allocator, try helpers.readFixture(allocator, "ts-public.pem"));
    const keyMap = try buildKeyMap(allocator, privateKey);
    for (sizes) |size| {
        const plain = try helpers.makePlaintext(allocator, size);
        const encrypted = try encrypt_buffer.encryptBuffer(allocator, std.testing.io, publicKey, plain);
        try std.testing.expectEqual(encrypt_stream.computeEncryptedLength(size), encrypted.len);
        try std.testing.expectEqualSlices(u8, plain, try encrypt_buffer.decryptBuffer(allocator, encrypted, &keyMap));
        try std.testing.expectEqualSlices(u8, plain, try decryptThroughStream(allocator, &keyMap, encrypted));

        const streamed = try encryptThroughStream(allocator, publicKey, plain);
        try std.testing.expectEqual(encrypt_stream.computeEncryptedLength(size), streamed.len);
        try std.testing.expectEqualSlices(u8, plain, try encrypt_buffer.decryptBuffer(allocator, streamed, &keyMap));
        try std.testing.expectEqualSlices(u8, plain, try decryptThroughStream(allocator, &keyMap, streamed));
    }
}

//
// The 44-byte new-format header TypeScript wrote at the start of every new-<size>.bin and stream-<size>.bin fixture
// encrypted with ts-public.pem: "PSEN", version 1 (little endian), "A2CB" and the SHA-256 hash of the public key
// (ts-public-hash.hex).
//
const ts_key_header = "PSEN" ++ "\x01\x00\x00\x00" ++ "A2CB" ++
    "\x95\x12\x45\x25\x51\x10\x55\x81\x60\x76\x53\x9f\x2c\x22\x82\x12" ++
    "\x57\x39\x8d\x71\x17\x8a\x1f\x70\x96\x3e\x22\xd6\x96\x64\xbe\x2c";

//
// The length of the TypeScript fixture new-<size>.bin for each entry of `sizes` (the stream fixtures have the same
// lengths): the 44-byte header, the 512-byte wrapped key, the 16-byte IV and the PKCS#7 padded ciphertext.
//
const ts_encrypted_lengths = [_]usize{ 588, 588, 588, 604, 604, 1049164 };

test "Zig output with the TypeScript key has the header and length of the TypeScript fixtures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const privateKey = try crypto.createPrivateKey(allocator, try helpers.readFixture(allocator, "ts-private.pem"));
    const tsPublicKey = try crypto.createPublicKey(allocator, try helpers.readFixture(allocator, "ts-public.pem"));

    // TypeScript decrypts with a key map that holds only the key hash, so Zig output must carry that hash.
    var hashOnlyMap = try buildKeyMap(allocator, privateKey);
    _ = hashOnlyMap.swapRemove("default");

    for (sizes, ts_encrypted_lengths) |size, expectedLength| {
        const plain = try helpers.makePlaintext(allocator, size);
        const tsEncrypted = try helpers.readFixture(allocator, try std.fmt.allocPrint(allocator, "new-{d}.bin", .{size}));
        try std.testing.expectEqual(expectedLength, tsEncrypted.len);
        try std.testing.expectEqualSlices(u8, ts_key_header, tsEncrypted[0..ts_key_header.len]);

        const zigEncrypted = try encrypt_buffer.encryptBuffer(allocator, io, tsPublicKey, plain);
        try std.testing.expectEqual(expectedLength, zigEncrypted.len);
        try std.testing.expectEqualSlices(u8, ts_key_header, zigEncrypted[0..ts_key_header.len]);
        try std.testing.expectEqualSlices(u8, plain, try encrypt_buffer.decryptNewFormat(allocator, zigEncrypted, &hashOnlyMap));
        try std.testing.expectEqualSlices(u8, plain, try encrypt_buffer.decryptLegacy(allocator, zigEncrypted[ts_key_header.len..], privateKey));

        const zigStream = try encryptThroughStream(allocator, tsPublicKey, plain);
        try std.testing.expectEqual(expectedLength, zigStream.len);
        try std.testing.expectEqualSlices(u8, ts_key_header, zigStream[0..ts_key_header.len]);
        try std.testing.expectEqualSlices(u8, plain, try decryptThroughStream(allocator, &hashOnlyMap, zigStream));
        if (size != large_size) {
            const tsStream = try helpers.readFixture(allocator, try std.fmt.allocPrint(allocator, "stream-{d}.bin", .{size}));
            try std.testing.expectEqual(expectedLength, tsStream.len);
            try std.testing.expectEqualSlices(u8, ts_key_header, tsStream[0..ts_key_header.len]);
        }
    }
}

test "Zig-generated keys export as PEM with the layout of the TypeScript PEM files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    //
    // A key pair generated by Zig, exported like the CLI does.
    //
    const keyPair = try key_utils.generateKeyPair(allocator, io);
    const privateKeyPem = try crypto.exportPrivateKey(allocator, keyPair.privateKey, .pem);
    const publicKeyPem = try key_utils.exportPublicKeyToPem(allocator, keyPair.publicKey);
    try std.testing.expectEqual(@as(usize, 512), keyPair.publicKey.modulusLength());

    // The PEM files re-import and re-export unchanged, and the public key derived from the private key matches.
    const reloadedPrivateKey = try crypto.createPrivateKey(allocator, privateKeyPem);
    try std.testing.expectEqualStrings(privateKeyPem, try crypto.exportPrivateKey(allocator, reloadedPrivateKey, .pem));
    try std.testing.expectEqualStrings(publicKeyPem, try key_utils.exportPublicKeyToPem(allocator, try crypto.createPublicKey(allocator, publicKeyPem)));
    try std.testing.expectEqualStrings(publicKeyPem, try key_utils.exportPublicKeyToPem(allocator, crypto.createPublicKeyFromPrivateKey(reloadedPrivateKey)));

    // An RSA-4096 SPKI public key with exponent 65537 always has the same length and the same DER prefix, so the
    // Zig PEM has the length (800 bytes) and the first two lines of ts-public.pem up to where the modulus starts.
    const tsPublicKeyPem = try helpers.readFixture(allocator, "ts-public.pem");
    const spkiPrefix = "-----BEGIN PUBLIC KEY-----\nMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA";
    try std.testing.expectEqual(@as(usize, 800), tsPublicKeyPem.len);
    try std.testing.expectEqualStrings(spkiPrefix, tsPublicKeyPem[0..spkiPrefix.len]);
    try std.testing.expectEqual(@as(usize, 800), publicKeyPem.len);
    try std.testing.expectEqualStrings(spkiPrefix, publicKeyPem[0..spkiPrefix.len]);
    try std.testing.expect(std.mem.endsWith(u8, publicKeyPem, "AwEAAQ==\n-----END PUBLIC KEY-----\n"));
    try std.testing.expect(std.mem.endsWith(u8, tsPublicKeyPem, "AwEAAQ==\n-----END PUBLIC KEY-----\n"));

    // Zig output with the Zig key decrypts with the Zig private key, in the new format, the legacy format and as a stream.
    const keyMap = try buildKeyMap(allocator, keyPair.privateKey);
    for (sizes, ts_encrypted_lengths) |size, expectedLength| {
        const plain = try helpers.makePlaintext(allocator, size);
        const zigEncrypted = try encrypt_buffer.encryptBuffer(allocator, io, keyPair.publicKey, plain);
        try std.testing.expectEqual(expectedLength, zigEncrypted.len);
        try std.testing.expectEqualSlices(u8, plain, try encrypt_buffer.decryptBuffer(allocator, zigEncrypted, &keyMap));
        try std.testing.expectEqualSlices(u8, plain, try encrypt_buffer.decryptLegacy(allocator, zigEncrypted[ts_key_header.len..], keyPair.privateKey));
        const zigStream = try encryptThroughStream(allocator, keyPair.publicKey, plain);
        try std.testing.expectEqualSlices(u8, plain, try decryptThroughStream(allocator, &keyMap, zigStream));
    }
}
