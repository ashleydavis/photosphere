const std = @import("std");
const encryption = @import("encryption-zig");
const storage_module = @import("storage.zig");

const IFileInfo = storage_module.IFileInfo;
const IListResult = storage_module.IListResult;
const IStorage = storage_module.IStorage;
const IReadStream = storage_module.IReadStream;
const IPrivateKeyMap = encryption.encryption_types.IPrivateKeyMap;
const PublicKey = encryption.node_crypto.PublicKey;
const computeEncryptedLength = encryption.encrypt_stream.computeEncryptedLength;
const createDecryptionStream = encryption.encrypt_stream.createDecryptionStream;
const createEncryptionStream = encryption.encrypt_stream.createEncryptionStream;
const DecryptionStream = encryption.encrypt_stream.DecryptionStream;
const decryptBuffer = encryption.encrypt_buffer.decryptBuffer;
const encryptBuffer = encryption.encrypt_buffer.encryptBuffer;

//
// A type of storage that wraps another storage and encrypts it.
//
pub const EncryptedStorage = struct {
    // Gets the location of the storage.
    location: []const u8,

    // The wrapped storage (TypeScript: the private `storage` field; renamed because `storage()` returns the interface).
    wrappedStorage: IStorage,

    // The private keys used to decrypt files, by key hash and "default".
    decryptionKeyMap: IPrivateKeyMap,

    // The public key used to encrypt files that are written.
    encryptionPublicKey: *const PublicKey,

    //
    // Creates the encrypted storage (TypeScript: `new EncryptedStorage(location, storage, decryptionKeyMap, encryptionPublicKey)`).
    //
    pub fn init(location: []const u8, wrappedStorage: IStorage, decryptionKeyMap: IPrivateKeyMap, encryptionPublicKey: *const PublicKey) EncryptedStorage {
        return .{
            .location = location,
            .wrappedStorage = wrappedStorage,
            .decryptionKeyMap = decryptionKeyMap,
            .encryptionPublicKey = encryptionPublicKey,
        };
    }

    //
    // Gets the IStorage interface of this storage (TypeScript: the class implements IStorage).
    //
    pub fn storage(self: *EncryptedStorage) IStorage {
        return .{ .ptr = self, .vtable = storage_module.implement(EncryptedStorage), .location = self.location };
    }

    //
    // Returns true if the specified directory is empty.
    //
    pub fn isEmpty(self: *EncryptedStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
        return self.wrappedStorage.isEmpty(allocator, io, path);
    }

    //
    // List files in storage.
    //
    pub fn listFiles(self: *EncryptedStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) !IListResult {
        return self.wrappedStorage.listFiles(allocator, io, path, max, next);
    }

    //
    // List directories in storage.
    //
    pub fn listDirs(self: *EncryptedStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) !IListResult {
        return self.wrappedStorage.listDirs(allocator, io, path, max, next);
    }

    //
    // Returns true if the specified file exists.
    //
    pub fn fileExists(self: *EncryptedStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !bool {
        return self.wrappedStorage.fileExists(allocator, io, filePath);
    }

    //
    // Returns true if the specified directory exists (contains at least one file or subdirectory).
    //
    pub fn dirExists(self: *EncryptedStorage, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) !bool {
        return self.wrappedStorage.dirExists(allocator, io, dirPath);
    }

    //
    // Gets info about a file.
    // (The length is the length of the encrypted file as stored, not the decrypted length, exactly like TypeScript.)
    //
    pub fn info(self: *EncryptedStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?IFileInfo {
        return self.wrappedStorage.info(allocator, io, filePath);
    }

    //
    // Reads a file from storage.
    // Returns undefined if the file doesn't exist.
    //
    pub fn read(self: *EncryptedStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?[]u8 {
        const data = try self.wrappedStorage.read(allocator, io, filePath) orelse {
            return null;
        };

        // decryptBuffer returns either newly allocated memory or `data` itself, both owned by the caller.
        return @constCast(try decryptBuffer(allocator, data, &self.decryptionKeyMap));
    }

    //
    // Writes a file to storage.
    //
    pub fn write(self: *EncryptedStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, data: []const u8) !void {
        try self.wrappedStorage.write(allocator, io, filePath, contentType, try encryptBuffer(allocator, io, self.encryptionPublicKey, data));
    }

    //
    // Streams a file from stroage.
    //
    pub fn readStream(self: *EncryptedStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !IReadStream {
        const readStreamResult = try self.wrappedStorage.readStream(allocator, io, filePath);
        errdefer readStreamResult.destroy(io);
        const decryptionStream = try createDecryptionStream(allocator, &self.decryptionKeyMap, readStreamResult.reader());
        const decryptedStream = try allocator.create(DecryptedReadStream);
        decryptedStream.* = .{ .decryptionStream = decryptionStream, .source = readStreamResult };
        return .{ .ptr = decryptedStream, .vtable = storage_module.implementReadStream(DecryptedReadStream) };
    }

    //
    // Writes an input stream to storage.
    //
    pub fn writeStream(self: *EncryptedStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64) !void {
        const encryptionStream = try createEncryptionStream(allocator, io, self.encryptionPublicKey, inputStream);
        var encryptedLength: ?u64 = null;
        if (contentLength) |length| {
            encryptedLength = computeEncryptedLength(length);
        }
        try self.wrappedStorage.writeStream(allocator, io, filePath, contentType, encryptionStream.reader(), encryptedLength);
    }

    //
    // Deletes a file from storage.
    //
    pub fn deleteFile(self: *EncryptedStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !void {
        return self.wrappedStorage.deleteFile(allocator, io, filePath);
    }

    //
    // Deletes a directory from storage.
    //
    pub fn deleteDir(self: *EncryptedStorage, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) !void {
        return self.wrappedStorage.deleteDir(allocator, io, dirPath);
    }

    //
    // Copies a file from one location to another.
    //
    pub fn copyTo(self: *EncryptedStorage, allocator: std.mem.Allocator, io: std.Io, srcPath: []const u8, destPath: []const u8) !void {
        return self.wrappedStorage.copyTo(allocator, io, srcPath, destPath);
    }

    // Not ported: checkWriteLock, acquireWriteLock, releaseWriteLock, refreshWriteLock
    // (write locks are not used by psi replicate or psi verify).
};

//
// The stream returned by EncryptedStorage.readStream: the decryption stream piped from the wrapped storage's stream
// (TypeScript: `pipe(readStream, decryptionStream)`).
//
const DecryptedReadStream = struct {
    // The stream that decrypts the source.
    decryptionStream: *DecryptionStream,

    // The stream of the encrypted file from the wrapped storage.
    source: IReadStream,

    //
    // Gets the reader that yields the decrypted bytes.
    //
    pub fn reader(self: *DecryptedReadStream) *std.Io.Reader {
        return self.decryptionStream.reader();
    }

    //
    // Destroys the source stream.
    //
    pub fn destroy(self: *DecryptedReadStream, io: std.Io) void {
        self.source.destroy(io);
    }
};
