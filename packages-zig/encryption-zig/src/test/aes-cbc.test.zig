const std = @import("std");
const encryption = @import("encryption-zig");

const aes_cbc = encryption.aes_cbc;

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

test "CbcEncryptor matches the NIST CBC-AES256 vectors and adds a full padding block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var output: std.ArrayList(u8) = .empty;
    var encryptor = aes_cbc.CbcEncryptor.init(nist_key, nist_iv);
    try encryptor.update(allocator, &output, nist_plaintext[0..5]);
    try encryptor.update(allocator, &output, nist_plaintext[5..]);
    try encryptor.final(allocator, &output);
    try std.testing.expectEqual(@as(usize, 80), output.items.len);
    try std.testing.expectEqualSlices(u8, &nist_ciphertext, output.items[0..64]);
}

test "CbcDecryptor decrypts and removes the padding for every split point" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var encrypted: std.ArrayList(u8) = .empty;
    var encryptor = aes_cbc.CbcEncryptor.init(nist_key, nist_iv);
    try encryptor.update(allocator, &encrypted, nist_plaintext[0..37]);
    try encryptor.final(allocator, &encrypted);
    try std.testing.expectEqual(@as(usize, 48), encrypted.items.len);

    var split: usize = 0;
    while (split <= encrypted.items.len) : (split += 1) {
        var output: std.ArrayList(u8) = .empty;
        var decryptor = aes_cbc.CbcDecryptor.init(nist_key, nist_iv);
        try decryptor.update(allocator, &output, encrypted.items[0..split]);
        try decryptor.update(allocator, &output, encrypted.items[split..]);
        try decryptor.final(allocator, &output);
        try std.testing.expectEqualSlices(u8, nist_plaintext[0..37], output.items);
    }
}

test "CbcEncryptor pads empty input to one block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var output: std.ArrayList(u8) = .empty;
    var encryptor = aes_cbc.CbcEncryptor.init(nist_key, nist_iv);
    try encryptor.final(allocator, &output);
    try std.testing.expectEqual(@as(usize, 16), output.items.len);

    var decrypted: std.ArrayList(u8) = .empty;
    var decryptor = aes_cbc.CbcDecryptor.init(nist_key, nist_iv);
    try decryptor.update(allocator, &decrypted, output.items);
    try decryptor.final(allocator, &decrypted);
    try std.testing.expectEqual(@as(usize, 0), decrypted.items.len);
}

test "CbcDecryptor rejects a truncated ciphertext and a wrong key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var output: std.ArrayList(u8) = .empty;
    var truncated = aes_cbc.CbcDecryptor.init(nist_key, nist_iv);
    try truncated.update(allocator, &output, nist_ciphertext[0..20]);
    try std.testing.expectError(error.WrongFinalBlockLength, truncated.final(allocator, &output));

    var wrong_key = nist_key;
    wrong_key[0] ^= 0xff;
    var encrypted: std.ArrayList(u8) = .empty;
    var encryptor = aes_cbc.CbcEncryptor.init(nist_key, nist_iv);
    try encryptor.update(allocator, &encrypted, "some text");
    try encryptor.final(allocator, &encrypted);
    var bad_padding_found = false;
    var attempt: u8 = 0;
    while (attempt < 8) : (attempt += 1) {
        wrong_key[1] = attempt;
        var decrypted: std.ArrayList(u8) = .empty;
        var decryptor = aes_cbc.CbcDecryptor.init(wrong_key, nist_iv);
        try decryptor.update(allocator, &decrypted, encrypted.items);
        decryptor.final(allocator, &decrypted) catch |err| {
            try std.testing.expectEqual(error.BadDecrypt, err);
            bad_padding_found = true;
        };
    }
    try std.testing.expect(bad_padding_found);
}
