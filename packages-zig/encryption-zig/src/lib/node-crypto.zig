const std = @import("std");
const utils = @import("utils-zig");
const c = @import("openssl");

//
// The subset of node:crypto that the encryption package uses, so that the ported files read like the TypeScript.
// This file has no TypeScript counterpart (node:crypto is part of Node, over OpenSSL): it calls aws-lc's libcrypto,
// built from the upstream release by aws/aws-lc.zig. Error messages match the OpenSSL 3 messages that Node reports
// for the same failures.
//

//
// Names used from other files (the equivalent of the TypeScript imports).
//
const errors = utils.errors;

//
// The largest number of bytes passed to one EVP_EncryptUpdate or EVP_DecryptUpdate call (their lengths are ints).
//
const max_update_length: usize = 1 << 30;

//
// The AES block length in bytes (also the CBC IV length).
//
const aes_block_length: usize = 16;

//
// An RSA public key (node:crypto KeyObject of type 'public'). The key is kept as its DER SubjectPublicKeyInfo in
// memory from the allocator it was created with, and parsed into a libcrypto EVP_PKEY for each operation, so nothing
// has to be freed.
//
pub const PublicKey = struct {
    // The DER SubjectPublicKeyInfo (KeyObject.export({ type: 'spki', format: 'der' })).
    spki: []const u8,

    // The length of the modulus in bytes.
    modulus_length: usize,

    //
    // The length of the modulus in bytes (KeyObject.asymmetricKeyDetails.modulusLength / 8).
    //
    pub fn modulusLength(self: *const PublicKey) usize {
        return self.modulus_length;
    }
};

//
// An RSA private key (node:crypto KeyObject of type 'private'), kept as its DER PKCS#8 PrivateKeyInfo like PublicKey.
//
pub const PrivateKey = struct {
    // The DER PKCS#8 PrivateKeyInfo (KeyObject.export({ type: 'pkcs8', format: 'der' })).
    pkcs8: []const u8,

    // The public half of the key.
    public_key: PublicKey,
};

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
// Throws the error Node reports for key data it cannot decode.
//
fn throwUnsupportedKey() errors.ThrownError {
    c.ERR_clear_error();
    return errors.throwError("error:1E08010C:DECODER routines::unsupported", .{});
}

//
// Takes the oldest error off libcrypto's error queue (0 when there is none) and clears the rest, so that the next
// operation starts with an empty queue.
//
fn takeLibraryError() u32 {
    const packedError = c.ERR_get_error();
    c.ERR_clear_error();
    return packedError;
}

//
// Throws a packed libcrypto error with the library's own text (for failures Node has no specific message for).
//
fn throwPackedError(packedError: u32, operation: []const u8) errors.ThrownError {
    if (packedError == 0) {
        return errors.throwError("{s} failed", .{operation});
    }
    var text: [256]u8 = undefined;
    _ = c.ERR_error_string_n(packedError, &text, text.len);
    return errors.throwError("{s}", .{std.mem.sliceTo(&text, 0)});
}

//
// Throws the oldest error on libcrypto's error queue with the library's own text, and clears the queue.
//
fn throwLibraryError(operation: []const u8) errors.ThrownError {
    return throwPackedError(takeLibraryError(), operation);
}

//
// True when a packed libcrypto error is the given reason of the given library.
//
fn isLibraryError(packedError: u32, library: c_int, reason: c_int) bool {
    return c.ERR_GET_LIB(packedError) == library and c.ERR_GET_REASON(packedError) == reason;
}

//
// Copies memory that libcrypto allocated into memory from the allocator, and frees the libcrypto copy.
//
fn takeLibraryBytes(allocator: std.mem.Allocator, bytes: [*c]u8, length: c_int) ![]u8 {
    defer c.OPENSSL_free(bytes);
    return allocator.dupe(u8, bytes[0..@intCast(length)]);
}

//
// Creates a read-only memory BIO over text.
//
fn openMemoryBio(text: []const u8) !*c.BIO {
    const length = std.math.cast(c.ossl_ssize_t, text.len) orelse {
        return throwUnsupportedKey();
    };
    return c.BIO_new_mem_buf(text.ptr, length) orelse {
        return throwLibraryError("BIO_new_mem_buf");
    };
}

//
// Creates an empty, writable memory BIO.
//
fn createMemoryBio() !*c.BIO {
    return c.BIO_new(c.BIO_s_mem()) orelse {
        return throwLibraryError("BIO_new");
    };
}

//
// Copies what was written to a memory BIO into memory from the allocator.
//
fn memoryBioContents(allocator: std.mem.Allocator, bio: *c.BIO) ![]u8 {
    var contents: [*c]const u8 = null;
    var length: usize = 0;
    if (c.BIO_mem_contents(bio, &contents, &length) != 1) {
        return throwLibraryError("BIO_mem_contents");
    }
    return allocator.dupe(u8, contents[0..length]);
}

//
// A password callback that supplies no passphrase, so that reading an encrypted PEM key fails instead of prompting
// on the terminal (Node fails the same way when no passphrase is given).
//
fn noPassphrase(buffer: [*c]u8, size: c_int, writing: c_int, userData: ?*anyopaque) callconv(.c) c_int {
    _ = buffer;
    _ = size;
    _ = writing;
    _ = userData;
    return -1;
}

//
// Encodes the public half of a key as DER SubjectPublicKeyInfo (i2d_PUBKEY).
//
fn encodeSpki(allocator: std.mem.Allocator, key: *c.EVP_PKEY) ![]u8 {
    var der: [*c]u8 = null;
    const length = c.i2d_PUBKEY(key, &der);
    if (length <= 0) {
        return throwLibraryError("i2d_PUBKEY");
    }
    return takeLibraryBytes(allocator, der, length);
}

//
// Encodes a private key as DER PKCS#8 PrivateKeyInfo (EVP_PKEY2PKCS8 and i2d_PKCS8_PRIV_KEY_INFO).
//
fn encodePkcs8(allocator: std.mem.Allocator, key: *c.EVP_PKEY) ![]u8 {
    const info = c.EVP_PKEY2PKCS8(key) orelse {
        return throwLibraryError("EVP_PKEY2PKCS8");
    };
    defer c.PKCS8_PRIV_KEY_INFO_free(info);
    var der: [*c]u8 = null;
    const length = c.i2d_PKCS8_PRIV_KEY_INFO(info, &der);
    if (length <= 0) {
        return throwLibraryError("i2d_PKCS8_PRIV_KEY_INFO");
    }
    return takeLibraryBytes(allocator, der, length);
}

//
// Makes a PublicKey from a parsed RSA key.
//
fn makePublicKey(allocator: std.mem.Allocator, key: *c.EVP_PKEY) !PublicKey {
    return PublicKey{
        .spki = try encodeSpki(allocator, key),
        .modulus_length = @intCast(c.EVP_PKEY_size(key)),
    };
}

//
// Parses a public key into a libcrypto key (d2i_PUBKEY). The caller frees it with EVP_PKEY_free.
//
fn parsePublicKey(publicKey: *const PublicKey) !*c.EVP_PKEY {
    var input: [*c]const u8 = publicKey.spki.ptr;
    return c.d2i_PUBKEY(null, &input, @intCast(publicKey.spki.len)) orelse {
        return throwLibraryError("d2i_PUBKEY");
    };
}

//
// Parses a private key into a libcrypto key (d2i_AutoPrivateKey). The caller frees it with EVP_PKEY_free.
//
fn parsePrivateKey(privateKey: *const PrivateKey) !*c.EVP_PKEY {
    var input: [*c]const u8 = privateKey.pkcs8.ptr;
    return c.d2i_AutoPrivateKey(null, &input, @intCast(privateKey.pkcs8.len)) orelse {
        return throwLibraryError("d2i_AutoPrivateKey");
    };
}

//
// Writes a public key as SPKI PEM (PEM_write_bio_PUBKEY).
//
fn writePublicKeyPem(allocator: std.mem.Allocator, key: *c.EVP_PKEY) ![]u8 {
    const bio = try createMemoryBio();
    defer _ = c.BIO_free(bio);
    if (c.PEM_write_bio_PUBKEY(bio, key) != 1) {
        return throwLibraryError("PEM_write_bio_PUBKEY");
    }
    return memoryBioContents(allocator, bio);
}

//
// Writes a private key as unencrypted PKCS#8 PEM (PEM_write_bio_PKCS8PrivateKey).
//
fn writePrivateKeyPem(allocator: std.mem.Allocator, key: *c.EVP_PKEY) ![]u8 {
    const bio = try createMemoryBio();
    defer _ = c.BIO_free(bio);
    if (c.PEM_write_bio_PKCS8PrivateKey(bio, key, null, null, 0, null, null) != 1) {
        return throwLibraryError("PEM_write_bio_PKCS8PrivateKey");
    }
    return memoryBioContents(allocator, bio);
}

//
// Fills a buffer with cryptographically strong random bytes (node:crypto randomBytes), from libcrypto's RAND_bytes.
//
pub fn randomBytes(io: std.Io, buffer: []u8) void {
    _ = io;
    // RAND_bytes always succeeds: it aborts the process rather than return without random bytes.
    std.debug.assert(c.RAND_bytes(buffer.ptr, buffer.len) == 1);
}

//
// Generates an RSA key pair and returns it as PEM (generateKeyPairSync('rsa', { modulusLength,
// publicKeyEncoding: { type: 'spki', format: 'pem' }, privateKeyEncoding: { type: 'pkcs8', format: 'pem' } }),
// with Node's default public exponent 0x10001).
//
pub fn generateKeyPairSync(allocator: std.mem.Allocator, io: std.Io, modulusLength: usize) !GeneratedKeyPairPem {
    _ = io;
    const bits = std.math.cast(c_int, modulusLength) orelse {
        return errors.throwError("modulusLength {d} is too large", .{modulusLength});
    };
    const context = c.EVP_PKEY_CTX_new_id(c.EVP_PKEY_RSA, null) orelse {
        return throwLibraryError("EVP_PKEY_CTX_new_id");
    };
    defer c.EVP_PKEY_CTX_free(context);
    if (c.EVP_PKEY_keygen_init(context) != 1) {
        return throwLibraryError("EVP_PKEY_keygen_init");
    }
    if (c.EVP_PKEY_CTX_set_rsa_keygen_bits(context, bits) != 1) {
        return throwLibraryError("EVP_PKEY_CTX_set_rsa_keygen_bits");
    }
    const exponent = c.BN_new() orelse {
        return throwLibraryError("BN_new");
    };
    // node:crypto's default publicExponent.
    if (c.BN_set_word(exponent, 0x10001) != 1) {
        c.BN_free(exponent);
        return throwLibraryError("BN_set_word");
    }
    // On success the context takes ownership of the exponent.
    if (c.EVP_PKEY_CTX_set_rsa_keygen_pubexp(context, exponent) != 1) {
        c.BN_free(exponent);
        return throwLibraryError("EVP_PKEY_CTX_set_rsa_keygen_pubexp");
    }
    var key: ?*c.EVP_PKEY = null;
    if (c.EVP_PKEY_keygen(context, &key) != 1) {
        return throwLibraryError("EVP_PKEY_keygen");
    }
    defer c.EVP_PKEY_free(key);
    return GeneratedKeyPairPem{
        .publicKey = try writePublicKeyPem(allocator, key.?),
        .privateKey = try writePrivateKeyPem(allocator, key.?),
    };
}

//
// TODO: a key that is not RSA is refused when it is loaded, where node:crypto accepts it and encryption fails
// later with OpenSSL's message.
//
// Makes a PrivateKey from a parsed key, which must be RSA.
//
fn makePrivateKey(allocator: std.mem.Allocator, key: *c.EVP_PKEY) !*const PrivateKey {
    if (c.EVP_PKEY_id(key) != c.EVP_PKEY_RSA) {
        return throwUnsupportedKey();
    }
    const privateKey = try allocator.create(PrivateKey);
    privateKey.* = PrivateKey{
        .pkcs8 = try encodePkcs8(allocator, key),
        .public_key = try makePublicKey(allocator, key),
    };
    return privateKey;
}

//
// Creates a private key from PEM text (node:crypto createPrivateKey), with PEM_read_bio_PrivateKey. Accepts
// unencrypted PKCS#8 ("PRIVATE KEY") and PKCS#1 ("RSA PRIVATE KEY") RSA keys.
//
pub fn createPrivateKey(allocator: std.mem.Allocator, keyPem: []const u8) !*const PrivateKey {
    c.ERR_clear_error();
    const bio = try openMemoryBio(keyPem);
    defer _ = c.BIO_free(bio);
    const key = c.PEM_read_bio_PrivateKey(bio, null, &noPassphrase, null) orelse {
        return throwUnsupportedKey();
    };
    defer c.EVP_PKEY_free(key);
    return makePrivateKey(allocator, key);
}

//
// Reads an RSA public key from PEM text: SPKI ("PUBLIC KEY", PEM_read_bio_PUBKEY) or PKCS#1 ("RSA PUBLIC KEY",
// PEM_read_bio_RSAPublicKey). Returns null when the text has neither. The caller frees the key with EVP_PKEY_free.
//
fn readPublicKeyPem(keyPem: []const u8) !?*c.EVP_PKEY {
    const spkiBio = try openMemoryBio(keyPem);
    defer _ = c.BIO_free(spkiBio);
    if (c.PEM_read_bio_PUBKEY(spkiBio, null, &noPassphrase, null)) |key| {
        return key;
    }
    c.ERR_clear_error();

    const pkcs1Bio = try openMemoryBio(keyPem);
    defer _ = c.BIO_free(pkcs1Bio);
    const rsaKey = c.PEM_read_bio_RSAPublicKey(pkcs1Bio, null, &noPassphrase, null) orelse {
        c.ERR_clear_error();
        return null;
    };
    const key = c.EVP_PKEY_new() orelse {
        c.RSA_free(rsaKey);
        return throwLibraryError("EVP_PKEY_new");
    };
    // On success the key takes ownership of the RSA key.
    if (c.EVP_PKEY_assign_RSA(key, rsaKey) != 1) {
        c.RSA_free(rsaKey);
        c.EVP_PKEY_free(key);
        return throwLibraryError("EVP_PKEY_assign_RSA");
    }
    return key;
}

//
// Creates a public key from PEM text (node:crypto createPublicKey). Accepts SPKI ("PUBLIC KEY") and
// PKCS#1 ("RSA PUBLIC KEY") RSA keys, and private key PEMs (the public half is returned, like Node).
//
pub fn createPublicKey(allocator: std.mem.Allocator, keyPem: []const u8) !*const PublicKey {
    c.ERR_clear_error();
    const key = try readPublicKeyPem(keyPem) orelse {
        const privateKey = try createPrivateKey(allocator, keyPem);
        return createPublicKeyFromPrivateKey(privateKey);
    };
    defer c.EVP_PKEY_free(key);
    if (c.EVP_PKEY_id(key) != c.EVP_PKEY_RSA) {
        return throwUnsupportedKey();
    }
    const publicKey = try allocator.create(PublicKey);
    publicKey.* = try makePublicKey(allocator, key);
    return publicKey;
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
    if (format == .der) {
        return allocator.dupe(u8, publicKey.spki);
    }
    const key = try parsePublicKey(publicKey);
    defer c.EVP_PKEY_free(key);
    return writePublicKeyPem(allocator, key);
}

//
// Exports a private key as PKCS#8 (KeyObject.export({ type: 'pkcs8', format })).
//
pub fn exportPrivateKey(allocator: std.mem.Allocator, privateKey: *const PrivateKey, format: KeyFormat) ![]u8 {
    if (format == .der) {
        return allocator.dupe(u8, privateKey.pkcs8);
    }
    const key = try parsePrivateKey(privateKey);
    defer c.EVP_PKEY_free(key);
    return writePrivateKeyPem(allocator, key);
}

//
// Sets RSA-OAEP with SHA-1 for both the OAEP hash and MGF1 on an encryption or decryption context: the padding
// node:crypto's publicEncrypt and privateDecrypt use by default (RSA_PKCS1_OAEP_PADDING, oaepHash 'sha1').
//
fn setOaepPadding(context: *c.EVP_PKEY_CTX) !void {
    if (c.EVP_PKEY_CTX_set_rsa_padding(context, c.RSA_PKCS1_OAEP_PADDING) != 1) {
        return throwLibraryError("EVP_PKEY_CTX_set_rsa_padding");
    }
    if (c.EVP_PKEY_CTX_set_rsa_oaep_md(context, c.EVP_sha1()) != 1) {
        return throwLibraryError("EVP_PKEY_CTX_set_rsa_oaep_md");
    }
    if (c.EVP_PKEY_CTX_set_rsa_mgf1_md(context, c.EVP_sha1()) != 1) {
        return throwLibraryError("EVP_PKEY_CTX_set_rsa_mgf1_md");
    }
}

//
// Encrypts data with a public key using RSA-OAEP with SHA-1 (node:crypto publicEncrypt with default options).
//
pub fn publicEncrypt(allocator: std.mem.Allocator, io: std.Io, publicKey: *const PublicKey, data: []const u8) ![]u8 {
    _ = io;
    c.ERR_clear_error();
    const key = try parsePublicKey(publicKey);
    defer c.EVP_PKEY_free(key);
    const context = c.EVP_PKEY_CTX_new(key, null) orelse {
        return throwLibraryError("EVP_PKEY_CTX_new");
    };
    defer c.EVP_PKEY_CTX_free(context);
    if (c.EVP_PKEY_encrypt_init(context) != 1) {
        return throwLibraryError("EVP_PKEY_encrypt_init");
    }
    try setOaepPadding(context);
    var outputLength: usize = 0;
    if (c.EVP_PKEY_encrypt(context, null, &outputLength, data.ptr, data.len) != 1) {
        return throwLibraryError("EVP_PKEY_encrypt");
    }
    const output = try allocator.alloc(u8, outputLength);
    if (c.EVP_PKEY_encrypt(context, output.ptr, &outputLength, data.ptr, data.len) != 1) {
        const packedError = takeLibraryError();
        if (isLibraryError(packedError, c.ERR_LIB_RSA, c.RSA_R_DATA_TOO_LARGE_FOR_KEY_SIZE)) {
            return errors.throwError("error:0200006E:rsa routines::data too large for key size", .{});
        }
        return throwPackedError(packedError, "EVP_PKEY_encrypt");
    }
    return output[0..outputLength];
}

//
// Decrypts data with a private key using RSA-OAEP with SHA-1 (node:crypto privateDecrypt with default options).
//
// OpenSSL 3, under Node, reads the ciphertext as a big-endian number: one longer than the modulus is refused, and a
// shorter one is the same number as when it is padded with leading zeros. libcrypto only takes a ciphertext exactly
// as long as the modulus, so a shorter one is padded here, which gives the error Node reports for it.
//
pub fn privateDecrypt(allocator: std.mem.Allocator, privateKey: *const PrivateKey, data: []const u8) ![]u8 {
    const modulusLength = privateKey.public_key.modulus_length;
    if (data.len > modulusLength) {
        return errors.throwError("error:0200006C:rsa routines::data greater than mod len", .{});
    }
    const ciphertext = try allocator.alloc(u8, modulusLength);
    @memset(ciphertext[0 .. modulusLength - data.len], 0);
    @memcpy(ciphertext[modulusLength - data.len ..], data);

    c.ERR_clear_error();
    const key = try parsePrivateKey(privateKey);
    defer c.EVP_PKEY_free(key);
    const context = c.EVP_PKEY_CTX_new(key, null) orelse {
        return throwLibraryError("EVP_PKEY_CTX_new");
    };
    defer c.EVP_PKEY_CTX_free(context);
    if (c.EVP_PKEY_decrypt_init(context) != 1) {
        return throwLibraryError("EVP_PKEY_decrypt_init");
    }
    try setOaepPadding(context);
    var outputLength: usize = modulusLength;
    const output = try allocator.alloc(u8, outputLength);
    if (c.EVP_PKEY_decrypt(context, output.ptr, &outputLength, ciphertext.ptr, ciphertext.len) != 1) {
        const packedError = takeLibraryError();
        if (isLibraryError(packedError, c.ERR_LIB_RSA, c.RSA_R_DATA_TOO_LARGE_FOR_MODULUS)) {
            return errors.throwError("error:02000084:rsa routines::data too large for modulus", .{});
        }
        if (isLibraryError(packedError, c.ERR_LIB_RSA, c.RSA_R_OAEP_DECODING_ERROR)) {
            return errors.throwError("error:02000079:rsa routines::oaep decoding error", .{});
        }
        return throwPackedError(packedError, "EVP_PKEY_decrypt");
    }
    return output[0..outputLength];
}

//
// Checks the algorithm, key and IV passed to createCipheriv/createDecipheriv.
//
fn checkCipherArguments(algorithm: []const u8, key: []const u8, iv: []const u8) !void {
    if (!std.mem.eql(u8, algorithm, "aes-256-cbc")) {
        return errors.throwError("Invalid cipher type", .{});
    }
    // AES-256 takes a 32-byte key.
    if (key.len != 32) {
        return errors.throwError("Invalid key length", .{});
    }
    if (iv.len != aes_block_length) {
        return errors.throwError("Invalid initialization vector", .{});
    }
}

//
// Creates a libcrypto AES-256-CBC context for encryption or decryption, with PKCS#7 padding (EVP_CipherInit_ex).
//
fn createCipherContext(key: []const u8, iv: []const u8, encrypt: bool) !*c.EVP_CIPHER_CTX {
    const context = c.EVP_CIPHER_CTX_new() orelse {
        return throwLibraryError("EVP_CIPHER_CTX_new");
    };
    if (c.EVP_CipherInit_ex(context, c.EVP_aes_256_cbc(), null, key.ptr, iv.ptr, @intFromBool(encrypt)) != 1) {
        c.EVP_CIPHER_CTX_free(context);
        return throwLibraryError("EVP_CipherInit_ex");
    }
    return context;
}

//
// Runs data through a cipher context and appends the output to a list (EVP_CipherUpdate), in pieces short enough for
// its int lengths.
//
fn cipherUpdate(context: *c.EVP_CIPHER_CTX, allocator: std.mem.Allocator, output: *std.ArrayList(u8), data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        const piece = data[offset..@min(data.len, offset + max_update_length)];
        // An update writes at most the input and one block that was held back.
        const room = try output.addManyAsSlice(allocator, piece.len + aes_block_length);
        var written: c_int = 0;
        if (c.EVP_CipherUpdate(context, room.ptr, &written, piece.ptr, @intCast(piece.len)) != 1) {
            output.shrinkRetainingCapacity(output.items.len - room.len);
            return throwLibraryError("EVP_CipherUpdate");
        }
        output.shrinkRetainingCapacity(output.items.len - room.len + @as(usize, @intCast(written)));
        offset += piece.len;
    }
}

//
// Finishes a cipher context, appends the last block to a list (EVP_CipherFinal_ex) and frees the context. Returns
// the packed libcrypto error when it fails (0 on success).
//
fn cipherFinal(context: *c.EVP_CIPHER_CTX, allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !u32 {
    defer c.EVP_CIPHER_CTX_free(context);
    const room = try output.addManyAsSlice(allocator, aes_block_length);
    var written: c_int = 0;
    if (c.EVP_CipherFinal_ex(context, room.ptr, &written) != 1) {
        output.shrinkRetainingCapacity(output.items.len - room.len);
        const packedError = takeLibraryError();
        if (packedError == 0) {
            return throwLibraryError("EVP_CipherFinal_ex");
        }
        return packedError;
    }
    output.shrinkRetainingCapacity(output.items.len - room.len + @as(usize, @intCast(written)));
    return 0;
}

//
// Throws the error Node reports for a cipher used after final (ERR_CRYPTO_INVALID_STATE).
//
fn throwFinalized(operation: []const u8) errors.ThrownError {
    return errors.throwError("Invalid state for operation {s}", .{operation});
}

//
// An AES-256-CBC encryption in progress (node:crypto Cipher), over a libcrypto EVP_CIPHER_CTX. final frees the
// context; a cipher that is dropped before final is freed with deinit.
//
pub const Cipher = struct {
    // The libcrypto context, null once final has run.
    context: ?*c.EVP_CIPHER_CTX,

    //
    // Encrypts data and appends the ciphertext produced so far to the output (like cipher.update, but
    // appending to a list so that streams can reuse one buffer).
    //
    pub fn updateInto(self: *Cipher, allocator: std.mem.Allocator, output: *std.ArrayList(u8), data: []const u8) !void {
        const context = self.context orelse {
            return throwFinalized("update");
        };
        try cipherUpdate(context, allocator, output, data);
    }

    //
    // Pads and appends the last block to the output (like cipher.final).
    //
    pub fn finalInto(self: *Cipher, allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
        const context = self.context orelse {
            return throwFinalized("final");
        };
        self.context = null;
        const packedError = try cipherFinal(context, allocator, output);
        if (packedError != 0) {
            return throwPackedError(packedError, "EVP_CipherFinal_ex");
        }
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

    //
    // Frees the libcrypto context of a cipher that final has not run on (nothing to do after final).
    //
    pub fn deinit(self: *Cipher) void {
        if (self.context) |context| {
            c.EVP_CIPHER_CTX_free(context);
            self.context = null;
        }
    }
};

//
// An AES-256-CBC decryption in progress (node:crypto Decipher), over a libcrypto EVP_CIPHER_CTX. final frees the
// context; a decipher that is dropped before final is freed with deinit.
//
pub const Decipher = struct {
    // The libcrypto context, null once final has run.
    context: ?*c.EVP_CIPHER_CTX,

    //
    // Decrypts data and appends the plaintext produced so far to the output (like decipher.update).
    //
    pub fn updateInto(self: *Decipher, allocator: std.mem.Allocator, output: *std.ArrayList(u8), data: []const u8) !void {
        const context = self.context orelse {
            return throwFinalized("update");
        };
        try cipherUpdate(context, allocator, output, data);
    }

    //
    // Decrypts the last block, removes the padding and appends the rest to the output (like decipher.final).
    //
    pub fn finalInto(self: *Decipher, allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
        const context = self.context orelse {
            return throwFinalized("final");
        };
        self.context = null;
        const packedError = try cipherFinal(context, allocator, output);
        if (packedError == 0) {
            return;
        }
        if (isLibraryError(packedError, c.ERR_LIB_CIPHER, c.CIPHER_R_WRONG_FINAL_BLOCK_LENGTH)) {
            return errors.throwError("error:1C80006B:Provider routines::wrong final block length", .{});
        }
        if (isLibraryError(packedError, c.ERR_LIB_CIPHER, c.CIPHER_R_BAD_DECRYPT)) {
            return errors.throwError("error:1C800064:Provider routines::bad decrypt", .{});
        }
        return throwPackedError(packedError, "EVP_CipherFinal_ex");
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

    //
    // Frees the libcrypto context of a decipher that final has not run on (nothing to do after final).
    //
    pub fn deinit(self: *Decipher) void {
        if (self.context) |context| {
            c.EVP_CIPHER_CTX_free(context);
            self.context = null;
        }
    }
};

//
// Creates an AES-256-CBC cipher (node:crypto createCipheriv). Only "aes-256-cbc" is supported.
//
pub fn createCipheriv(algorithm: []const u8, key: []const u8, iv: []const u8) !Cipher {
    try checkCipherArguments(algorithm, key, iv);
    return Cipher{ .context = try createCipherContext(key, iv, true) };
}

//
// Creates an AES-256-CBC decipher (node:crypto createDecipheriv). Only "aes-256-cbc" is supported.
//
pub fn createDecipheriv(algorithm: []const u8, key: []const u8, iv: []const u8) !Decipher {
    try checkCipherArguments(algorithm, key, iv);
    return Decipher{ .context = try createCipherContext(key, iv, false) };
}

//
// A signature being built (node:crypto Sign, from createSign): the data given to update is signed by sign.
// Only "SHA256" is supported, with the RSA PKCS#1 v1.5 padding Node uses for an RSA key by default.
//
pub const Sign = struct {
    // Allocates the data collected by update.
    allocator: std.mem.Allocator,

    // The data given to update so far.
    data: std.ArrayList(u8),

    //
    // Adds data to sign (Sign.update).
    //
    pub fn update(self: *Sign, data: []const u8) !void {
        try self.data.appendSlice(self.allocator, data);
    }

    //
    // Signs the data with a private key given as PEM text and returns the signature (Sign.sign(privateKeyPem)).
    //
    pub fn sign(self: *Sign, allocator: std.mem.Allocator, privateKeyPem: []const u8) ![]u8 {
        c.ERR_clear_error();
        const bio = try openMemoryBio(privateKeyPem);
        defer _ = c.BIO_free(bio);
        const key = c.PEM_read_bio_PrivateKey(bio, null, &noPassphrase, null) orelse {
            return throwUnsupportedKey();
        };
        defer c.EVP_PKEY_free(key);
        const context = c.EVP_MD_CTX_new() orelse {
            return throwLibraryError("EVP_MD_CTX_new");
        };
        defer c.EVP_MD_CTX_free(context);
        // Node refuses a key that signs in one go (Ed25519) before it starts, and gives the error of OpenSSL 3 for a key
        // of a type that cannot sign (X25519).
        if (c.EVP_PKEY_id(key) == c.EVP_PKEY_ED25519) {
            return errors.throwError("Unsupported crypto operation", .{});
        }
        if (c.EVP_DigestSignInit(context, null, c.EVP_sha256(), null, key) != 1) {
            c.ERR_clear_error();
            return errors.throwError("error:03000096:digital envelope routines::operation not supported for this keytype", .{});
        }
        var signatureLength: usize = 0;
        if (c.EVP_DigestSign(context, null, &signatureLength, self.data.items.ptr, self.data.items.len) != 1) {
            return throwLibraryError("EVP_DigestSign");
        }
        const signature = try allocator.alloc(u8, signatureLength);
        if (c.EVP_DigestSign(context, signature.ptr, &signatureLength, self.data.items.ptr, self.data.items.len) != 1) {
            return throwLibraryError("EVP_DigestSign");
        }
        return signature[0..signatureLength];
    }
};

//
// Creates a Sign object for the digest algorithm (node:crypto createSign). Only "SHA256" is supported.
//
pub fn createSign(allocator: std.mem.Allocator, algorithm: []const u8) !Sign {
    if (!std.mem.eql(u8, algorithm, "SHA256")) {
        return errors.throwError("Invalid digest: {s}", .{algorithm});
    }
    return .{
        .allocator = allocator,
        .data = .empty,
    };
}
