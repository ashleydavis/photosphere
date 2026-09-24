//
// An implementation of storage that operates under a particular prefix.
//

const std = @import("std");
const utils = @import("utils-zig");
const storage_module = @import("storage.zig");
const storage_factory = @import("storage-factory.zig");

const errors = utils.errors;
const IFileInfo = storage_module.IFileInfo;
const IListResult = storage_module.IListResult;
const IStorage = storage_module.IStorage;
const IReadStream = storage_module.IReadStream;
const pathJoin = storage_factory.pathJoin;

//
// Storage that prepends a prefix to every path before passing it to the wrapped storage.
//
pub const StoragePrefixWrapper = struct {
    // The wrapped storage (TypeScript: the private `storage` field; renamed because `storage()` returns the interface).
    wrappedStorage: IStorage,

    // The prefix added to every path.
    prefix: []const u8,

    // The location of the storage (TypeScript: the `location` getter, computed once here).
    location: []const u8,

    //
    // Creates the wrapper (TypeScript: `new StoragePrefixWrapper(storage, prefix)`).
    //
    pub fn init(allocator: std.mem.Allocator, wrappedStorage: IStorage, prefix: []const u8) !StoragePrefixWrapper {
        if (prefix.len == 0) {
            return errors.throwError("Prefix must not be empty.", .{});
        }
        return .{
            .wrappedStorage = wrappedStorage,
            .prefix = prefix,
            .location = try pathJoin(allocator, &.{ wrappedStorage.location, prefix }),
        };
    }

    //
    // Gets the IStorage interface of this storage (TypeScript: the class implements IStorage).
    //
    pub fn storage(self: *StoragePrefixWrapper) IStorage {
        return .{ .ptr = self, .vtable = storage_module.implement(StoragePrefixWrapper), .location = self.location };
    }

    //
    // Make a full path using the prefix.
    //
    fn makeFullPath(self: *StoragePrefixWrapper, allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        if (std.mem.endsWith(u8, self.prefix, ":")) {
            return std.mem.concat(allocator, u8, &.{ self.prefix, path });
        }
        else {
            return pathJoin(allocator, &.{ self.prefix, path });
        }
    }

    //
    // Returns true if the specified directory is empty.
    //
    pub fn isEmpty(self: *StoragePrefixWrapper, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
        return self.wrappedStorage.isEmpty(allocator, io, try self.makeFullPath(allocator, path));
    }

    //
    // List files in storage.
    //
    pub fn listFiles(self: *StoragePrefixWrapper, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) !IListResult {
        return self.wrappedStorage.listFiles(allocator, io, try self.makeFullPath(allocator, path), max, next);
    }

    //
    // List directories in storage.
    //
    pub fn listDirs(self: *StoragePrefixWrapper, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) !IListResult {
        return self.wrappedStorage.listDirs(allocator, io, try self.makeFullPath(allocator, path), max, next);
    }

    //
    // Returns true if the specified file exists.
    //
    pub fn fileExists(self: *StoragePrefixWrapper, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !bool {
        return self.wrappedStorage.fileExists(allocator, io, try self.makeFullPath(allocator, filePath));
    }

    //
    // Returns true if the specified directory exists (contains at least one file or subdirectory).
    //
    pub fn dirExists(self: *StoragePrefixWrapper, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) !bool {
        return self.wrappedStorage.dirExists(allocator, io, try self.makeFullPath(allocator, dirPath));
    }

    //
    // Gets info about a file.
    //
    pub fn info(self: *StoragePrefixWrapper, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?IFileInfo {
        return self.wrappedStorage.info(allocator, io, try self.makeFullPath(allocator, filePath));
    }

    //
    // Reads a file from storage.
    // Returns undefined if the file doesn't exist.
    //
    pub fn read(self: *StoragePrefixWrapper, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?[]u8 {
        return self.wrappedStorage.read(allocator, io, try self.makeFullPath(allocator, filePath));
    }

    //
    // Writes a file to storage.
    //
    pub fn write(self: *StoragePrefixWrapper, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, data: []const u8) !void {
        return self.wrappedStorage.write(allocator, io, try self.makeFullPath(allocator, filePath), contentType, data);
    }

    //
    // Streams a file from stroage.
    //
    pub fn readStream(self: *StoragePrefixWrapper, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !IReadStream {
        return self.wrappedStorage.readStream(allocator, io, try self.makeFullPath(allocator, filePath));
    }

    //
    // Writes an input stream to storage.
    //
    pub fn writeStream(self: *StoragePrefixWrapper, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64) !void {
        return self.wrappedStorage.writeStream(allocator, io, try self.makeFullPath(allocator, filePath), contentType, inputStream, contentLength);
    }

    //
    // Deletes the file from storage.
    //
    pub fn deleteFile(self: *StoragePrefixWrapper, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !void {
        return self.wrappedStorage.deleteFile(allocator, io, try self.makeFullPath(allocator, filePath));
    }

    //
    // Deletes the directory from storage.
    //
    pub fn deleteDir(self: *StoragePrefixWrapper, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !void {
        return self.wrappedStorage.deleteDir(allocator, io, try self.makeFullPath(allocator, filePath));
    }

    //
    // Copies a file from one location to another.
    //
    pub fn copyTo(self: *StoragePrefixWrapper, allocator: std.mem.Allocator, io: std.Io, srcPath: []const u8, destPath: []const u8) !void {
        return self.wrappedStorage.copyTo(allocator, io, try self.makeFullPath(allocator, srcPath), try self.makeFullPath(allocator, destPath));
    }

    // Not ported: checkWriteLock, acquireWriteLock, releaseWriteLock, refreshWriteLock
    // (write locks are not used by psi replicate or psi verify).
};
