const std = @import("std");

//
// AES-256-CBC with PKCS#7 padding, as done by node:crypto's createCipheriv/createDecipheriv('aes-256-cbc').
// This file has no TypeScript counterpart: TypeScript uses node:crypto (OpenSSL).
//
// Both directions are incremental (update/final) so they can be used by the streams in encrypt-stream.zig.
//

//
// The AES block size in bytes.
//
pub const block_length = 16;

//
// The AES-256 key size in bytes.
//
pub const key_length = 32;

//
// The AES-256 block cipher from the Zig standard library.
//
const Aes256 = std.crypto.core.aes.Aes256;

//
// Errors raised by decryption when the ciphertext is malformed.
//
pub const DecryptError = error{
    // The ciphertext length is not a multiple of the block size.
    WrongFinalBlockLength,

    // The PKCS#7 padding is invalid (usually a wrong key).
    BadDecrypt,
};

//
// Incremental AES-256-CBC encryption with PKCS#7 padding.
//
pub const CbcEncryptor = struct {
    // The expanded encryption key.
    context: @TypeOf(Aes256.initEnc(undefined)),

    // The previous ciphertext block (initially the IV).
    previous_block: [block_length]u8,

    // Plaintext bytes waiting for a full block.
    partial_block: [block_length]u8,

    // The number of valid bytes in partial_block.
    partial_length: usize,

    //
    // Creates an encryptor from a 32-byte key and a 16-byte IV.
    //
    pub fn init(key: [key_length]u8, iv: [block_length]u8) CbcEncryptor {
        return CbcEncryptor{
            .context = Aes256.initEnc(key),
            .previous_block = iv,
            .partial_block = undefined,
            .partial_length = 0,
        };
    }

    //
    // Encrypts one full block and appends it to the output.
    //
    fn encryptBlock(self: *CbcEncryptor, allocator: std.mem.Allocator, output: *std.ArrayList(u8), block: *const [block_length]u8) !void {
        var input_block: [block_length]u8 = undefined;
        for (&input_block, block, self.previous_block) |*input_byte, plain_byte, previous_byte| {
            input_byte.* = plain_byte ^ previous_byte;
        }
        self.context.encrypt(&self.previous_block, &input_block);
        try output.appendSlice(allocator, &self.previous_block);
    }

    //
    // Encrypts as many full blocks as possible and appends the ciphertext to the output.
    //
    pub fn update(self: *CbcEncryptor, allocator: std.mem.Allocator, output: *std.ArrayList(u8), data: []const u8) !void {
        try output.ensureUnusedCapacity(allocator, data.len + block_length);
        var offset: usize = 0;
        while (offset < data.len) {
            const count = @min(block_length - self.partial_length, data.len - offset);
            @memcpy(self.partial_block[self.partial_length .. self.partial_length + count], data[offset .. offset + count]);
            self.partial_length += count;
            offset += count;
            if (self.partial_length == block_length) {
                try self.encryptBlock(allocator, output, &self.partial_block);
                self.partial_length = 0;
            }
        }
    }

    //
    // Pads the remaining bytes (PKCS#7, always at least one byte) and appends the final block to the output.
    //
    pub fn final(self: *CbcEncryptor, allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
        const padding: u8 = @intCast(block_length - self.partial_length);
        @memset(self.partial_block[self.partial_length..], padding);
        try self.encryptBlock(allocator, output, &self.partial_block);
        self.partial_length = 0;
    }
};

//
// Incremental AES-256-CBC decryption with PKCS#7 padding removal.
// The last full block is held back until final() so that the padding can be removed.
//
pub const CbcDecryptor = struct {
    // The expanded decryption key.
    context: @TypeOf(Aes256.initDec(undefined)),

    // The previous ciphertext block (initially the IV).
    previous_block: [block_length]u8,

    // Ciphertext bytes waiting to be decrypted.
    partial_block: [block_length]u8,

    // The number of valid bytes in partial_block.
    partial_length: usize,

    //
    // Creates a decryptor from a 32-byte key and a 16-byte IV.
    //
    pub fn init(key: [key_length]u8, iv: [block_length]u8) CbcDecryptor {
        return CbcDecryptor{
            .context = Aes256.initDec(key),
            .previous_block = iv,
            .partial_block = undefined,
            .partial_length = 0,
        };
    }

    //
    // Decrypts the buffered full block into plain.
    //
    fn decryptBlock(self: *CbcDecryptor, plain: *[block_length]u8) void {
        var decrypted: [block_length]u8 = undefined;
        self.context.decrypt(&decrypted, &self.partial_block);
        for (plain, decrypted, self.previous_block) |*plain_byte, decrypted_byte, previous_byte| {
            plain_byte.* = decrypted_byte ^ previous_byte;
        }
        self.previous_block = self.partial_block;
        self.partial_length = 0;
    }

    //
    // Decrypts every block except the last one received and appends the plaintext to the output.
    //
    pub fn update(self: *CbcDecryptor, allocator: std.mem.Allocator, output: *std.ArrayList(u8), data: []const u8) !void {
        try output.ensureUnusedCapacity(allocator, data.len + block_length);
        var offset: usize = 0;
        while (offset < data.len) {
            if (self.partial_length == block_length) {
                var plain: [block_length]u8 = undefined;
                self.decryptBlock(&plain);
                try output.appendSlice(allocator, &plain);
            }
            const count = @min(block_length - self.partial_length, data.len - offset);
            @memcpy(self.partial_block[self.partial_length .. self.partial_length + count], data[offset .. offset + count]);
            self.partial_length += count;
            offset += count;
        }
    }

    //
    // Decrypts the last block, checks and removes the PKCS#7 padding and appends the rest to the output.
    //
    pub fn final(self: *CbcDecryptor, allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
        if (self.partial_length != block_length) {
            return error.WrongFinalBlockLength;
        }
        var plain: [block_length]u8 = undefined;
        self.decryptBlock(&plain);
        const padding = plain[block_length - 1];
        if (padding == 0 or padding > block_length) {
            return error.BadDecrypt;
        }
        for (plain[block_length - padding ..]) |padding_byte| {
            if (padding_byte != padding) {
                return error.BadDecrypt;
            }
        }
        try output.appendSlice(allocator, plain[0 .. block_length - padding]);
    }
};
