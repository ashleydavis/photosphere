//
// Peeks at the encryption header of a stored file (raw bytes) to detect format and key.
// Call with the underlying (unencrypted) storage so read() returns raw bytes.
//

const std = @import("std");
const utils = @import("utils-zig");
const encryption = @import("encryption-zig");
const storage_module = @import("storage.zig");

const IStorage = storage_module.IStorage;
const ENCRYPTION_TAG = encryption.encryption_constants.ENCRYPTION_TAG;
const NEW_FORMAT_HEADER_LENGTH = encryption.encryption_constants.NEW_FORMAT_HEADER_LENGTH;
const PUBLIC_KEY_HASH_LENGTH = encryption.encryption_constants.PUBLIC_KEY_HASH_LENGTH;
const retry = utils.retry.retry;

//
// Reads exactly `length` bytes from the start of a storage file using its read stream.
// Returns undefined if the file does not exist or produces no data.
//
pub fn readFirstBytes(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, filePath: []const u8, length: usize) !?[]u8 {
    if (!try storage.fileExists(allocator, io, filePath)) {
        return null;
    }

    const stream = try storage.readStream(allocator, io, filePath);
    defer stream.destroy(io);

    // Collects chunks until at least `length` bytes have arrived or the stream ends, keeping the first `length`.
    const buffer = try allocator.alloc(u8, length);
    const collected = try stream.reader().readSliceShort(buffer);
    if (collected == 0) {
        return null;
    }
    return buffer[0..collected];
}

//
// The retried read of readEncryptionHeader (TypeScript: the arrow function passed to retry).
//
const ReadFirstBytesOperation = struct {
    // Allocates the bytes read.
    allocator: std.mem.Allocator,

    // The raw storage to read from.
    rawStorage: IStorage,

    // The path of the file to read.
    filePath: []const u8,

    // The Bun toString() of the TypeScript arrow function (used in the retry timeout message).
    pub const source = "() => readFirstBytes(rawStorage, filePath, NEW_FORMAT_HEADER_LENGTH)";

    //
    // Reads the first bytes of the file.
    //
    pub fn run(self: *const ReadFirstBytesOperation, io: std.Io) anyerror!?[]u8 {
        return readFirstBytes(self.allocator, io, self.rawStorage, self.filePath, NEW_FORMAT_HEADER_LENGTH);
    }
};

//
// Reads the first bytes of a file and returns the public key hash from the encryption header if present.
// Pass the raw storage (no decryption layer) so read() returns bytes as stored on disk.
// Returns the 32-byte SHA-256 hash of the public key that encrypted the file, or undefined if
// the file does not exist, is too short, or is not new-format encrypted.
//
pub fn readEncryptionHeader(
    allocator: std.mem.Allocator,
    io: std.Io,
    rawStorage: IStorage,
    filePath: []const u8,
) !?[]const u8 {
    const operation: ReadFirstBytesOperation = .{ .allocator = allocator, .rawStorage = rawStorage, .filePath = filePath };
    const raw = try retry(io, &operation, 3, 1_000, 2, 30_000, null) orelse {
        return null;
    };
    if (raw.len < 4) {
        return null;
    }
    const tag = raw[0..4];
    if (!std.mem.eql(u8, tag, ENCRYPTION_TAG)) {
        return null;
    }
    if (raw.len < NEW_FORMAT_HEADER_LENGTH) {
        return null;
    }
    return raw[12 .. 12 + PUBLIC_KEY_HASH_LENGTH];
}
