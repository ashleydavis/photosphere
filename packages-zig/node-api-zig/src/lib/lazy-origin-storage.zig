const std = @import("std");
const storage_zig = @import("storage-zig");

const storage_module = storage_zig.storage;
const IStorage = storage_module.IStorage;
const IReadStream = storage_module.IReadStream;
const IFileInfo = storage_module.IFileInfo;
const IListResult = storage_module.IListResult;
const IWriteLockInfo = storage_module.IWriteLockInfo;

//
// How many bytes of a file fetched from the origin may wait for the local cache write before the reader waits for
// it (TypeScript: the highWaterMark of the PassThrough streams, 16 KiB).
//
const CACHE_PIPE_CAPACITY = 16 * 1024;

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
    // Creates the wrapper (TypeScript: `new LazyOriginStorage(local, origin)`).
    //
    pub fn init(local: IStorage, origin: IStorage) LazyOriginStorage {
        return .{
            .local = local,
            .origin = origin,
        };
    }

    //
    // Gets the IStorage interface of this storage (TypeScript: the class implements IStorage).
    // Its location is the local storage's location.
    //
    pub fn storage(self: *LazyOriginStorage) IStorage {
        return .{ .ptr = self, .vtable = storage_module.implement(LazyOriginStorage), .location = self.local.location };
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

    // Not ported: writeStreamHashed, storedHash (IStorage in storage-zig does not have them).

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
    // Streams a file from local storage. If the file is absent locally, fetches it from
    // origin using a tee stream: one branch writes to the local cache, the other is
    // returned to the caller. The origin stream is never fully buffered in memory, which
    // is required for large files such as 7 GB videos.
    //
    // Cache write errors are non-fatal — the caller's stream is unaffected.
    // (Zig: the cache write runs concurrently and destroying the returned stream waits for it to finish.)
    //
    pub fn readStream(self: *LazyOriginStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !IReadStream {
        if (try self.local.fileExists(allocator, io, filePath)) {
            return self.local.readStream(allocator, io, filePath);
        }

        const originStream = try self.origin.readStream(allocator, io, filePath);
        const teeStream = try allocator.create(TeeStream);
        teeStream.* = .{
            .allocator = allocator,
            .io = io,
            .originStream = originStream,
            .cachePipe = .{ .io = io },
            .interface = .{
                .vtable = &.{ .stream = TeeStream.streamFunction },
                .buffer = try allocator.alloc(u8, CACHE_PIPE_CAPACITY),
                .seek = 0,
                .end = 0,
            },
            .cacheWrite = undefined,
        };

        //
        // Cache in the background; errors are swallowed so the caller is not affected.
        //
        teeStream.cacheWrite = try io.concurrent(writeCache, .{ self.local, io, try allocator.dupe(u8, filePath), &teeStream.cachePipe });

        return .{ .ptr = teeStream, .vtable = &TeeStream.read_stream_vtable };
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

    // Not ported: refreshWriteLock (IStorage in storage-zig does not have it).
};

//
// Writes the cache branch of a tee to local storage (TypeScript: `this.local.writeStream(filePath, undefined,
// cacheStream).catch(() => {})`). Runs concurrently with the caller's reads, with its own allocator because the
// caller's is not shared between threads.
//
fn writeCache(local: IStorage, io: std.Io, filePath: []const u8, cachePipe: *CachePipe) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    local.writeStream(arena.allocator(), io, filePath, null, &cachePipe.interface, null) catch {};
    cachePipe.finishReading();
}

//
// The cache branch of a tee (TypeScript: the cacheStream PassThrough): a bounded queue of bytes that the caller's
// reads push into and the cache write reads from.
//
const CachePipe = struct {
    // The io the queue waits with.
    io: std.Io,

    // Guards every field below.
    mutex: std.Io.Mutex = .init,

    // Signalled when bytes are added, taken, or the pipe ends.
    changed: std.Io.Condition = .init,

    // The bytes waiting for the cache write.
    queue: [CACHE_PIPE_CAPACITY]u8 = undefined,

    // How many bytes of queue are filled.
    queued: usize = 0,

    // True when the origin stream ended (TypeScript: `cacheStream.end()`).
    ended: bool = false,

    // True when the caller's stream failed or was destroyed early (TypeScript: `cacheStream.destroy(err)`).
    failed: bool = false,

    // True when the cache write has stopped reading (it finished or failed), so pushes are dropped.
    readerDone: bool = false,

    // The reader the cache write reads from.
    interface: std.Io.Reader = .{
        .vtable = &.{ .stream = streamFunction },
        .buffer = &.{},
        .seek = 0,
        .end = 0,
    },

    //
    // Adds bytes for the cache write, waiting while the queue is full (TypeScript: `cacheStream.write(chunk)` with
    // the origin paused until it drains).
    //
    fn push(self: *CachePipe, data: []const u8) void {
        var remaining = data;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (remaining.len > 0) {
            while (self.queued == self.queue.len and !self.readerDone) {
                self.changed.waitUncancelable(self.io, &self.mutex);
            }
            if (self.readerDone) {
                return;
            }
            const count = @min(remaining.len, self.queue.len - self.queued);
            @memcpy(self.queue[self.queued .. self.queued + count], remaining[0..count]);
            self.queued += count;
            remaining = remaining[count..];
            self.changed.broadcast(self.io);
        }
    }

    //
    // Ends the cache branch: normally at the end of the origin stream, or with a failure.
    //
    fn finish(self: *CachePipe, failed: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.ended) {
            self.ended = true;
            self.failed = failed;
        }
        self.changed.broadcast(self.io);
    }

    //
    // Records that the cache write stopped reading.
    //
    fn finishReading(self: *CachePipe) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.readerDone = true;
        self.changed.broadcast(self.io);
    }

    //
    // The std.Io.Reader stream function of the cache branch.
    //
    fn streamFunction(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *CachePipe = @alignCast(@fieldParentPtr("interface", reader));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (self.queued == 0 and !self.ended) {
            self.changed.waitUncancelable(self.io, &self.mutex);
        }
        if (self.failed) {
            return error.ReadFailed;
        }
        if (self.queued == 0) {
            return error.EndOfStream;
        }
        const count = try writer.write(limit.sliceConst(self.queue[0..self.queued]));
        std.mem.copyForwards(u8, self.queue[0 .. self.queued - count], self.queue[count..self.queued]);
        self.queued -= count;
        self.changed.broadcast(self.io);
        return count;
    }
};

//
// The caller's branch of a tee (TypeScript: the callerStream PassThrough): reads the origin stream and hands each
// chunk to the cache branch as well.
//
const TeeStream = struct {
    // Allocates the stream.
    allocator: std.mem.Allocator,

    // The io of the read.
    io: std.Io,

    // The stream of the file in the origin storage.
    originStream: IReadStream,

    // The cache branch.
    cachePipe: CachePipe,

    // The reader the caller reads from.
    interface: std.Io.Reader,

    // The concurrent cache write.
    cacheWrite: std.Io.Future(void),

    //
    // The IReadStream functions of the caller's branch.
    //
    const read_stream_vtable: IReadStream.VTable = .{
        .reader = readerFunction,
        .destroy = destroyFunction,
    };

    //
    // Gets the caller's reader.
    //
    fn readerFunction(ptr: *anyopaque) *std.Io.Reader {
        const self: *TeeStream = @ptrCast(@alignCast(ptr));
        return &self.interface;
    }

    //
    // Ends the cache branch (as a failure when the origin was not read to its end), waits for the cache write and
    // releases the origin stream.
    //
    fn destroyFunction(ptr: *anyopaque, io: std.Io) void {
        const self: *TeeStream = @ptrCast(@alignCast(ptr));
        self.cachePipe.finish(true);
        self.cacheWrite.await(io);
        self.originStream.destroy(io);
    }

    //
    // The std.Io.Reader stream function of the caller's branch: forwards data from origin to both branches.
    //
    fn streamFunction(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *TeeStream = @alignCast(@fieldParentPtr("interface", reader));
        const destination = limit.slice(try writer.writableSliceGreedy(1));
        const count = self.originStream.reader().readSliceShort(destination) catch {
            self.cachePipe.finish(true);
            return error.ReadFailed;
        };
        if (count == 0) {
            self.cachePipe.finish(false);
            return error.EndOfStream;
        }
        self.cachePipe.push(destination[0..count]);
        writer.advance(count);
        return count;
    }
};
