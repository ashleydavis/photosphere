const std = @import("std");
const utils = @import("utils-zig");
const encryption = @import("encryption-zig");
const helpers = @import("test-helpers.zig");

const crypto = encryption.node_crypto;

test "createPrivateKey and exportPrivateKey reproduce the TypeScript PKCS#8 PEM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const privateKeyPem = try helpers.readFixture(allocator, "ts-private.pem");
    const privateKey = try crypto.createPrivateKey(allocator, privateKeyPem);
    try std.testing.expectEqualStrings(privateKeyPem, try crypto.exportPrivateKey(allocator, privateKey, .pem));
}

test "createPublicKey accepts SPKI, PKCS#1 and private key PEMs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const publicKeyPem = try helpers.readFixture(allocator, "ts-public.pem");
    const privateKeyPem = try helpers.readFixture(allocator, "ts-private.pem");
    const fromSpki = try crypto.createPublicKey(allocator, publicKeyPem);
    try std.testing.expectEqualStrings(publicKeyPem, try crypto.exportPublicKey(allocator, fromSpki, .pem));
    const fromPrivate = try crypto.createPublicKey(allocator, privateKeyPem);
    try std.testing.expectEqualStrings(publicKeyPem, try crypto.exportPublicKey(allocator, fromPrivate, .pem));

    const pkcs1Der = try encryption.asn1.encodeRsaPublicKey(allocator, fromSpki.components);
    const pkcs1Pem = try encryption.pem.encode(allocator, "RSA PUBLIC KEY", pkcs1Der);
    const fromPkcs1 = try crypto.createPublicKey(allocator, pkcs1Pem);
    try std.testing.expectEqualStrings(publicKeyPem, try crypto.exportPublicKey(allocator, fromPkcs1, .pem));
}

test "createPrivateKey accepts a PKCS#1 RSA PRIVATE KEY PEM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const privateKeyPem = try helpers.readFixture(allocator, "ts-private.pem");
    const privateKey = try crypto.createPrivateKey(allocator, privateKeyPem);
    const pkcs1Der = try encryption.asn1.encodeRsaPrivateKey(allocator, privateKey.components);
    const pkcs1Pem = try encryption.pem.encode(allocator, "RSA PRIVATE KEY", pkcs1Der);
    const fromPkcs1 = try crypto.createPrivateKey(allocator, pkcs1Pem);
    try std.testing.expectEqualStrings(privateKeyPem, try crypto.exportPrivateKey(allocator, fromPkcs1, .pem));
}

test "createPrivateKey throws the Node decoder error for invalid input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.Thrown, crypto.createPrivateKey(allocator, "garbage"));
    try std.testing.expectEqualStrings("error:1E08010C:DECODER routines::unsupported", utils.errors.lastErrorMessage());
    const publicKeyPem = try helpers.readFixture(allocator, "ts-public.pem");
    try std.testing.expectError(error.Thrown, crypto.createPrivateKey(allocator, publicKeyPem));
    try std.testing.expectError(error.Thrown, crypto.createPublicKey(allocator, "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n"));
}

test "createCipheriv and createDecipheriv round-trip and validate their arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var key: [32]u8 = undefined;
    crypto.randomBytes(std.testing.io, &key);
    var iv: [16]u8 = undefined;
    crypto.randomBytes(std.testing.io, &iv);
    var cipher = try crypto.createCipheriv("aes-256-cbc", &key, &iv);
    const encrypted = try std.mem.concat(allocator, u8, &.{ try cipher.update(allocator, "hello world"), try cipher.final(allocator) });
    try std.testing.expectEqual(@as(usize, 16), encrypted.len);
    var decipher = try crypto.createDecipheriv("aes-256-cbc", &key, &iv);
    const decrypted = try std.mem.concat(allocator, u8, &.{ try decipher.update(allocator, encrypted), try decipher.final(allocator) });
    try std.testing.expectEqualStrings("hello world", decrypted);

    try std.testing.expectError(error.Thrown, crypto.createCipheriv("aes-256-cbc", key[0..16], &iv));
    try std.testing.expectEqualStrings("Invalid key length", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, crypto.createDecipheriv("aes-256-cbc", &key, iv[0..8]));
    try std.testing.expectEqualStrings("Invalid initialization vector", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, crypto.createDecipheriv("aes-128-cbc", &key, &iv));

    var truncated = try crypto.createDecipheriv("aes-256-cbc", &key, &iv);
    _ = try truncated.update(allocator, encrypted[0..10]);
    try std.testing.expectError(error.Thrown, truncated.final(allocator));
    try std.testing.expectEqualStrings("error:1C80006B:Provider routines::wrong final block length", utils.errors.lastErrorMessage());
}

test "publicEncrypt and privateDecrypt use OAEP and report Node errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const privateKey = try crypto.createPrivateKey(allocator, try helpers.readFixture(allocator, "ts-private.pem"));
    const otherKey = try crypto.createPrivateKey(allocator, try helpers.readFixture(allocator, "ts2-private.pem"));
    const publicKey = crypto.createPublicKeyFromPrivateKey(privateKey);
    const encrypted = try crypto.publicEncrypt(allocator, std.testing.io, publicKey, "aes key");
    try std.testing.expectEqualStrings("aes key", try crypto.privateDecrypt(allocator, privateKey, encrypted));
    try std.testing.expectError(error.Thrown, crypto.privateDecrypt(allocator, otherKey, encrypted));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "error:020000"));
    try std.testing.expectError(error.Thrown, crypto.privateDecrypt(allocator, privateKey, "short"));
    try std.testing.expectEqualStrings("error:02000079:rsa routines::oaep decoding error", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, crypto.privateDecrypt(allocator, privateKey, &([_]u8{1} ** 513)));
    try std.testing.expectEqualStrings("error:0200006C:rsa routines::data greater than mod len", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, crypto.publicEncrypt(allocator, std.testing.io, publicKey, &([_]u8{0} ** 471)));
    try std.testing.expectEqualStrings("error:0200006E:rsa routines::data too large for key size", utils.errors.lastErrorMessage());
}
