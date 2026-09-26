const std = @import("std");
const encryption = @import("encryption-zig");
const helpers = @import("test-helpers.zig");

const rsa = encryption.rsa;
const asn1 = encryption.asn1;
const pem = encryption.pem;
const big_number = encryption.big_number;

//
// Loads the TypeScript fixture private key.
//
fn loadFixtureKey(allocator: std.mem.Allocator, file_name: []const u8) !rsa.PrivateKey {
    const block = try pem.decode(allocator, try helpers.readFixture(allocator, file_name));
    return rsa.initPrivateKey(allocator, try asn1.decodePrivateKeyInfo(block.der));
}

test "generateKeyPair creates a 4096-bit key that encrypts and decrypts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    const private_key = try rsa.generateKeyPair(allocator, io, 4096, rsa.default_public_exponent);

    try std.testing.expectEqual(@as(usize, 512), private_key.public_key.modulusLength());
    try std.testing.expect(private_key.components.modulus[0] >= 0x80);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 0x01 }, private_key.components.public_exponent);
    try std.testing.expectEqual(@as(usize, 256), private_key.components.prime1.len);
    try std.testing.expectEqual(@as(usize, 256), private_key.components.prime2.len);

    //
    // n = p * q.
    //
    const limb_count = big_number.limbCountForBytes(256);
    const prime1 = try big_number.allocFromBytes(allocator, private_key.components.prime1, limb_count);
    const prime2 = try big_number.allocFromBytes(allocator, private_key.components.prime2, limb_count);
    const product = try allocator.alloc(big_number.Limb, 2 * limb_count);
    big_number.multiply(product, prime1, prime2);
    const product_bytes = try allocator.alloc(u8, 512);
    try big_number.limbsToBytes(product_bytes, product);
    try std.testing.expectEqualSlices(u8, private_key.components.modulus, product_bytes);

    //
    // The CRT result equals m^d mod n computed directly, and m^(e*d) = m.
    //
    const message = try allocator.alloc(u8, 512);
    std.testing.io.random(message);
    message[0] = 0;
    const encrypted = try rsa.publicOperation(allocator, &private_key.public_key, message);
    const decrypted = try rsa.privateOperation(allocator, &private_key, encrypted);
    try std.testing.expectEqualSlices(u8, message, decrypted);
    const encrypted_limbs = try big_number.allocFromBytes(allocator, encrypted, private_key.public_key.modulus_limbs.len);
    const direct = try private_key.public_key.modulus_context.pow(allocator, encrypted_limbs, private_key.components.private_exponent);
    const direct_bytes = try allocator.alloc(u8, 512);
    try big_number.limbsToBytes(direct_bytes, direct);
    try std.testing.expectEqualSlices(u8, message, direct_bytes);

    const key_message = "0123456789abcdef0123456789abcdef";
    const ciphertext = try rsa.publicEncrypt(allocator, io, &private_key.public_key, key_message);
    try std.testing.expectEqual(@as(usize, 512), ciphertext.len);
    try std.testing.expectEqualSlices(u8, key_message, try rsa.privateDecrypt(allocator, &private_key, ciphertext));
}

test "privateDecrypt decrypts an AES key that TypeScript encrypted with publicEncrypt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const private_key = try loadFixtureKey(allocator, "ts-private.pem");
    const encrypted = try helpers.readFixture(allocator, "new-17.bin");
    const key = try rsa.privateDecrypt(allocator, &private_key, encrypted[44 .. 44 + 512]);
    try std.testing.expectEqual(@as(usize, 32), key.len);
}

test "privateOperation with the CRT matches the direct exponentiation for the TypeScript key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const private_key = try loadFixtureKey(allocator, "ts-private.pem");
    const encrypted = try helpers.readFixture(allocator, "legacy-1.bin");
    const crt = try rsa.privateOperation(allocator, &private_key, encrypted[0..512]);
    const encrypted_limbs = try big_number.allocFromBytes(allocator, encrypted[0..512], private_key.public_key.modulus_limbs.len);
    const direct = try private_key.public_key.modulus_context.pow(allocator, encrypted_limbs, private_key.components.private_exponent);
    const direct_bytes = try allocator.alloc(u8, 512);
    try big_number.limbsToBytes(direct_bytes, direct);
    try std.testing.expectEqualSlices(u8, direct_bytes, crt);
}

test "publicEncrypt output is randomized and decrypts with the matching key only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const private_key = try loadFixtureKey(allocator, "ts-private.pem");
    const other_key = try loadFixtureKey(allocator, "ts2-private.pem");
    const first = try rsa.publicEncrypt(allocator, io, &private_key.public_key, "secret");
    const second = try rsa.publicEncrypt(allocator, io, &private_key.public_key, "secret");
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expectEqualStrings("secret", try rsa.privateDecrypt(allocator, &private_key, second));
    if (rsa.privateDecrypt(allocator, &other_key, first)) |_| {
        return error.TestUnexpectedResult;
    }
    else |err| {
        try std.testing.expect(err == error.OaepDecodingError or err == error.DataGreaterThanModulus);
    }
}

test "publicEncrypt rejects messages longer than k - 42 bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const private_key = try loadFixtureKey(allocator, "ts-private.pem");
    const longest = try allocator.alloc(u8, 470);
    @memset(longest, 0x5a);
    const ciphertext = try rsa.publicEncrypt(allocator, io, &private_key.public_key, longest);
    try std.testing.expectEqualSlices(u8, longest, try rsa.privateDecrypt(allocator, &private_key, ciphertext));
    try std.testing.expectError(error.DataTooLarge, rsa.publicEncrypt(allocator, io, &private_key.public_key, try allocator.alloc(u8, 471)));
}

test "oaepEncode and oaepDecode round-trip and detect corruption" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const encoded = try rsa.oaepEncode(allocator, std.testing.io, "hello", 128);
    try std.testing.expectEqual(@as(u8, 0), encoded[0]);
    try std.testing.expectEqualStrings("hello", try rsa.oaepDecode(allocator, encoded));
    const empty = try rsa.oaepEncode(allocator, std.testing.io, "", 128);
    try std.testing.expectEqualStrings("", try rsa.oaepDecode(allocator, empty));
    encoded[100] ^= 1;
    try std.testing.expectError(error.OaepDecodingError, rsa.oaepDecode(allocator, encoded));
}

test "raw operations reject inputs of the wrong length or not smaller than the modulus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const private_key = try loadFixtureKey(allocator, "ts-private.pem");
    try std.testing.expectError(error.InvalidInputLength, rsa.privateOperation(allocator, &private_key, &([_]u8{1} ** 513)));
    try std.testing.expectError(error.OaepDecodingError, rsa.privateDecrypt(allocator, &private_key, "short"));
    const too_big = try allocator.alloc(u8, 512);
    @memset(too_big, 0xff);
    try std.testing.expectError(error.DataGreaterThanModulus, rsa.publicOperation(allocator, &private_key.public_key, too_big));
}

test "initPublicKey rejects an even modulus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.InvalidKey, rsa.initPublicKey(allocator, .{ .modulus = &.{ 0x12, 0x34 }, .public_exponent = &.{3} }));
}
