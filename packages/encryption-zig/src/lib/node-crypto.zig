const std = @import("std");
const utils = @import("utils-zig");
const aes_cbc = @import("aes-cbc.zig");
const asn1 = @import("asn1.zig");
const pem = @import("pem.zig");
const rsa = @import("rsa.zig");

//
// The subset of node:crypto that the encryption package uses, so that the ported files read like the TypeScript.
// This file has no TypeScript counterpart (node:crypto is part of Node). Error messages match the OpenSSL 3 messages
// that Node reports for the same failures.
//

//
// Names used from other files (the equivalent of the TypeScript imports).
//
const errors = utils.errors;

//
// An RSA public key (node:crypto KeyObject of type 'public').
//
pub const PublicKey = rsa.PublicKey;

//
// An RSA private key (node:crypto KeyObject of type 'private').
//
pub const PrivateKey = rsa.PrivateKey;

//
// Encodings for exported keys (node:crypto KeyObject.export format option).
//
pub const KeyFormat = enum {
    // PEM text.
    pem,

    // Raw DER bytes.
    der,
};

//
// The result of generateKeyPairSync with PEM encodings (spki public key and pkcs8 private key).
//
pub const GeneratedKeyPairPem = struct {
    // The PEM-encoded SPKI public key.
    publicKey: []const u8,

    // The PEM-encoded PKCS#8 private key.
    privateKey: []const u8,
};

//
// Fills a buffer with cryptographically strong random bytes (node:crypto randomBytes).
//
pub fn randomBytes(io: std.Io, buffer: []u8) void {
    io.random(buffer);
}

//
// Generates an RSA key pair and returns it as PEM (generateKeyPairSync('rsa', { modulusLength,
// publicKeyEncoding: { type: 'spki', format: 'pem' }, privateKeyEncoding: { type: 'pkcs8', format: 'pem' } })).
//
pub fn generateKeyPairSync(allocator: std.mem.Allocator, io: std.Io, modulusLength: usize) !GeneratedKeyPairPem {
    const privateKey = try rsa.generateKeyPair(allocator, io, modulusLength, rsa.default_public_exponent);
    return GeneratedKeyPairPem{
        .publicKey = try exportPublicKey(allocator, &privateKey.public_key, .pem),
        .privateKey = try exportPrivateKey(allocator, &privateKey, .pem),
    };
}

//
// Throws the error Node reports for key data it cannot decode.
//
fn throwUnsupportedKey() errors.ThrownError {
    return errors.throwError("error:1E08010C:DECODER routines::unsupported", .{});
}

//
// Creates a private key from PEM text (node:crypto createPrivateKey). Accepts PKCS#8 ("PRIVATE KEY") and
// PKCS#1 ("RSA PRIVATE KEY") RSA keys.
//
pub fn createPrivateKey(allocator: std.mem.Allocator, keyPem: []const u8) !*const PrivateKey {
    const block = pem.decode(allocator, keyPem) catch |err| {
        if (err == error.OutOfMemory) {
            return err;
        }
        return throwUnsupportedKey();
    };
    var components: asn1.RsaPrivateKeyComponents = undefined;
    if (std.mem.eql(u8, block.label, "PRIVATE KEY")) {
        components = asn1.decodePrivateKeyInfo(block.der) catch {
            return throwUnsupportedKey();
        };
    }
    else if (std.mem.eql(u8, block.label, "RSA PRIVATE KEY")) {
        components = asn1.decodeRsaPrivateKey(block.der) catch {
            return throwUnsupportedKey();
        };
    }
    else {
        return throwUnsupportedKey();
    }
    const key = try allocator.create(PrivateKey);
    key.* = rsa.initPrivateKey(allocator, components) catch |err| {
        if (err == error.OutOfMemory) {
            return err;
        }
        return throwUnsupportedKey();
    };
    return key;
}

//
// Creates a public key from PEM text (node:crypto createPublicKey). Accepts SPKI ("PUBLIC KEY") and
// PKCS#1 ("RSA PUBLIC KEY") RSA keys, and private key PEMs (the public half is returned, like Node).
//
pub fn createPublicKey(allocator: std.mem.Allocator, keyPem: []const u8) !*const PublicKey {
    const block = pem.decode(allocator, keyPem) catch |err| {
        if (err == error.OutOfMemory) {
            return err;
        }
        return throwUnsupportedKey();
    };
    if (std.mem.eql(u8, block.label, "PRIVATE KEY") or std.mem.eql(u8, block.label, "RSA PRIVATE KEY")) {
        const privateKey = try createPrivateKey(allocator, keyPem);
        return createPublicKeyFromPrivateKey(privateKey);
    }
    var components: asn1.RsaPublicKeyComponents = undefined;
    if (std.mem.eql(u8, block.label, "PUBLIC KEY")) {
        components = asn1.decodeSubjectPublicKeyInfo(block.der) catch {
            return throwUnsupportedKey();
        };
    }
    else if (std.mem.eql(u8, block.label, "RSA PUBLIC KEY")) {
        components = asn1.decodeRsaPublicKey(block.der) catch {
            return throwUnsupportedKey();
        };
    }
    else {
        return throwUnsupportedKey();
    }
    const key = try allocator.create(PublicKey);
    key.* = rsa.initPublicKey(allocator, components) catch |err| {
        if (err == error.OutOfMemory) {
            return err;
        }
        return throwUnsupportedKey();
    };
    return key;
}

//
// Returns the public key of a private key (node:crypto createPublicKey(privateKeyObject)).
//
pub fn createPublicKeyFromPrivateKey(privateKey: *const PrivateKey) *const PublicKey {
    return &privateKey.public_key;
}

//
// Exports a public key as SPKI (KeyObject.export({ type: 'spki', format })).
//
pub fn exportPublicKey(allocator: std.mem.Allocator, publicKey: *const PublicKey, format: KeyFormat) ![]u8 {
    const der = try asn1.encodeSubjectPublicKeyInfo(allocator, publicKey.components);
    if (format == .der) {
        return der;
    }
    return pem.encode(allocator, "PUBLIC KEY", der);
}

//
// Exports a private key as PKCS#8 (KeyObject.export({ type: 'pkcs8', format })).
//
pub fn exportPrivateKey(allocator: std.mem.Allocator, privateKey: *const PrivateKey, format: KeyFormat) ![]u8 {
    const der = try asn1.encodePrivateKeyInfo(allocator, privateKey.components);
    if (format == .der) {
        return der;
    }
    return pem.encode(allocator, "PRIVATE KEY", der);
}

//
// Encrypts data with a public key using RSA-OAEP with SHA-1 (node:crypto publicEncrypt with default options).
//
pub fn publicEncrypt(allocator: std.mem.Allocator, io: std.Io, publicKey: *const PublicKey, data: []const u8) ![]u8 {
    return rsa.publicEncrypt(allocator, io, publicKey, data) catch |err| {
        return switch (err) {
            error.DataTooLarge => errors.throwError("error:0200006E:rsa routines::data too large for key size", .{}),
            else => err,
        };
    };
}

//
// Decrypts data with a private key using RSA-OAEP with SHA-1 (node:crypto privateDecrypt with default options).
//
pub fn privateDecrypt(allocator: std.mem.Allocator, privateKey: *const PrivateKey, data: []const u8) ![]u8 {
    return rsa.privateDecrypt(allocator, privateKey, data) catch |err| {
        return switch (err) {
            error.InvalidInputLength => errors.throwError("error:0200006C:rsa routines::data greater than mod len", .{}),
            error.DataGreaterThanModulus => errors.throwError("error:02000084:rsa routines::data too large for modulus", .{}),
            error.OaepDecodingError => errors.throwError("error:02000079:rsa routines::oaep decoding error", .{}),
            else => err,
        };
    };
}

//
// Checks the algorithm, key and IV passed to createCipheriv/createDecipheriv.
//
fn checkCipherArguments(algorithm: []const u8, key: []const u8, iv: []const u8) !void {
    if (!std.mem.eql(u8, algorithm, "aes-256-cbc")) {
        return errors.throwError("Invalid cipher type", .{});
    }
    if (key.len != aes_cbc.key_length) {
        return errors.throwError("Invalid key length", .{});
    }
    if (iv.len != aes_cbc.block_length) {
        return errors.throwError("Invalid initialization vector", .{});
    }
}

//
// An AES-256-CBC encryption in progress (node:crypto Cipher).
//
pub const Cipher = struct {
    // The CBC state.
    encryptor: aes_cbc.CbcEncryptor,

    //
    // Encrypts data and appends the ciphertext produced so far to the output (like cipher.update, but
    // appending to a list so that streams can reuse one buffer).
    //
    pub fn updateInto(self: *Cipher, allocator: std.mem.Allocator, output: *std.ArrayList(u8), data: []const u8) !void {
        try self.encryptor.update(allocator, output, data);
    }

    //
    // Pads and appends the last block to the output (like cipher.final).
    //
    pub fn finalInto(self: *Cipher, allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
        try self.encryptor.final(allocator, output);
    }

    //
    // Encrypts data and returns the ciphertext produced so far (cipher.update).
    //
    pub fn update(self: *Cipher, allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        try self.updateInto(allocator, &output, data);
        return output.toOwnedSlice(allocator);
    }

    //
    // Returns the last, padded block (cipher.final).
    //
    pub fn final(self: *Cipher, allocator: std.mem.Allocator) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        try self.finalInto(allocator, &output);
        return output.toOwnedSlice(allocator);
    }
};

//
// An AES-256-CBC decryption in progress (node:crypto Decipher).
//
pub const Decipher = struct {
    // The CBC state.
    decryptor: aes_cbc.CbcDecryptor,

    //
    // Decrypts data and appends the plaintext produced so far to the output (like decipher.update).
    //
    pub fn updateInto(self: *Decipher, allocator: std.mem.Allocator, output: *std.ArrayList(u8), data: []const u8) !void {
        try self.decryptor.update(allocator, output, data);
    }

    //
    // Decrypts the last block, removes the padding and appends the rest to the output (like decipher.final).
    //
    pub fn finalInto(self: *Decipher, allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
        self.decryptor.final(allocator, output) catch |err| {
            return switch (err) {
                error.WrongFinalBlockLength => errors.throwError("error:1C80006B:Provider routines::wrong final block length", .{}),
                error.BadDecrypt => errors.throwError("error:1C800064:Provider routines::bad decrypt", .{}),
                else => err,
            };
        };
    }

    //
    // Decrypts data and returns the plaintext produced so far (decipher.update).
    //
    pub fn update(self: *Decipher, allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        try self.updateInto(allocator, &output, data);
        return output.toOwnedSlice(allocator);
    }

    //
    // Returns the rest of the plaintext without padding (decipher.final).
    //
    pub fn final(self: *Decipher, allocator: std.mem.Allocator) ![]u8 {
        var output: std.ArrayList(u8) = .empty;
        try self.finalInto(allocator, &output);
        return output.toOwnedSlice(allocator);
    }
};

//
// Creates an AES-256-CBC cipher (node:crypto createCipheriv). Only "aes-256-cbc" is supported.
//
pub fn createCipheriv(algorithm: []const u8, key: []const u8, iv: []const u8) !Cipher {
    try checkCipherArguments(algorithm, key, iv);
    return Cipher{ .encryptor = aes_cbc.CbcEncryptor.init(key[0..aes_cbc.key_length].*, iv[0..aes_cbc.block_length].*) };
}

//
// Creates an AES-256-CBC decipher (node:crypto createDecipheriv). Only "aes-256-cbc" is supported.
//
pub fn createDecipheriv(algorithm: []const u8, key: []const u8, iv: []const u8) !Decipher {
    try checkCipherArguments(algorithm, key, iv);
    return Decipher{ .decryptor = aes_cbc.CbcDecryptor.init(key[0..aes_cbc.key_length].*, iv[0..aes_cbc.block_length].*) };
}
