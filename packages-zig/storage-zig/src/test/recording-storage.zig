const std = @import("std");
const storage_zig = @import("storage-zig");

const storage_module = storage_zig.storage;
const IStorage = storage_module.IStorage;
const IReadStream = storage_module.IReadStream;
const IFileInfo = storage_module.IFileInfo;
const IListResult = storage_module.IListResult;
const IWriteLockInfo = storage_module.IWriteLockInfo;

//
// A test storage that records the method name and paths of every call and returns canned results.
//
pub const RecordingStorage = struct {
    // Allocates the recorded calls.
    allocator: std.mem.Allocator,

    // The recorded calls, "method path [path]".
    calls: std.ArrayList([]const u8),

    //
    // Creates the storage.
    //
    pub fn init(allocator: std.mem.Allocator) RecordingStorage {
        return .{ .allocator = allocator, .calls = .empty };
    }

    //
    // Gets the IStorage interface.
    //
    pub fn storage(self: *RecordingStorage) IStorage {
        return .{ .ptr = self, .vtable = storage_module.implement(RecordingStorage), .location = "rec:" };
    }

    //
    // Records one call.
    //
    fn record(self: *RecordingStorage, method: []const u8, path: []const u8) !void {
        try self.calls.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ method, path }));
    }

    //
    // Records isEmpty.
    //
    pub fn isEmpty(self: *RecordingStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
        _ = allocator;
        _ = io;
        try self.record("isEmpty", path);
        return true;
    }

    //
    // Records listFiles.
    //
    pub fn listFiles(self: *RecordingStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) !IListResult {
        _ = allocator;
        _ = io;
        _ = max;
        _ = next;
        try self.record("listFiles", path);
        return .{ .names = &.{}, .next = null };
    }

    //
    // Records listDirs.
    //
    pub fn listDirs(self: *RecordingStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) !IListResult {
        _ = allocator;
        _ = io;
        _ = max;
        _ = next;
        try self.record("listDirs", path);
        return .{ .names = &.{}, .next = null };
    }

    //
    // Records fileExists.
    //
    pub fn fileExists(self: *RecordingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !bool {
        _ = allocator;
        _ = io;
        try self.record("fileExists", filePath);
        return true;
    }

    //
    // Records dirExists.
    //
    pub fn dirExists(self: *RecordingStorage, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) !bool {
        _ = allocator;
        _ = io;
        try self.record("dirExists", dirPath);
        return true;
    }

    //
    // Records info.
    //
    pub fn info(self: *RecordingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?IFileInfo {
        _ = allocator;
        _ = io;
        try self.record("info", filePath);
        return .{ .contentType = null, .length = 42, .lastModified = 7 };
    }

    //
    // Records read.
    //
    pub fn read(self: *RecordingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?[]u8 {
        _ = io;
        try self.record("read", filePath);
        return try allocator.dupe(u8, "data");
    }

    //
    // Records write.
    //
    pub fn write(self: *RecordingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, data: []const u8) !void {
        _ = allocator;
        _ = io;
        _ = contentType;
        _ = data;
        try self.record("write", filePath);
    }

    //
    // Records readStream (not supported: fails).
    //
    pub fn readStream(self: *RecordingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !IReadStream {
        _ = allocator;
        _ = io;
        try self.record("readStream", filePath);
        return error.NotImplemented;
    }

    //
    // Records writeStream.
    //
    pub fn writeStream(self: *RecordingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64) !void {
        _ = allocator;
        _ = io;
        _ = contentType;
        _ = inputStream;
        _ = contentLength;
        try self.record("writeStream", filePath);
    }

    //
    // Records deleteFile.
    //
    pub fn deleteFile(self: *RecordingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !void {
        _ = allocator;
        _ = io;
        try self.record("deleteFile", filePath);
    }

    //
    // Records deleteDir.
    //
    pub fn deleteDir(self: *RecordingStorage, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) !void {
        _ = allocator;
        _ = io;
        try self.record("deleteDir", dirPath);
    }

    //
    // Records copyTo.
    //
    pub fn copyTo(self: *RecordingStorage, allocator: std.mem.Allocator, io: std.Io, srcPath: []const u8, destPath: []const u8) !void {
        _ = allocator;
        _ = io;
        try self.calls.append(self.allocator, try std.fmt.allocPrint(self.allocator, "copyTo {s} {s}", .{ srcPath, destPath }));
    }

    //
    // Records checkWriteLock.
    //
    pub fn checkWriteLock(self: *RecordingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?IWriteLockInfo {
        _ = allocator;
        _ = io;
        try self.record("checkWriteLock", filePath);
        return null;
    }

    //
    // Records acquireWriteLock.
    //
    pub fn acquireWriteLock(self: *RecordingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, owner: []const u8) !bool {
        _ = allocator;
        _ = io;
        try self.calls.append(self.allocator, try std.fmt.allocPrint(self.allocator, "acquireWriteLock {s} {s}", .{ filePath, owner }));
        return true;
    }

    //
    // Records releaseWriteLock.
    //
    pub fn releaseWriteLock(self: *RecordingStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !void {
        _ = allocator;
        _ = io;
        try self.record("releaseWriteLock", filePath);
    }
};
