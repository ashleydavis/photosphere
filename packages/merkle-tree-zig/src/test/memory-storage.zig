const std = @import("std");
const storage_zig = @import("storage-zig");
const storage = storage_zig.storage;
const IStorage = storage.IStorage;
const IReadStream = storage.IReadStream;
const IFileInfo = storage.IFileInfo;
const IListResult = storage.IListResult;

//
// In-memory IStorage for tests (the TypeScript tests use FileStorage on a temporary file instead).
// Only the methods the merkle tree functions use do real work; the others fail with error.NotImplemented.
//
pub const MemoryStorage = struct {
    // Allocates stored file contents and streams.
    allocator: std.mem.Allocator,

    // Stored files by path.
    files: std.StringArrayHashMapUnmanaged([]const u8),

    //
    // Creates an empty storage.
    //
    pub fn init(allocator: std.mem.Allocator) MemoryStorage {
        return .{ .allocator = allocator, .files = .empty };
    }

    //
    // Gets the IStorage interface of this storage.
    //
    pub fn asStorage(self: *MemoryStorage) IStorage {
        return .{ .ptr = self, .vtable = &vtable, .location = "memory:" };
    }

    //
    // Stores a file directly (test setup).
    //
    pub fn putFile(self: *MemoryStorage, filePath: []const u8, data: []const u8) !void {
        const ownedPath = try self.allocator.dupe(u8, filePath);
        const ownedData = try self.allocator.dupe(u8, data);
        try self.files.put(self.allocator, ownedPath, ownedData);
    }

    //
    // Gets the stored data of a file (test assertions).
    //
    pub fn getFile(self: *MemoryStorage, filePath: []const u8) ?[]const u8 {
        return self.files.get(filePath);
    }

    //
    // Converts the type erased pointer back to the storage.
    //
    fn fromPointer(pointer: *anyopaque) *MemoryStorage {
        return @ptrCast(@alignCast(pointer));
    }

    //
    // The IStorage functions of this storage.
    //
    const vtable: IStorage.VTable = .{
        .isEmpty = isEmpty,
        .listFiles = listFiles,
        .listDirs = listDirs,
        .fileExists = fileExists,
        .dirExists = dirExists,
        .info = info,
        .read = read,
        .write = write,
        .readStream = readStream,
        .writeStream = writeStream,
        .deleteFile = deleteFile,
        .deleteDir = deleteDir,
        .copyTo = copyTo,
        .checkWriteLock = checkWriteLock,
        .acquireWriteLock = acquireWriteLock,
        .releaseWriteLock = releaseWriteLock,
    };

    //
    // Not implemented.
    //
    fn isEmpty(pointer: *anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8) anyerror!bool {
        _ = pointer;
        _ = allocator;
        _ = io;
        _ = path;
        return error.NotImplemented;
    }

    //
    // Not implemented.
    //
    fn listFiles(pointer: *anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) anyerror!IListResult {
        _ = pointer;
        _ = allocator;
        _ = io;
        _ = path;
        _ = max;
        _ = next;
        return error.NotImplemented;
    }

    //
    // Not implemented.
    //
    fn listDirs(pointer: *anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) anyerror!IListResult {
        _ = pointer;
        _ = allocator;
        _ = io;
        _ = path;
        _ = max;
        _ = next;
        return error.NotImplemented;
    }

    //
    // Returns true when the file exists.
    //
    fn fileExists(pointer: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!bool {
        _ = allocator;
        _ = io;
        return fromPointer(pointer).files.contains(filePath);
    }

    //
    // Not implemented.
    //
    fn dirExists(pointer: *anyopaque, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) anyerror!bool {
        _ = pointer;
        _ = allocator;
        _ = io;
        _ = dirPath;
        return error.NotImplemented;
    }

    //
    // Gets the length of a file (null when it does not exist).
    //
    fn info(pointer: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!?IFileInfo {
        _ = allocator;
        _ = io;
        const data = fromPointer(pointer).files.get(filePath) orelse {
            return null;
        };
        return .{ .contentType = null, .length = data.len, .lastModified = 0 };
    }

    //
    // Reads a whole file (null when it does not exist).
    //
    fn read(pointer: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!?[]u8 {
        _ = io;
        const data = fromPointer(pointer).files.get(filePath) orelse {
            return null;
        };
        return try allocator.dupe(u8, data);
    }

    //
    // Writes a whole file.
    //
    fn write(pointer: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, data: []const u8) anyerror!void {
        _ = allocator;
        _ = io;
        _ = contentType;
        try fromPointer(pointer).putFile(filePath, data);
    }

    //
    // Opens a stream that reads a file.
    //
    fn readStream(pointer: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!IReadStream {
        _ = io;
        const data = fromPointer(pointer).files.get(filePath) orelse {
            return error.FileNotFound;
        };
        const stream = try allocator.create(MemoryStream);
        stream.* = .{ .interface = .fixed(data) };
        return stream.asReadStream();
    }

    //
    // Not implemented.
    //
    fn writeStream(pointer: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64) anyerror!void {
        _ = pointer;
        _ = allocator;
        _ = io;
        _ = filePath;
        _ = contentType;
        _ = inputStream;
        _ = contentLength;
        return error.NotImplemented;
    }

    //
    // Deletes a file.
    //
    fn deleteFile(pointer: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!void {
        _ = allocator;
        _ = io;
        _ = fromPointer(pointer).files.orderedRemove(filePath);
    }

    //
    // Not implemented.
    //
    fn deleteDir(pointer: *anyopaque, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) anyerror!void {
        _ = pointer;
        _ = allocator;
        _ = io;
        _ = dirPath;
        return error.NotImplemented;
    }

    //
    // Not implemented.
    //
    fn copyTo(pointer: *anyopaque, allocator: std.mem.Allocator, io: std.Io, srcPath: []const u8, destPath: []const u8) anyerror!void {
        _ = pointer;
        _ = allocator;
        _ = io;
        _ = srcPath;
        _ = destPath;
        return error.NotImplemented;
    }

    //
    // Not implemented.
    //
    fn checkWriteLock(pointer: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!?storage.IWriteLockInfo {
        _ = pointer;
        _ = allocator;
        _ = io;
        _ = filePath;
        return error.NotImplemented;
    }

    //
    // Not implemented.
    //
    fn acquireWriteLock(pointer: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, owner: []const u8) anyerror!bool {
        _ = pointer;
        _ = allocator;
        _ = io;
        _ = filePath;
        _ = owner;
        return error.NotImplemented;
    }

    //
    // Not implemented.
    //
    fn releaseWriteLock(pointer: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!void {
        _ = pointer;
        _ = allocator;
        _ = io;
        _ = filePath;
        return error.NotImplemented;
    }
};

//
// A stream over a stored file.
//
pub const MemoryStream = struct {
    // Reads the file data.
    interface: std.Io.Reader,

    //
    // Gets the IReadStream interface of this stream.
    //
    pub fn asReadStream(self: *MemoryStream) IReadStream {
        return .{ .ptr = self, .vtable = &stream_vtable };
    }

    //
    // The IReadStream functions of this stream.
    //
    const stream_vtable: IReadStream.VTable = .{
        .reader = reader,
        .destroy = destroy,
    };

    //
    // Gets the reader of the stream.
    //
    fn reader(pointer: *anyopaque) *std.Io.Reader {
        const self: *MemoryStream = @ptrCast(@alignCast(pointer));
        return &self.interface;
    }

    //
    // Closes the stream (nothing to release).
    //
    fn destroy(pointer: *anyopaque, io: std.Io) void {
        _ = pointer;
        _ = io;
    }
};
