const std = @import("std");
const utils = @import("utils-zig");
const crypto = @import("node-crypto.zig");
const constants = @import("encryption-constants.zig");
const key_utils = @import("key-utils.zig");
const encryption_types = @import("encryption-types.zig");

//
// Names used from other files (the equivalent of the TypeScript imports).
//
const errors = utils.errors;
const log = utils.log;
const hashPublicKey = key_utils.hashPublicKey;
const IPrivateKeyMap = encryption_types.IPrivateKeyMap;
const ENCRYPTION_TAG = constants.ENCRYPTION_TAG;
const ENCRYPTION_FORMAT_VERSION = constants.ENCRYPTION_FORMAT_VERSION;
const ENCRYPTION_TYPE = constants.ENCRYPTION_TYPE;
const LEGACY_HEADER_LENGTH = constants.LEGACY_HEADER_LENGTH;
const WRAPPED_KEY_LENGTH = constants.WRAPPED_KEY_LENGTH;
const NEW_FORMAT_HEADER_LENGTH = constants.NEW_FORMAT_HEADER_LENGTH;
const PUBLIC_KEY_HASH_LENGTH = constants.PUBLIC_KEY_HASH_LENGTH;
const SUPPORTED_TYPES = constants.SUPPORTED_TYPES;
const SUPPORTED_VERSIONS = constants.SUPPORTED_VERSIONS;

//
// Encrypts a buffer using a public key. Always writes the new format (tag, version, type, keyHash + payload).
//
pub fn encryptBuffer(allocator: std.mem.Allocator, io: std.Io, publicKey: *const crypto.PublicKey, data: []const u8) ![]u8 {
    var key: [32]u8 = undefined;
    crypto.randomBytes(io, &key);
    var iv: [16]u8 = undefined;
    crypto.randomBytes(io, &iv);
    var cipher = try crypto.createCipheriv("aes-256-cbc", &key, &iv);
    const encrypted = try std.mem.concat(allocator, u8, &.{ try cipher.update(allocator, data), try cipher.final(allocator) });
    const encryptedKey = try crypto.publicEncrypt(allocator, io, publicKey, &key);
    try requireWrappableKey(encryptedKey.len);
    const payload = try std.mem.concat(allocator, u8, &.{ encryptedKey, &iv, encrypted });

    const version = ENCRYPTION_FORMAT_VERSION;
    const encType = ENCRYPTION_TYPE;
    const keyHash = try hashPublicKey(allocator, publicKey);

    var header: [NEW_FORMAT_HEADER_LENGTH]u8 = undefined;
    @memcpy(header[0..4], ENCRYPTION_TAG);
    std.mem.writeInt(u32, header[4..8], version, .little);
    @memcpy(header[8..12], encType);
    @memcpy(header[12..], &keyHash);

    return std.mem.concat(allocator, u8, &.{ &header, payload });
}

//
// The encryption tag as bytes.
//
const TAG_BYTES = ENCRYPTION_TAG;

//
// Refuses a wrapped key that the readers could not slice back out of the file.
//
// Checked at the write, where the wrapped key has just been produced and its length is free to read,
// rather than where a key is loaded: this is the one check that works everywhere, because the mobile
// crypto shim's KeyObject carries no key details to inspect and only the wrapped length says what
// size the key really was.
//
// What it prevents is losing the plaintext. Encrypting with a smaller key succeeded and wrote a file
// that no reader here can decrypt, and said nothing at the time; making the read loud does not help,
// because by then the only copy of the data is the unreadable file.
//
pub fn requireWrappableKey(wrappedKeyLength: usize) !void {
    if (wrappedKeyLength != WRAPPED_KEY_LENGTH) {
        return errors.throwError("This encryption key wraps into {d} bytes and the file format requires {d}, which is 4096-bit RSA. Encrypting with it would write files that cannot be decrypted again.", .{ wrappedKeyLength, WRAPPED_KEY_LENGTH });
    }
}

//
// Decrypts a buffer using a key map. Tries in order: new format, legacy format, then returns data
// unchanged, which is how a file that was never encrypted reads back through an encrypted storage.
//
// A file carrying the encryption tag is the exception: it says outright that it is encrypted, so a
// failure to decrypt it is a failure, not evidence that it was plaintext all along. Handing the
// ciphertext back for one of those produces a wrong answer a long way from its cause: the caller
// deserializes the encrypted bytes and reports whatever that happens to look like, which for a
// database file is "Checksum mismatch: expected <the file's last 32 bytes>". That message names
// serialization while the fault is the key, so it sends a reader to the wrong place entirely.
// (The returned slice is `data` itself when the data is returned unchanged.)
//
pub fn decryptBuffer(allocator: std.mem.Allocator, data: []const u8, privateKeyMap: *const IPrivateKeyMap) ![]const u8 {
    if (data.len < 4) {
        return data;
    }

    const carriesEncryptionTag = std.mem.eql(u8, data[0..4], TAG_BYTES);

    //
    // Try to decrypt as new format.
    //
    if (decryptNewFormat(allocator, data, privateKeyMap)) |decrypted| {
        return decrypted;
    }
    else |err| {
        if (err == error.OutOfMemory) {
            return err;
        }
        if (carriesEncryptionTag) {
            // (Zig: a runtime error has no recorded message, so its name is recorded as the cause's message.)
            if (err != error.Thrown and err != error.FatalError) {
                errors.recordError("Error", "{s}", .{@errorName(err)});
            }
            const causeMessage = try allocator.dupe(u8, errors.lastErrorMessage());
            return errors.throwErrorWithCause("Could not decrypt data that says it is encrypted: {s}", .{causeMessage});
        }
        log.log.verbose("decryptBuffer: new format decryption failed, trying legacy");
    }

    //
    // Try to decrypt as legacy format.
    //
    if (privateKeyMap.get("default")) |defaultKey| {
        if (decryptLegacy(allocator, data, defaultKey)) |decrypted| {
            return decrypted;
        }
        else |err| {
            if (err == error.OutOfMemory) {
                return err;
            }
            log.log.verbose("decryptBuffer: legacy decryption failed, returning data unchanged");
        }
    }

    //
    // Assume data is not encrypted.
    //
    return data;
}

//
// Removes NUL characters and surrounding whitespace from the encryption type field
// (TypeScript: .replace(/\0/g, "").trim()).
//
pub fn normalizeEncryptionType(buffer: []u8, field: []const u8) []const u8 {
    var length: usize = 0;
    for (field) |character| {
        if (character != 0) {
            buffer[length] = character;
            length += 1;
        }
    }
    return std.mem.trim(u8, buffer[0..length], &std.ascii.whitespace);
}

//
// Equivalent of JavaScript `strings.includes(value)` for an array of strings.
//
pub fn includesString(strings: []const []const u8, value: []const u8) bool {
    for (strings) |candidate| {
        if (std.mem.eql(u8, candidate, value)) {
            return true;
        }
    }
    return false;
}

//
// Returns bytes [start, end) of a slice, clamped to its length (TypeScript Buffer.slice semantics).
//
fn clampedSlice(data: []const u8, start: usize, end: usize) []const u8 {
    const clampedStart = @min(start, data.len);
    const clampedEnd = @max(clampedStart, @min(end, data.len));
    return data[clampedStart..clampedEnd];
}

//
// Decrypts a buffer in new format (PSEN header + version, type, keyHash + payload).
//
pub fn decryptNewFormat(allocator: std.mem.Allocator, data: []const u8, privateKeyMap: *const IPrivateKeyMap) ![]u8 {
    if (data.len < NEW_FORMAT_HEADER_LENGTH) {
        return errors.throwError("New-format data too short for header", .{});
    }
    if (!std.mem.eql(u8, data[0..4], TAG_BYTES)) {
        return errors.throwError("New-format data does not start with encryption tag", .{});
    }

    const version = std.mem.readInt(u32, data[4..8], .little);
    var encTypeBuffer: [4]u8 = undefined;
    const encType = normalizeEncryptionType(&encTypeBuffer, data[8..12]);
    const keyHashBuffer = data[12 .. 12 + PUBLIC_KEY_HASH_LENGTH];
    const keyHashHex = std.fmt.bytesToHex(keyHashBuffer[0..PUBLIC_KEY_HASH_LENGTH].*, .lower);
    if (std.mem.indexOfScalar(u32, &SUPPORTED_VERSIONS, version) == null or !includesString(&SUPPORTED_TYPES, encType)) {
        return errors.throwError("Unsupported encryption format version={d} type={s}", .{ version, encType });
    }

    const privateKey = privateKeyMap.get(&keyHashHex) orelse {
        return errors.throwError("No private key in map for key hash {s}", .{&keyHashHex});
    };

    const payload = data[NEW_FORMAT_HEADER_LENGTH..];
    const encryptedKey = clampedSlice(payload, 0, 512);
    const iv = clampedSlice(payload, 512, 512 + 16);
    const encrypted = clampedSlice(payload, 512 + 16, payload.len);
    const key = try crypto.privateDecrypt(allocator, privateKey, encryptedKey);
    var decipher = try crypto.createDecipheriv("aes-256-cbc", key, iv);
    return std.mem.concat(allocator, u8, &.{ try decipher.update(allocator, encrypted), try decipher.final(allocator) });
}

//
// Decrypts a buffer in legacy format (no header: encryptedKey + iv + ciphertext) using the default key.
//
pub fn decryptLegacy(allocator: std.mem.Allocator, data: []const u8, privateKey: *const crypto.PrivateKey) ![]u8 {
    if (data.len < LEGACY_HEADER_LENGTH) {
        return errors.throwError("Legacy encrypted data too short", .{});
    }
    const encryptedKey = data[0..512];
    const iv = data[512 .. 512 + 16];
    const encrypted = data[512 + 16 ..];
    const key = try crypto.privateDecrypt(allocator, privateKey, encryptedKey);
    var decipher = try crypto.createDecipheriv("aes-256-cbc", key, iv);
    return std.mem.concat(allocator, u8, &.{ try decipher.update(allocator, encrypted), try decipher.final(allocator) });
}
