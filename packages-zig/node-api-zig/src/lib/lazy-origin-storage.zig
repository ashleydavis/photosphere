const std = @import("std");
const storage_zig = @import("storage-zig");

const IStorage = storage_zig.storage.IStorage;
const IReadStream = storage_zig.storage.IReadStream;
const IFileInfo = storage_zig.storage.IFileInfo;
const IListResult = storage_zig.storage.IListResult;
const IWriteLockInfo = storage_zig.storage.IWriteLockInfo;

//
// A storage wrapper that transparently fetches missing files from an origin storage
// and caches them locally on first access.
//
// Read operations check local first; if the file is absent, they fetch from origin,
// cache the result locally, and return it to the caller.
//
// Write operations always go to local only — the origin is never written to.
//
// fileExists / dirExists / info / list operations query local only; they do not
// trigger a fetch, so callers that check existence before reading will still get
// the lazy-fetch behaviour on the subsequent read call.
//
pub const LazyOriginStorage = struct {
    //
    // Local storage that acts as the primary read/write target and cache.
    //
    local: IStorage,

    //
    // Origin storage that is consulted when a file is missing locally.
    //
    origin: IStorage,

    //
    // Creates the wrapper.
    //
    pub fn init(local: IStorage, origin: IStorage) LazyOriginStorage {
        return .{
            .local = local,
            .origin = origin,
        };
    }

    //
    // Gets the IStorage interface of this storage.
    // Its location is the local storage's location.
    //
    pub fn storage(self: *LazyOriginStorage) IStorage {
        return .{ .ptr = self, .vtable = storage_zig.storage.implement(LazyOriginStorage), .location = self.local.location };
    }

    //
    // Returns true if the specified directory is empty (local only).
    //
    pub fn isEmpty(self: *LazyOriginStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
        return self.local.isEmpty(allocator, io, path);
    }

    //
    // Lists files (local only).
    //
    pub fn listFiles(self: *LazyOriginStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) !IListResult {
        return self.local.listFiles(allocator, io, path, max, next);
    }

    //
    // Lists directories (local only).
    //
    pub fn listDirs(self: *LazyOriginStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) !IListResult {
        return self.local.listDirs(allocator, io, path, max, next);
    }

    //
    // Returns true if the file exists locally.
    //
    pub fn fileExists(self: *LazyOriginStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !bool {
        return self.local.fileExists(allocator, io, filePath);
    }

    //
    // Returns true if the directory exists locally.
    //
    pub fn dirExists(self: *LazyOriginStorage, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) !bool {
        return self.local.dirExists(allocator, io, dirPath);
    }

    //
    // Gets info about a local file.
    //
    pub fn info(self: *LazyOriginStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?IFileInfo {
        return self.local.info(allocator, io, filePath);
    }

    //
    // How many bytes a read hands out, which the local store is the one to say.
    //
    pub fn readableLength(self: *LazyOriginStorage, fileInfo: IFileInfo) ?u64 {
        return self.local.readableLength(fileInfo);
    }

    //
    // Writes a stream whose SHA-256 the caller already knows, into the local store.
    //
    pub fn writeStreamHashed(self: *LazyOriginStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64, sha256: []const u8) !bool {
        return self.local.writeStreamHashed(allocator, io, filePath, contentType, inputStream, contentLength, sha256);
    }

    //
    // The SHA-256 the local store kept of a file, when it can say without sending the bytes back.
    //
    pub fn storedHash(self: *LazyOriginStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?[]const u8 {
        return self.local.storedHash(allocator, io, filePath);
    }

    //
    // Reads a file from local storage. If the file is absent locally, fetches it from
    // origin, caches it locally, and returns the data.
    //
    pub fn read(self: *LazyOriginStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?[]u8 {
        if (try self.local.read(allocator, io, filePath)) |localData| {
            return localData;
        }

        const originData = try self.origin.read(allocator, io, filePath) orelse {
            return null;
        };

        try self.local.write(allocator, io, filePath, null, originData);
        return originData;
    }

    //
    // Writes a file to local storage.
    //
    pub fn write(self: *LazyOriginStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, data: []const u8) !void {
        try self.local.write(allocator, io, filePath, contentType, data);
    }

    //
    // Streams a file from local storage. If the file is absent locally, fetches it from origin into the local cache first and then
    // streams the cached copy. The origin stream is never fully buffered in memory, which is required for large files such as 7 GB
    // videos.
    //
    // Cache write errors are non-fatal — the caller's stream is unaffected.
    // (Zig: in TypeScript a tee writes the cache while the caller reads. Writing the cache and reading the file side by side takes two
    // threads, or one thread switching between them, and a task runs only on its own thread, so the file is cached first. When the
    // cache write fails, the caller is given the origin's stream instead.)
    //
    pub fn readStream(self: *LazyOriginStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !IReadStream {
        if (try self.local.fileExists(allocator, io, filePath)) {
            return self.local.readStream(allocator, io, filePath);
        }

        const originStream = try self.origin.readStream(allocator, io, filePath);
        const cached = cached: {
            defer originStream.destroy(io);
            self.local.writeStream(allocator, io, filePath, null, originStream.reader(), null) catch {
                break :cached false;
            };
            break :cached true;
        };
        if (cached) {
            return self.local.readStream(allocator, io, filePath);
        }
        return self.origin.readStream(allocator, io, filePath);
    }

    //
    // Writes an input stream to local storage.
    //
    pub fn writeStream(self: *LazyOriginStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64) !void {
        try self.local.writeStream(allocator, io, filePath, contentType, inputStream, contentLength);
    }

    //
    // Deletes a local file.
    //
    pub fn deleteFile(self: *LazyOriginStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !void {
        try self.local.deleteFile(allocator, io, filePath);
    }

    //
    // Deletes a local directory.
    //
    pub fn deleteDir(self: *LazyOriginStorage, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) !void {
        try self.local.deleteDir(allocator, io, dirPath);
    }

    //
    // Copies a local file.
    //
    pub fn copyTo(self: *LazyOriginStorage, allocator: std.mem.Allocator, io: std.Io, srcPath: []const u8, destPath: []const u8) !void {
        try self.local.copyTo(allocator, io, srcPath, destPath);
    }

    //
    // Checks the local write lock.
    //
    pub fn checkWriteLock(self: *LazyOriginStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?IWriteLockInfo {
        return self.local.checkWriteLock(allocator, io, filePath);
    }

    //
    // Acquires the local write lock.
    //
    pub fn acquireWriteLock(self: *LazyOriginStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, owner: []const u8) !bool {
        return self.local.acquireWriteLock(allocator, io, filePath, owner);
    }

    //
    // Releases the local write lock.
    //
    pub fn releaseWriteLock(self: *LazyOriginStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !void {
        try self.local.releaseWriteLock(allocator, io, filePath);
    }

    //
    // Refreshes the local write lock.
    //
    pub fn refreshWriteLock(self: *LazyOriginStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, owner: []const u8) !void {
        try self.local.refreshWriteLock(allocator, io, filePath, owner);
    }
};
