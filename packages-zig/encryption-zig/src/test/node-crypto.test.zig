const std = @import("std");
const utils = @import("utils-zig");
const encryption = @import("encryption-zig");
const helpers = @import("test-helpers.zig");

const openssl = @import("openssl");

const crypto = encryption.node_crypto;

//
// Decodes a hex string at compile time.
//
fn hex(comptime text: []const u8) [text.len / 2]u8 {
    var bytes: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text) catch unreachable;
    return bytes;
}

//
// NIST SP 800-38A F.2.5 CBC-AES256 key.
//
const nist_key = hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4");

//
// NIST SP 800-38A F.2.5 CBC-AES256 IV.
//
const nist_iv = hex("000102030405060708090a0b0c0d0e0f");

//
// NIST SP 800-38A F.2.5 CBC-AES256 plaintext.
//
const nist_plaintext = hex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710");

//
// NIST SP 800-38A F.2.5 CBC-AES256 ciphertext.
//
const nist_ciphertext = hex("f58c4c04d6e5f1ba779eabfb5f7bfbd69cfc4e967edb808d679f777bc6702c7d39f23369a9d9bacfa530e26304231461b2eb05e2c39be9fcda6c19078c6a9d1b");

//
// Opens a read-only libcrypto memory BIO over text.
//
fn openBio(text: []const u8) !*openssl.BIO {
    return openssl.BIO_new_mem_buf(text.ptr, @intCast(text.len)) orelse error.TestUnexpectedResult;
}

//
// Copies what was written to a libcrypto memory BIO.
//
fn bioContents(allocator: std.mem.Allocator, bio: *openssl.BIO) ![]u8 {
    var contents: [*c]const u8 = null;
    var length: usize = 0;
    try std.testing.expectEqual(@as(c_int, 1), openssl.BIO_mem_contents(bio, &contents, &length));
    return allocator.dupe(u8, contents[0..length]);
}

//
// Rewrites an SPKI public key PEM as a PKCS#1 "RSA PUBLIC KEY" PEM, with libcrypto.
//
fn toPkcs1PublicKeyPem(allocator: std.mem.Allocator, spkiPem: []const u8) ![]u8 {
    const input = try openBio(spkiPem);
    defer _ = openssl.BIO_free(input);
    const rsaKey = openssl.PEM_read_bio_RSA_PUBKEY(input, null, null, null) orelse {
        return error.TestUnexpectedResult;
    };
    defer openssl.RSA_free(rsaKey);
    const output = openssl.BIO_new(openssl.BIO_s_mem()) orelse {
        return error.TestUnexpectedResult;
    };
    defer _ = openssl.BIO_free(output);
    try std.testing.expectEqual(@as(c_int, 1), openssl.PEM_write_bio_RSAPublicKey(output, rsaKey));
    return bioContents(allocator, output);
}

//
// Rewrites a PKCS#8 private key PEM as a PKCS#1 "RSA PRIVATE KEY" PEM, with libcrypto.
//
fn toPkcs1PrivateKeyPem(allocator: std.mem.Allocator, pkcs8Pem: []const u8) ![]u8 {
    const input = try openBio(pkcs8Pem);
    defer _ = openssl.BIO_free(input);
    const rsaKey = openssl.PEM_read_bio_RSAPrivateKey(input, null, null, null) orelse {
        return error.TestUnexpectedResult;
    };
    defer openssl.RSA_free(rsaKey);
    const output = openssl.BIO_new(openssl.BIO_s_mem()) orelse {
        return error.TestUnexpectedResult;
    };
    defer _ = openssl.BIO_free(output);
    try std.testing.expectEqual(@as(c_int, 1), openssl.PEM_write_bio_RSAPrivateKey(output, rsaKey, null, null, 0, null, null));
    return bioContents(allocator, output);
}

//
// Encrypts data in one go with a fresh AES-256-CBC cipher.
//
fn encryptAll(allocator: std.mem.Allocator, key: []const u8, iv: []const u8, data: []const u8) ![]u8 {
    var cipher = try crypto.createCipheriv("aes-256-cbc", key, iv);
    return std.mem.concat(allocator, u8, &.{
        try cipher.update(allocator, data),
        try cipher.final(allocator),
    });
}

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

    const pkcs1Pem = try toPkcs1PublicKeyPem(allocator, publicKeyPem);
    try std.testing.expect(std.mem.startsWith(u8, pkcs1Pem, "-----BEGIN RSA PUBLIC KEY-----\n"));
    const fromPkcs1 = try crypto.createPublicKey(allocator, pkcs1Pem);
    try std.testing.expectEqualStrings(publicKeyPem, try crypto.exportPublicKey(allocator, fromPkcs1, .pem));
}

test "createPrivateKey accepts a PKCS#1 RSA PRIVATE KEY PEM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const privateKeyPem = try helpers.readFixture(allocator, "ts-private.pem");
    const pkcs1Pem = try toPkcs1PrivateKeyPem(allocator, privateKeyPem);
    try std.testing.expect(std.mem.startsWith(u8, pkcs1Pem, "-----BEGIN RSA PRIVATE KEY-----\n"));
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

test "createPublicKey accepts CRLF line endings and text around the PEM block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const publicKeyPem = try helpers.readFixture(allocator, "ts-public.pem");
    const crlfPem = try std.mem.replaceOwned(u8, allocator, publicKeyPem, "\n", "\r\n");
    const surrounded = try std.mem.concat(allocator, u8, &.{
        "junk before\r\n",
        crlfPem,
        "junk after\r\n",
    });
    const publicKey = try crypto.createPublicKey(allocator, surrounded);
    try std.testing.expectEqualStrings(publicKeyPem, try crypto.exportPublicKey(allocator, publicKey, .pem));
}

test "generateKeyPairSync creates an RSA key with the requested modulus length and exponent 65537" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const generated = try crypto.generateKeyPairSync(allocator, std.testing.io, 4096);
    try std.testing.expect(std.mem.startsWith(u8, generated.publicKey, "-----BEGIN PUBLIC KEY-----\n"));
    try std.testing.expect(std.mem.startsWith(u8, generated.privateKey, "-----BEGIN PRIVATE KEY-----\n"));

    const input = try openBio(generated.publicKey);
    defer _ = openssl.BIO_free(input);
    const rsaKey = openssl.PEM_read_bio_RSA_PUBKEY(input, null, null, null) orelse {
        return error.TestUnexpectedResult;
    };
    defer openssl.RSA_free(rsaKey);
    try std.testing.expectEqual(@as(c_uint, 4096), openssl.RSA_bits(rsaKey));
    try std.testing.expectEqual(@as(u64, 65537), openssl.BN_get_word(openssl.RSA_get0_e(rsaKey)));

    const privateKey = try crypto.createPrivateKey(allocator, generated.privateKey);
    try std.testing.expectEqualStrings(generated.privateKey, try crypto.exportPrivateKey(allocator, privateKey, .pem));
    try std.testing.expectEqualStrings(generated.publicKey, try crypto.exportPublicKey(allocator, crypto.createPublicKeyFromPrivateKey(privateKey), .pem));
    const publicKey = try crypto.createPublicKey(allocator, generated.publicKey);
    try std.testing.expectEqual(@as(usize, 512), publicKey.modulusLength());
    const encrypted = try crypto.publicEncrypt(allocator, std.testing.io, publicKey, "0123456789abcdef0123456789abcdef");
    try std.testing.expectEqual(@as(usize, 512), encrypted.len);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", try crypto.privateDecrypt(allocator, privateKey, encrypted));
}

test "privateDecrypt decrypts the AES key TypeScript wrapped with publicEncrypt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const privateKey = try crypto.createPrivateKey(allocator, try helpers.readFixture(allocator, "ts-private.pem"));
    const encrypted = try helpers.readFixture(allocator, "new-17.bin");
    const key = try crypto.privateDecrypt(allocator, privateKey, encrypted[44 .. 44 + 512]);
    try std.testing.expectEqual(@as(usize, 32), key.len);

    // The unwrapped key and the IV that follows the wrapped key decrypt the file's ciphertext to the fixture plaintext.
    var decipher = try crypto.createDecipheriv("aes-256-cbc", key, encrypted[44 + 512 .. 44 + 512 + 16]);
    const decrypted = try std.mem.concat(allocator, u8, &.{
        try decipher.update(allocator, encrypted[44 + 512 + 16 ..]),
        try decipher.final(allocator),
    });
    try std.testing.expectEqualSlices(u8, try helpers.readFixture(allocator, "plain-17.bin"), decrypted);
}

test "publicEncrypt output is randomized, takes up to k - 42 bytes and decrypts with the matching key only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const privateKey = try crypto.createPrivateKey(allocator, try helpers.readFixture(allocator, "ts-private.pem"));
    const publicKey = crypto.createPublicKeyFromPrivateKey(privateKey);
    const first = try crypto.publicEncrypt(allocator, std.testing.io, publicKey, "secret");
    const second = try crypto.publicEncrypt(allocator, std.testing.io, publicKey, "secret");
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expectEqualStrings("secret", try crypto.privateDecrypt(allocator, privateKey, first));
    try std.testing.expectEqualStrings("secret", try crypto.privateDecrypt(allocator, privateKey, second));

    const longest = try allocator.alloc(u8, 470);
    @memset(longest, 0x5a);
    const ciphertext = try crypto.publicEncrypt(allocator, std.testing.io, publicKey, longest);
    try std.testing.expectEqualSlices(u8, longest, try crypto.privateDecrypt(allocator, privateKey, ciphertext));
}

test "privateDecrypt reports the Node error for a ciphertext not smaller than the modulus" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const privateKey = try crypto.createPrivateKey(allocator, try helpers.readFixture(allocator, "ts-private.pem"));
    try std.testing.expectError(error.Thrown, crypto.privateDecrypt(allocator, privateKey, &([_]u8{0xff} ** 512)));
    try std.testing.expectEqualStrings("error:02000084:rsa routines::data too large for modulus", utils.errors.lastErrorMessage());
}

test "createCipheriv matches the NIST CBC-AES256 vectors and adds a full padding block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cipher = try crypto.createCipheriv("aes-256-cbc", &nist_key, &nist_iv);
    const encrypted = try std.mem.concat(allocator, u8, &.{
        try cipher.update(allocator, nist_plaintext[0..5]),
        try cipher.update(allocator, nist_plaintext[5..]),
        try cipher.final(allocator),
    });
    try std.testing.expectEqual(@as(usize, 80), encrypted.len);
    try std.testing.expectEqualSlices(u8, &nist_ciphertext, encrypted[0..64]);
}

test "createDecipheriv decrypts and removes the padding for every split point" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const encrypted = try encryptAll(allocator, &nist_key, &nist_iv, nist_plaintext[0..37]);
    try std.testing.expectEqual(@as(usize, 48), encrypted.len);
    var split: usize = 0;
    while (split <= encrypted.len) : (split += 1) {
        var output: std.ArrayList(u8) = .empty;
        var decipher = try crypto.createDecipheriv("aes-256-cbc", &nist_key, &nist_iv);
        try decipher.updateInto(allocator, &output, encrypted[0..split]);
        try decipher.updateInto(allocator, &output, encrypted[split..]);
        try decipher.finalInto(allocator, &output);
        try std.testing.expectEqualSlices(u8, nist_plaintext[0..37], output.items);
    }
}

test "createCipheriv pads empty input to one block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const encrypted = try encryptAll(allocator, &nist_key, &nist_iv, "");
    try std.testing.expectEqual(@as(usize, 16), encrypted.len);
    var decipher = try crypto.createDecipheriv("aes-256-cbc", &nist_key, &nist_iv);
    const decrypted = try std.mem.concat(allocator, u8, &.{
        try decipher.update(allocator, encrypted),
        try decipher.final(allocator),
    });
    try std.testing.expectEqual(@as(usize, 0), decrypted.len);
}

test "createDecipheriv reports the Node bad decrypt error for a wrong key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const encrypted = try encryptAll(allocator, &nist_key, &nist_iv, "some text");
    var wrongKey = nist_key;
    wrongKey[0] ^= 0xff;
    var badDecryptFound = false;
    var attempt: u8 = 0;
    while (attempt < 8) : (attempt += 1) {
        wrongKey[1] = attempt;
        var decipher = try crypto.createDecipheriv("aes-256-cbc", &wrongKey, &nist_iv);
        _ = try decipher.update(allocator, encrypted);
        if (decipher.final(allocator)) |_| {
            continue;
        }
        else |err| {
            try std.testing.expectEqual(error.Thrown, err);
            try std.testing.expectEqualStrings("error:1C800064:Provider routines::bad decrypt", utils.errors.lastErrorMessage());
            badDecryptFound = true;
        }
    }
    try std.testing.expect(badDecryptFound);
}

test "a cipher refuses update and final after final or deinit, like Node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cipher = try crypto.createCipheriv("aes-256-cbc", &nist_key, &nist_iv);
    _ = try cipher.final(allocator);
    try std.testing.expectError(error.Thrown, cipher.update(allocator, "more"));
    try std.testing.expectEqualStrings("Invalid state for operation update", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, cipher.final(allocator));
    try std.testing.expectEqualStrings("Invalid state for operation final", utils.errors.lastErrorMessage());
    cipher.deinit();

    var abandoned = try crypto.createCipheriv("aes-256-cbc", &nist_key, &nist_iv);
    _ = try abandoned.update(allocator, "partial");
    abandoned.deinit();
    try std.testing.expectError(error.Thrown, abandoned.final(allocator));
    try std.testing.expectEqualStrings("Invalid state for operation final", utils.errors.lastErrorMessage());

    var decipher = try crypto.createDecipheriv("aes-256-cbc", &nist_key, &nist_iv);
    decipher.deinit();
    try std.testing.expectError(error.Thrown, decipher.update(allocator, &nist_ciphertext));
    try std.testing.expectEqualStrings("Invalid state for operation update", utils.errors.lastErrorMessage());
}
