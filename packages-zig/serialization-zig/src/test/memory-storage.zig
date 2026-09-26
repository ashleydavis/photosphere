const std = @import("std");

//
// In-memory storage for tests, providing the storage methods that save, load, loadVersion and verify use
// (the equivalent of the MockStorage class in the TypeScript serialization tests).
//
pub const MemoryStorage = struct {
    // Allocates stored file contents and streams.
    allocator: std.mem.Allocator,

    // Stored files by path.
    files: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    // The number of streams opened by readStream that have not been destroyed.
    openStreams: usize = 0,

    //
    // Creates an empty storage.
    //
    pub fn init(allocator: std.mem.Allocator) MemoryStorage {
        return .{ .allocator = allocator };
    }

    //
    // Reads a whole file (null when it does not exist).
    //
    pub fn read(self: *MemoryStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?[]u8 {
        _ = io;
        const data = self.files.get(filePath) orelse {
            return null;
        };
        return try allocator.dupe(u8, data);
    }

    //
    // Writes a whole file.
    //
    pub fn write(self: *MemoryStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, data: []const u8) !void {
        _ = allocator;
        _ = io;
        _ = contentType;
        const owned_path = try self.allocator.dupe(u8, filePath);
        const owned_data = try self.allocator.dupe(u8, data);
        try self.files.put(self.allocator, owned_path, owned_data);
    }

    //
    // Opens a stream that reads a file.
    //
    pub fn readStream(self: *MemoryStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !*MemoryStream {
        _ = io;
        const data = self.files.get(filePath) orelse {
            return error.FileNotFound;
        };
        const stream = try allocator.create(MemoryStream);
        stream.* = .{ .storage = self, .interface = .fixed(data) };
        self.openStreams += 1;
        return stream;
    }

    //
    // Returns true when a file exists.
    //
    pub fn fileExists(self: *MemoryStorage, filePath: []const u8) bool {
        return self.files.contains(filePath);
    }
};

//
// A stream over a stored file.
//
pub const MemoryStream = struct {
    // The storage that opened the stream (tracks open streams).
    storage: *MemoryStorage,

    // Reads the file data.
    interface: std.Io.Reader,

    //
    // Gets the reader of the stream.
    //
    pub fn reader(self: *MemoryStream) *std.Io.Reader {
        return &self.interface;
    }

    //
    // Closes the stream.
    //
    pub fn destroy(self: *MemoryStream, io: std.Io) void {
        _ = io;
        self.storage.openStreams -= 1;
    }
};
