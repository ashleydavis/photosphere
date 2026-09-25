const std = @import("std");
const crypto = @import("node-crypto.zig");
const constants = @import("encryption-constants.zig");
const key_utils = @import("key-utils.zig");
const encryption_types = @import("encryption-types.zig");
const encrypt_buffer = @import("encrypt-buffer.zig");
const utils = @import("utils-zig");

//
// Streams.
// TypeScript returns Node Transform streams that are piped from an input stream. In Zig each stream wraps an input
// `*std.Io.Reader` and is itself read through its `interface: std.Io.Reader` field (pull based), which is what
// storage-zig's EncryptedStorage needs:
//   readStream:  const decryption = try createDecryptionStream(allocator, keyMap, try storage.readStream(path));
//                return &decryption.interface;
//   writeStream: const encryption = try createEncryptionStream(allocator, io, publicKey, inputStream);
//                try storage.writeStream(path, contentType, &encryption.interface, computeEncryptedLength(length));
// When reading fails because of the data (for example a wrong key), the reader returns error.ReadFailed and the
// stream's `err` field holds the Zig error; for error.Thrown the message is in utils-zig errors.lastErrorMessage().
// Failures of the input reader are reported the same way (err = error.ReadFailed, details on the input reader).
//

//
// Names used from other files (the equivalent of the TypeScript imports).
//
const IPrivateKeyMap = encryption_types.IPrivateKeyMap;
const hashPublicKey = key_utils.hashPublicKey;
const requireWrappableKey = encrypt_buffer.requireWrappableKey;
const errors = utils.errors;
const ENCRYPTION_TAG = constants.ENCRYPTION_TAG;
const ENCRYPTION_FORMAT_VERSION = constants.ENCRYPTION_FORMAT_VERSION;
const ENCRYPTION_TYPE = constants.ENCRYPTION_TYPE;
const LEGACY_HEADER_LENGTH = constants.LEGACY_HEADER_LENGTH;
const NEW_FORMAT_HEADER_LENGTH = constants.NEW_FORMAT_HEADER_LENGTH;
const NEW_FORMAT_PAYLOAD_OFFSET = constants.NEW_FORMAT_PAYLOAD_OFFSET;
const PUBLIC_KEY_HASH_LENGTH = constants.PUBLIC_KEY_HASH_LENGTH;
const SUPPORTED_TYPES = constants.SUPPORTED_TYPES;
const SUPPORTED_VERSIONS = constants.SUPPORTED_VERSIONS;

//
// The number of bytes read from the input stream at a time.
//
const chunk_length = 64 * 1024;

//
// The size of the buffer behind each stream's std.Io.Reader interface.
//
const reader_buffer_length = 64 * 1024;

//
// A pull-based equivalent of a Node Transform stream: reads chunks from an input reader, passes them to a transform
// function that pushes output, calls a flush function at the end of the input and serves the pushed output through
// a std.Io.Reader. (No TypeScript counterpart: this is the machinery behind `new Transform({ transform, flush })`.)
//
pub const TransformStream = struct {
    // The reader interface that consumers read the transformed data from.
    interface: std.Io.Reader,

    // The stream being transformed.
    input: *std.Io.Reader,

    // Allocator for the output buffer and the transform's own allocations.
    allocator: std.mem.Allocator,

    // Output pushed by the transform that has not been read yet.
    pending: std.ArrayList(u8),

    // The number of bytes of `pending` already read.
    pending_offset: usize,

    // Buffer for chunks read from the input.
    chunk: []u8,

    // True once flush has run (the end of the output).
    finished: bool,

    // The error that stopped the stream, if any.
    err: ?anyerror,

    // Called with each chunk of input (like Transform's transform option).
    transform_function: *const fn (stream: *TransformStream, chunk: []const u8) anyerror!void,

    // Called at the end of the input (like Transform's flush option).
    flush_function: *const fn (stream: *TransformStream) anyerror!void,

    //
    // Initializes a transform stream over an input reader.
    //
    pub fn init(
        allocator: std.mem.Allocator,
        input: *std.Io.Reader,
        transform_function: *const fn (stream: *TransformStream, chunk: []const u8) anyerror!void,
        flush_function: *const fn (stream: *TransformStream) anyerror!void,
    ) !TransformStream {
        return TransformStream{
            .interface = .{
                .vtable = &.{ .stream = streamFunction },
                .buffer = try allocator.alloc(u8, reader_buffer_length),
                .seek = 0,
                .end = 0,
            },
            .input = input,
            .allocator = allocator,
            .pending = .empty,
            .pending_offset = 0,
            .chunk = try allocator.alloc(u8, chunk_length),
            .finished = false,
            .err = null,
            .transform_function = transform_function,
            .flush_function = flush_function,
        };
    }

    //
    // Queues output for the reader (like Transform's this.push).
    //
    pub fn push(self: *TransformStream, data: []const u8) !void {
        try self.pending.appendSlice(self.allocator, data);
    }

    //
    // Reads the next chunk of input and runs the transform (or the flush at the end of the input).
    //
    fn pull(self: *TransformStream) !void {
        const count = try self.input.readSliceShort(self.chunk);
        if (count == 0) {
            try self.flush_function(self);
            self.finished = true;
            return;
        }
        try self.transform_function(self, self.chunk[0..count]);
    }

    //
    // The std.Io.Reader stream function: serves pending output, pulling more input when it runs out.
    //
    fn streamFunction(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *TransformStream = @alignCast(@fieldParentPtr("interface", reader));
        while (self.pending_offset == self.pending.items.len) {
            if (self.finished or self.err != null) {
                if (self.err != null) {
                    return error.ReadFailed;
                }
                return error.EndOfStream;
            }
            self.pending.clearRetainingCapacity();
            self.pending_offset = 0;
            self.pull() catch |err| {
                self.err = err;
                return error.ReadFailed;
            };
        }
        const available = self.pending.items[self.pending_offset..];
        const count = try writer.write(limit.sliceConst(available));
        self.pending_offset += count;
        return count;
    }
};

//
// Computes the byte length of the encrypted output for a given plaintext length.
// AES-256-CBC always adds a PKCS#7 padding block, so the ciphertext is always
// rounded up to the next 16-byte boundary plus one full padding block.
//
pub fn computeEncryptedLength(plainLength: u64) u64 {
    return NEW_FORMAT_PAYLOAD_OFFSET + (plainLength / 16 + 1) * 16;
}

//
// The state of a stream created by createEncryptionStream.
//
pub const EncryptionStream = struct {
    // The transform machinery; read the ciphertext from `transform.interface` (see `reader`).
    transform: TransformStream,

    // Used for the random padding of the RSA encryption.
    io: std.Io,

    // The public key that encrypts the AES key.
    publicKey: *const crypto.PublicKey,

    // The random AES-256 key.
    key: [32]u8,

    // The random IV.
    iv: [16]u8,

    // The AES-256-CBC cipher.
    cipher: crypto.Cipher,

    // The new-format header (tag, version, type, key hash).
    header: [NEW_FORMAT_HEADER_LENGTH]u8,

    // True once the header, encrypted key and IV have been pushed.
    headerSent: bool,

    //
    // Returns the reader that produces the encrypted data.
    //
    pub fn reader(self: *EncryptionStream) *std.Io.Reader {
        return &self.transform.interface;
    }

    //
    // Writes the header, the wrapped key and the iv, once, refusing a key the readers could not
    // slice back out. Both entry points below have to do it, because a stream that is flushed with
    // nothing written still produces a file.
    //
    fn sendHeader(self: *EncryptionStream, stream: *TransformStream) !void {
        const encryptedKey = try crypto.publicEncrypt(stream.allocator, self.io, self.publicKey, &self.key);
        try requireWrappableKey(encryptedKey.len);
        try stream.push(&self.header);
        try stream.push(encryptedKey);
        try stream.push(&self.iv);
        self.headerSent = true;
    }

    //
    // Transform: encrypts one chunk.
    //
    fn transformChunk(stream: *TransformStream, chunk: []const u8) anyerror!void {
        const self: *EncryptionStream = @alignCast(@fieldParentPtr("transform", stream));
        if (!self.headerSent) {
            try self.sendHeader(stream);
        }
        try self.cipher.updateInto(stream.allocator, &stream.pending, chunk);
    }

    //
    // Flush: writes the header when the input was empty, then the final padded block.
    //
    fn flush(stream: *TransformStream) anyerror!void {
        const self: *EncryptionStream = @alignCast(@fieldParentPtr("transform", stream));
        if (!self.headerSent) {
            try self.sendHeader(stream);
        }
        try self.cipher.finalInto(stream.allocator, &stream.pending);
    }
};

//
// Creates a stream that encrypts data with a public key and writes the new format header
// (tag, version, type, keyHash) then the legacy payload (encryptedKey + iv + ciphertext).
// (Zig: the plaintext is read from inputStream; read the ciphertext from the returned stream's reader().)
//
pub fn createEncryptionStream(allocator: std.mem.Allocator, io: std.Io, publicKey: *const crypto.PublicKey, inputStream: *std.Io.Reader) !*EncryptionStream {
    const self = try allocator.create(EncryptionStream);
    self.io = io;
    self.publicKey = publicKey;
    crypto.randomBytes(io, &self.key);
    crypto.randomBytes(io, &self.iv);
    self.cipher = try crypto.createCipheriv("aes-256-cbc", &self.key, &self.iv);
    const keyHash = try hashPublicKey(allocator, publicKey);

    @memcpy(self.header[0..4], ENCRYPTION_TAG);
    std.mem.writeInt(u32, self.header[4..8], ENCRYPTION_FORMAT_VERSION, .little);
    @memcpy(self.header[8..12], ENCRYPTION_TYPE);
    @memcpy(self.header[12..], &keyHash);

    self.headerSent = false;

    self.transform = try TransformStream.init(allocator, inputStream, EncryptionStream.transformChunk, EncryptionStream.flush);
    return self;
}

//
// The state of a stream created by createDecryptionStream.
//
pub const DecryptionStream = struct {
    // The transform machinery; read the plaintext from `transform.interface` (see `reader`).
    transform: TransformStream,

    // The private keys, by key hash and "default".
    privateKeyMap: *const IPrivateKeyMap,

    // The AES-256-CBC decipher, once the key is known.
    decipher: ?crypto.Decipher,

    // True when the data is passed through unchanged.
    passThrough: bool,

    // The header bytes received so far.
    headerBuffer: [NEW_FORMAT_PAYLOAD_OFFSET]u8,

    // The number of valid bytes in headerBuffer.
    headerBytesReceived: usize,

    //
    // Returns the reader that produces the decrypted data.
    //
    pub fn reader(self: *DecryptionStream) *std.Io.Reader {
        return &self.transform.interface;
    }

    //
    // Transform: buffers the header, picks the key and decrypts (or passes data through).
    //
    fn transformChunk(stream: *TransformStream, chunk: []const u8) anyerror!void {
        const self: *DecryptionStream = @alignCast(@fieldParentPtr("transform", stream));
        const allocator = stream.allocator;
        if (self.passThrough) {
            try stream.push(chunk);
            return;
        }

        if (self.decipher != null) {
            try self.decipher.?.updateInto(allocator, &stream.pending, chunk);
            return;
        }

        const toCopy = @min(chunk.len, NEW_FORMAT_PAYLOAD_OFFSET - self.headerBytesReceived);
        @memcpy(self.headerBuffer[self.headerBytesReceived .. self.headerBytesReceived + toCopy], chunk[0..toCopy]);
        self.headerBytesReceived += toCopy;
        const remainder = chunk[toCopy..];

        if (self.headerBytesReceived < 4) {
            return;
        }

        const isLegacy = !std.mem.eql(u8, self.headerBuffer[0..4], ENCRYPTION_TAG);
        if (isLegacy) {
            const defaultKey = self.privateKeyMap.get("default") orelse {
                self.passThrough = true;
                try stream.push(self.headerBuffer[0..self.headerBytesReceived]);
                self.headerBytesReceived = 0;
                if (remainder.len > 0) {
                    try stream.push(remainder);
                }
                return;
            };
            if (self.headerBytesReceived < LEGACY_HEADER_LENGTH) {
                return;
            }
            // (Zig: the TypeScript try block; a failing step breaks out with false, which runs the catch block.)
            const succeeded = legacy: {
                const encryptedKey = self.headerBuffer[0..512];
                const iv = self.headerBuffer[512 .. 512 + 16];
                const key = crypto.privateDecrypt(allocator, defaultKey, encryptedKey) catch |err| {
                    if (err == error.OutOfMemory) {
                        return err;
                    }
                    break :legacy false;
                };
                self.decipher = crypto.createDecipheriv("aes-256-cbc", key, iv) catch {
                    break :legacy false;
                };
                const bufferedCiphertext = self.headerBuffer[LEGACY_HEADER_LENGTH..self.headerBytesReceived];
                if (bufferedCiphertext.len > 0) {
                    try self.decipher.?.updateInto(allocator, &stream.pending, bufferedCiphertext);
                }
                if (remainder.len > 0) {
                    try self.decipher.?.updateInto(allocator, &stream.pending, remainder);
                }
                break :legacy true;
            };
            if (!succeeded) {
                self.passThrough = true;
                try stream.push(self.headerBuffer[0..self.headerBytesReceived]);
                self.headerBytesReceived = 0;
                if (remainder.len > 0) {
                    try stream.push(remainder);
                }
            }
            return;
        }

        if (self.headerBytesReceived < NEW_FORMAT_PAYLOAD_OFFSET) {
            return;
        }

        const version = std.mem.readInt(u32, self.headerBuffer[4..8], .little);
        var encTypeBuffer: [4]u8 = undefined;
        const encType = encrypt_buffer.normalizeEncryptionType(&encTypeBuffer, self.headerBuffer[8..12]);
        const keyHashHex = std.fmt.bytesToHex(self.headerBuffer[12 .. 12 + PUBLIC_KEY_HASH_LENGTH].*, .lower);
        var key = self.privateKeyMap.get(&keyHashHex);
        if (key == null and (std.mem.indexOfScalar(u32, &SUPPORTED_VERSIONS, version) == null or !encrypt_buffer.includesString(&SUPPORTED_TYPES, encType))) {
            key = self.privateKeyMap.get("default");
        }

        const privateKey = key orelse {
            // The data carries the encryption tag, so it says outright that it is encrypted and
            // there is no key for it. Passing it through was a silent wrong answer of the worst
            // kind on this path: a copy reading through this stream would write the ciphertext
            // out as though it were the file, so a prefetch or a sync run without the key would
            // fill a replica with unreadable files and report success. decryptBuffer had the
            // same fallback, and what it produced was a checksum mismatch reported from
            // serialization, which names a place that has nothing to do with the missing key.
            return errors.throwError("Could not decrypt data that says it is encrypted: no private key for key hash {s}", .{&keyHashHex});
        };

        const encryptedKey = self.headerBuffer[NEW_FORMAT_HEADER_LENGTH .. NEW_FORMAT_HEADER_LENGTH + 512];
        const iv = self.headerBuffer[NEW_FORMAT_HEADER_LENGTH + 512 .. NEW_FORMAT_HEADER_LENGTH + 512 + 16];
        const symKey = try crypto.privateDecrypt(allocator, privateKey, encryptedKey);
        self.decipher = try crypto.createDecipheriv("aes-256-cbc", symKey, iv);
        if (remainder.len > 0) {
            try self.decipher.?.updateInto(allocator, &stream.pending, remainder);
        }
    }

    //
    // Flush: pushes buffered bytes of data that never started decryption, or the final decrypted block.
    //
    fn flush(stream: *TransformStream) anyerror!void {
        const self: *DecryptionStream = @alignCast(@fieldParentPtr("transform", stream));
        if (self.passThrough and self.headerBytesReceived > 0) {
            try stream.push(self.headerBuffer[0..self.headerBytesReceived]);
        }
        else if (self.decipher != null) {
            try self.decipher.?.finalInto(stream.allocator, &stream.pending);
        }
        else if (self.headerBytesReceived > 0) {
            // Plain data that never triggered decrypt (e.g. shorter than legacy header)
            try stream.push(self.headerBuffer[0..self.headerBytesReceived]);
        }
    }
};

//
// Creates a stream that decrypts data using a key map. Supports legacy (no header, "default" key)
// and new-format (44-byte header then payload; key looked up by hash from header).
// (Zig: the encrypted data is read from inputStream; read the plaintext from the returned stream's reader().)
//
pub fn createDecryptionStream(allocator: std.mem.Allocator, privateKeyMap: *const IPrivateKeyMap, inputStream: *std.Io.Reader) !*DecryptionStream {
    const self = try allocator.create(DecryptionStream);
    self.privateKeyMap = privateKeyMap;
    self.decipher = null;
    self.passThrough = false;
    self.headerBytesReceived = 0;
    self.transform = try TransformStream.init(allocator, inputStream, DecryptionStream.transformChunk, DecryptionStream.flush);
    return self;
}
