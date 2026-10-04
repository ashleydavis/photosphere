const std = @import("std");
const node_api = @import("node-api-zig");
const storage_zig = @import("storage-zig");
const helpers = @import("test-helpers.zig");

const LazyOriginStorage = node_api.lazy_origin_storage.LazyOriginStorage;
const storage_module = storage_zig.storage;
const IStorage = storage_module.IStorage;
const IReadStream = storage_module.IReadStream;
const IFileInfo = storage_module.IFileInfo;
const IListResult = storage_module.IListResult;
const IWriteLockInfo = storage_module.IWriteLockInfo;

const io = std.testing.io;

//
// A readable stream over bytes held in memory (TypeScript: `Readable.from(data)`).
//
const MemoryReadStream = struct {
    // The reader over the bytes.
    reader: std.Io.Reader,

    //
    // Gets the reader.
    //
    fn readerFunction(ptr: *anyopaque) *std.Io.Reader {
        const self: *MemoryReadStream = @ptrCast(@alignCast(ptr));
        return &self.reader;
    }

    //
    // Nothing to release.
    //
    fn destroyFunction(ptr: *anyopaque, streamIo: std.Io) void {
        _ = ptr;
        _ = streamIo;
    }

    // The IReadStream functions.
    const vtable: IReadStream.VTable = .{
        .reader = readerFunction,
        .destroy = destroyFunction,
    };
};

//
// A readable stream whose every read fails (TypeScript: a Readable that emits an error).
//
const FailingReadStream = struct {
    // The reader, which fails when it is read.
    reader: std.Io.Reader = .{
        .vtable = &.{ .stream = streamFunction },
        .buffer = &.{},
        .seek = 0,
        .end = 0,
    },

    //
    // Fails the read.
    //
    fn streamFunction(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        _ = reader;
        _ = writer;
        _ = limit;
        return error.ReadFailed;
    }

    //
    // Gets the reader.
    //
    fn readerFunction(ptr: *anyopaque) *std.Io.Reader {
        const self: *FailingReadStream = @ptrCast(@alignCast(ptr));
        return &self.reader;
    }

    //
    // Nothing to release.
    //
    fn destroyFunction(ptr: *anyopaque, streamIo: std.Io) void {
        _ = ptr;
        _ = streamIo;
    }

    // The IReadStream functions.
    const vtable: IReadStream.VTable = .{
        .reader = readerFunction,
        .destroy = destroyFunction,
    };
};

//
// A minimal mock IStorage (TypeScript: makeMockStorage). Only the methods used by LazyOriginStorage tests have
// real implementations; the rest throw so accidental calls are obvious. Its files are shared with the concurrent
// cache write, so they are guarded and allocated with a thread safe allocator.
//
const MockStorage = struct {
    // The files, by path.
    files: std.StringHashMapUnmanaged([]const u8) = .empty,

    // Guards files.
    mutex: std.Io.Mutex = .init,

    // Set when read is called (TypeScript: the test's wrapper around origin.read).
    readCalled: bool = false,

    // Set when readStream is called.
    readStreamCalled: bool = false,

    // Set when write is called.
    writeCalled: bool = false,

    // Set when writeStream is called.
    writeStreamCalled: bool = false,

    // Makes writeStream fail (TypeScript: `local.writeStream = async () => { throw new Error("disk full"); }`).
    writeStreamFails: bool = false,

    // Makes readStream fail (TypeScript: an origin.readStream that throws "should not be called").
    readStreamFails: bool = false,

    // Makes the stream readStream returns fail when it is read (TypeScript: a Readable that emits an error).
    streamReadFails: bool = false,

    //
    // Gets the IStorage interface.
    //
    fn storage(self: *MockStorage) IStorage {
        return .{ .ptr = self, .vtable = storage_module.implement(MockStorage), .location = "mock://local" };
    }

    //
    // Adds a file.
    //
    fn put(self: *MockStorage, filePath: []const u8, data: []const u8) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.files.put(std.heap.smp_allocator, try std.heap.smp_allocator.dupe(u8, filePath), try std.heap.smp_allocator.dupe(u8, data));
    }

    //
    // Gets a file.
    //
    fn get(self: *MockStorage, filePath: []const u8) ?[]const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.files.get(filePath);
    }

    //
    // Frees the files.
    //
    fn deinit(self: *MockStorage) void {
        var iterator = self.files.iterator();
        while (iterator.next()) |entry| {
            std.heap.smp_allocator.free(entry.key_ptr.*);
            std.heap.smp_allocator.free(entry.value_ptr.*);
        }
        self.files.deinit(std.heap.smp_allocator);
    }

    pub fn isEmpty(self: *MockStorage, allocator: std.mem.Allocator, storageIo: std.Io, path: []const u8) !bool {
        _ = .{ self, allocator, storageIo, path };
        return error.NotImplemented;
    }

    pub fn listFiles(self: *MockStorage, allocator: std.mem.Allocator, storageIo: std.Io, path: []const u8, max: u32, next: ?[]const u8) !IListResult {
        _ = .{ self, allocator, storageIo, path, max, next };
        return error.NotImplemented;
    }

    pub fn listDirs(self: *MockStorage, allocator: std.mem.Allocator, storageIo: std.Io, path: []const u8, max: u32, next: ?[]const u8) !IListResult {
        _ = .{ self, allocator, storageIo, path, max, next };
        return error.NotImplemented;
    }

    pub fn fileExists(self: *MockStorage, allocator: std.mem.Allocator, storageIo: std.Io, filePath: []const u8) !bool {
        _ = .{ allocator, storageIo };
        return self.get(filePath) != null;
    }

    pub fn dirExists(self: *MockStorage, allocator: std.mem.Allocator, storageIo: std.Io, dirPath: []const u8) !bool {
        _ = .{ self, allocator, storageIo, dirPath };
        return error.NotImplemented;
    }

    pub fn info(self: *MockStorage, allocator: std.mem.Allocator, storageIo: std.Io, filePath: []const u8) !?IFileInfo {
        _ = .{ self, allocator, storageIo, filePath };
        return error.NotImplemented;
    }

    pub fn readableLength(self: *MockStorage, fileInfo: IFileInfo) ?u64 {
        _ = self;
        return fileInfo.length;
    }

    //
    // Not used by the tests.
    //
    pub fn writeStreamHashed(self: *MockStorage, allocator: std.mem.Allocator, storageIo: std.Io, filePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64, sha256: []const u8) !bool {
        _ = self;
        _ = allocator;
        _ = storageIo;
        _ = filePath;
        _ = contentType;
        _ = inputStream;
        _ = contentLength;
        _ = sha256;
        return error.NotImplemented;
    }

    //
    // Not used by the tests.
    //
    pub fn storedHash(self: *MockStorage, allocator: std.mem.Allocator, storageIo: std.Io, filePath: []const u8) !?[]const u8 {
        _ = self;
        _ = allocator;
        _ = storageIo;
        _ = filePath;
        return error.NotImplemented;
    }

    pub fn read(self: *MockStorage, allocator: std.mem.Allocator, storageIo: std.Io, filePath: []const u8) !?[]u8 {
        _ = storageIo;
        self.readCalled = true;
        const data = self.get(filePath) orelse return null;
        return try allocator.dupe(u8, data);
    }

    pub fn write(self: *MockStorage, allocator: std.mem.Allocator, storageIo: std.Io, filePath: []const u8, contentType: ?[]const u8, data: []const u8) !void {
        _ = .{ allocator, storageIo, contentType };
        self.writeCalled = true;
        try self.put(filePath, data);
    }

    pub fn readStream(self: *MockStorage, allocator: std.mem.Allocator, storageIo: std.Io, filePath: []const u8) !IReadStream {
        _ = storageIo;
        self.readStreamCalled = true;
        if (self.readStreamFails) {
            return error.ShouldNotBeCalled;
        }
        const data = self.get(filePath) orelse return error.FileNotFound;
        if (self.streamReadFails) {
            const failingStream = try allocator.create(FailingReadStream);
            failingStream.* = .{};
            return .{ .ptr = failingStream, .vtable = &FailingReadStream.vtable };
        }
        const stream = try allocator.create(MemoryReadStream);
        stream.* = .{ .reader = .fixed(data) };
        return .{ .ptr = stream, .vtable = &MemoryReadStream.vtable };
    }

    pub fn writeStream(self: *MockStorage, allocator: std.mem.Allocator, storageIo: std.Io, filePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64) !void {
        _ = .{ storageIo, contentType, contentLength };
        self.writeStreamCalled = true;
        if (self.writeStreamFails) {
            return error.DiskFull;
        }
        const data = try inputStream.allocRemaining(allocator, .unlimited);
        try self.put(filePath, data);
    }

    pub fn deleteFile(self: *MockStorage, allocator: std.mem.Allocator, storageIo: std.Io, filePath: []const u8) !void {
        _ = .{ allocator, storageIo };
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        _ = self.files.remove(filePath);
    }

    pub fn deleteDir(self: *MockStorage, allocator: std.mem.Allocator, storageIo: std.Io, dirPath: []const u8) !void {
        _ = .{ self, allocator, storageIo, dirPath };
        return error.NotImplemented;
    }

    pub fn copyTo(self: *MockStorage, allocator: std.mem.Allocator, storageIo: std.Io, srcPath: []const u8, destPath: []const u8) !void {
        _ = .{ self, allocator, storageIo, srcPath, destPath };
        return error.NotImplemented;
    }

    pub fn checkWriteLock(self: *MockStorage, allocator: std.mem.Allocator, storageIo: std.Io, filePath: []const u8) !?IWriteLockInfo {
        _ = .{ self, allocator, storageIo, filePath };
        return error.NotImplemented;
    }

    pub fn acquireWriteLock(self: *MockStorage, allocator: std.mem.Allocator, storageIo: std.Io, filePath: []const u8, owner: []const u8) !bool {
        _ = .{ self, allocator, storageIo, filePath, owner };
        return error.NotImplemented;
    }

    pub fn releaseWriteLock(self: *MockStorage, allocator: std.mem.Allocator, storageIo: std.Io, filePath: []const u8) !void {
        _ = .{ self, allocator, storageIo, filePath };
        return error.NotImplemented;
    }
};

//
// Reads all bytes from a stream and destroys it.
//
fn readAll(allocator: std.mem.Allocator, stream: IReadStream) ![]u8 {
    defer stream.destroy(io);
    return stream.reader().allocRemaining(allocator, .unlimited);
}

test "read() returns local data without calling origin when local has the file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var local: MockStorage = .{};
    defer local.deinit();
    var origin: MockStorage = .{};
    defer origin.deinit();
    try local.put("foo.txt", "local");
    try origin.put("foo.txt", "origin");

    var lazy = LazyOriginStorage.init(local.storage(), origin.storage());
    const result = try lazy.storage().read(arena.allocator(), io, "foo.txt");

    try std.testing.expectEqualStrings("local", result.?);
    try std.testing.expect(!origin.readCalled);
}

test "read() fetches from origin when local returns undefined, caches locally, and returns data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var local: MockStorage = .{};
    defer local.deinit();
    var origin: MockStorage = .{};
    defer origin.deinit();
    try origin.put("bar.txt", "from-origin");

    var lazy = LazyOriginStorage.init(local.storage(), origin.storage());
    const result = try lazy.storage().read(arena.allocator(), io, "bar.txt");

    try std.testing.expectEqualStrings("from-origin", result.?);

    // File should now be cached locally.
    try std.testing.expectEqualStrings("from-origin", local.get("bar.txt").?);
}

test "read() returns undefined when both local and origin have nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var local: MockStorage = .{};
    defer local.deinit();
    var origin: MockStorage = .{};
    defer origin.deinit();
    var lazy = LazyOriginStorage.init(local.storage(), origin.storage());
    try std.testing.expect((try lazy.storage().read(arena.allocator(), io, "missing.txt")) == null);
}

test "readStream() returns local stream directly when file exists locally" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var local: MockStorage = .{};
    defer local.deinit();
    var origin: MockStorage = .{};
    defer origin.deinit();
    try local.put("img.jpg", "localdata");
    try origin.put("img.jpg", "origindata");
    origin.readStreamFails = true;

    var lazy = LazyOriginStorage.init(local.storage(), origin.storage());
    const data = try readAll(arena.allocator(), try lazy.storage().readStream(arena.allocator(), io, "img.jpg"));

    try std.testing.expectEqualStrings("localdata", data);
    try std.testing.expect(!origin.readStreamCalled);
}

test "readStream() fetches from origin and tees when file is missing locally" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var local: MockStorage = .{};
    defer local.deinit();
    var origin: MockStorage = .{};
    defer origin.deinit();
    try origin.put("vid.mp4", "videodata");

    var lazy = LazyOriginStorage.init(local.storage(), origin.storage());
    const data = try readAll(arena.allocator(), try lazy.storage().readStream(arena.allocator(), io, "vid.mp4"));

    try std.testing.expectEqualStrings("videodata", data);

    // File should now be cached locally (destroying the stream waited for the cache write).
    try std.testing.expectEqualStrings("videodata", local.get("vid.mp4").?);
}

test "readStream() streams data correctly even if local cache write fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var local: MockStorage = .{};
    defer local.deinit();
    var origin: MockStorage = .{};
    defer origin.deinit();
    try origin.put("doc.pdf", "pdfdata");

    // Make the local writeStream always reject.
    local.writeStreamFails = true;

    var lazy = LazyOriginStorage.init(local.storage(), origin.storage());
    const data = try readAll(arena.allocator(), try lazy.storage().readStream(arena.allocator(), io, "doc.pdf"));

    try std.testing.expectEqualStrings("pdfdata", data);
}

test "readStream() tees a file larger than the cache queue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var local: MockStorage = .{};
    defer local.deinit();
    var origin: MockStorage = .{};
    defer origin.deinit();
    const big = try allocator.alloc(u8, 200_000);
    for (big, 0..) |*byte, index| {
        byte.* = @intCast(index % 251);
    }
    try origin.put("big.bin", big);

    var lazy = LazyOriginStorage.init(local.storage(), origin.storage());
    const data = try readAll(allocator, try lazy.storage().readStream(allocator, io, "big.bin"));

    try std.testing.expectEqualSlices(u8, big, data);
    try std.testing.expectEqualSlices(u8, big, local.get("big.bin").?);
}

test "readStream() streams a file larger than the cache queue in full when the local cache write fails" {
    // A divergence kept on purpose (docs/zig-port-map.md, "Divergences kept"): the TypeScript stops after its
    // PassThrough buffers fill, because nothing drains the cache stream once the cache write has failed, and the
    // caller waits for ever. The Zig stops feeding the cache and hands the caller the whole file.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var local: MockStorage = .{};
    defer local.deinit();
    var origin: MockStorage = .{};
    defer origin.deinit();
    const big = try allocator.alloc(u8, 200_000);
    for (big, 0..) |*byte, index| {
        byte.* = @intCast(index % 251);
    }
    try origin.put("big.bin", big);
    local.writeStreamFails = true;

    var lazy = LazyOriginStorage.init(local.storage(), origin.storage());
    const data = try readAll(allocator, try lazy.storage().readStream(allocator, io, "big.bin"));

    try std.testing.expectEqualSlices(u8, big, data);
}

// TypeScript: the callerStream emits the origin's error, and the cacheStream is destroyed with it, so nothing partial
// is cached.
test "readStream() fails the caller's read and caches nothing when the origin stream fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var local: MockStorage = .{};
    defer local.deinit();
    var origin: MockStorage = .{};
    defer origin.deinit();
    try origin.put("broken.bin", "somedata");
    origin.streamReadFails = true;

    var lazy = LazyOriginStorage.init(local.storage(), origin.storage());
    const stream = try lazy.storage().readStream(arena.allocator(), io, "broken.bin");
    try std.testing.expectError(error.ReadFailed, stream.reader().allocRemaining(arena.allocator(), .unlimited));

    // Destroying the stream waits for the cache write, which ended with the failure.
    stream.destroy(io);
    try std.testing.expect(local.get("broken.bin") == null);
}

test "write() writes to local only and never touches origin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var local: MockStorage = .{};
    defer local.deinit();
    var origin: MockStorage = .{};
    defer origin.deinit();

    var lazy = LazyOriginStorage.init(local.storage(), origin.storage());
    try lazy.storage().write(arena.allocator(), io, "out.txt", null, "hello");

    try std.testing.expectEqualStrings("hello", local.get("out.txt").?);
    try std.testing.expect(!origin.writeCalled);
}

test "writeStream() writes to local only and never touches origin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var local: MockStorage = .{};
    defer local.deinit();
    var origin: MockStorage = .{};
    defer origin.deinit();

    var lazy = LazyOriginStorage.init(local.storage(), origin.storage());
    var input = std.Io.Reader.fixed("streamdata");
    try lazy.storage().writeStream(arena.allocator(), io, "stream.bin", null, &input, null);

    try std.testing.expectEqualStrings("streamdata", local.get("stream.bin").?);
    try std.testing.expect(!origin.writeStreamCalled);
}

test "every other operation goes to the local storage and never to the origin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const localDir = try helpers.makeTempDir(allocator, io, "lazy-local");
    defer helpers.removeTempDir(io, localDir);
    const originDir = try helpers.makeTempDir(allocator, io, "lazy-origin");
    defer helpers.removeTempDir(io, originDir);
    const local = try helpers.directoryStorage(allocator, io, localDir);
    const origin = try helpers.directoryStorage(allocator, io, originDir);
    var lazy = LazyOriginStorage.init(local, origin);
    const storage = lazy.storage();

    try std.testing.expect(try storage.isEmpty(allocator, io, "dir"));
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("content", &hash, .{});
    var input = std.Io.Reader.fixed("content");
    _ = try storage.writeStreamHashed(allocator, io, "dir/file.txt", "text/plain", &input, "content".len, &hash);
    try std.testing.expect(!try storage.isEmpty(allocator, io, "dir"));
    try std.testing.expect(try storage.fileExists(allocator, io, "dir/file.txt"));
    try std.testing.expect(try storage.dirExists(allocator, io, "dir"));
    try std.testing.expectEqual(@as(usize, 1), (try storage.listFiles(allocator, io, "dir", 10, null)).names.len);
    try std.testing.expectEqual(@as(usize, 1), (try storage.listDirs(allocator, io, "", 10, null)).names.len);
    const fileInfo = (try storage.info(allocator, io, "dir/file.txt")).?;
    try std.testing.expectEqual(@as(u64, "content".len), fileInfo.length);
    try std.testing.expectEqual(local.readableLength(fileInfo), storage.readableLength(fileInfo));

    // A file storage keeps no hash, so the local storage has none to give.
    try std.testing.expect((try storage.storedHash(allocator, io, "dir/file.txt")) == null);

    try storage.copyTo(allocator, io, "dir/file.txt", "dir/copy.txt");
    try std.testing.expectEqualStrings("content", (try local.read(allocator, io, "dir/copy.txt")).?);
    try storage.deleteFile(allocator, io, "dir/copy.txt");
    try std.testing.expect(!try local.fileExists(allocator, io, "dir/copy.txt"));

    try std.testing.expect(try storage.acquireWriteLock(allocator, io, "write.lock", "owner"));
    try std.testing.expectEqualStrings("owner", (try storage.checkWriteLock(allocator, io, "write.lock")).?.owner);
    try storage.releaseWriteLock(allocator, io, "write.lock");
    try std.testing.expect((try local.checkWriteLock(allocator, io, "write.lock")) == null);

    try storage.deleteDir(allocator, io, "dir");
    try std.testing.expect(!try local.dirExists(allocator, io, "dir"));

    // The origin was never written to.
    try std.testing.expect(try origin.isEmpty(allocator, io, ""));
}
