const std = @import("std");
const utils = @import("utils-zig");
const s3_client = @import("s3-client.zig");
const storage_module = @import("storage.zig");

const retry = utils.retry.retry;
const S3Client = s3_client.S3Client;
const IReadStream = storage_module.IReadStream;

//
// Chunk sizes to attempt for range requests, in order.
// On failure the stream falls back to the next smaller size.
//
pub const CHUNK_SIZES = [_]u64{
    100 * 1024 * 1024, // 100 MB: start large to minimise round-trips
    20 * 1024 * 1024, // 20 MB
    10 * 1024 * 1024, // 10 MB
};

//
// Per-attempt timeout for downloading a single chunk (5 minutes).
// Covers both the S3 request and the full body read.
//
const CHUNK_TIMEOUT = 5 * 60 * 1_000;

//
// The size of the buffer of the reader interface.
//
const reader_buffer_length = 64 * 1024;

//
// A readable stream that fetches an S3 object in fixed-size chunks
// using HTTP range requests. Each chunk is fully consumed before the next
// request is made, so no S3 response stream is held open between reads.
// This prevents the memory leaks caused by holding a long-lived S3 body stream.
//
// NOTE: Breaking up an S3 download into multiple HTTP requests makes it really slow.
//
// (Zig: a pull-based std.Io.Reader; `_read` runs when the reader needs more data. Chunk buffers are allocated with the
// page allocator and freed when the next chunk arrives or the stream is destroyed.)
//
pub const S3RangeReadableStream = struct {
    // The reader interface that consumers read the object's bytes from.
    interface: std.Io.Reader,

    // Allocates the stream and the request data.
    allocator: std.mem.Allocator,

    // Used for the range requests.
    io: std.Io,

    // The S3 client.
    s3: *S3Client,

    // The bucket.
    bucket: []const u8,

    // The object key.
    key: []const u8,

    //
    // The current byte offset into the file.
    //
    offset: u64,

    //
    // The total size of the file in bytes, extracted from the first range response.
    //
    fileSize: ?u64,

    //
    // Index into CHUNK_SIZES for the next request. Advances when a chunk fails
    // so subsequent chunks use a smaller size.
    //
    chunkSizeIndex: usize,

    // The current chunk.
    chunk: []u8,

    // Owns the memory of the current chunk (null when there is none).
    chunkArena: ?*std.heap.ArenaAllocator,

    // The number of bytes of `chunk` already read.
    chunkOffset: usize,

    // True once the end of the stream was reached (TypeScript: `this.push(null)`).
    ended: bool,

    // The error that stopped the stream, if any (TypeScript: `this.destroy(err)`).
    err: ?anyerror,

    //
    // Creates the stream (TypeScript: `new S3RangeReadableStream(s3, bucket, key)`).
    //
    pub fn init(allocator: std.mem.Allocator, io: std.Io, s3: *S3Client, bucket: []const u8, key: []const u8) !*S3RangeReadableStream {
        const self = try allocator.create(S3RangeReadableStream);
        self.* = .{
            .interface = .{
                .vtable = &.{ .stream = streamFunction },
                .buffer = try allocator.alloc(u8, reader_buffer_length),
                .seek = 0,
                .end = 0,
            },
            .allocator = allocator,
            .io = io,
            .s3 = s3,
            .bucket = bucket,
            .key = key,
            .offset = 0,
            .fileSize = null,
            .chunkSizeIndex = 0,
            .chunk = &.{},
            .chunkArena = null,
            .chunkOffset = 0,
            .ended = false,
            .err = null,
        };
        return self;
    }

    //
    // Gets the reader that yields the object's bytes.
    //
    pub fn reader(self: *S3RangeReadableStream) *std.Io.Reader {
        return &self.interface;
    }

    //
    // Releases the stream (TypeScript: `destroy()`); no further requests are made.
    //
    pub fn destroy(self: *S3RangeReadableStream, io: std.Io) void {
        _ = io;
        self.freeChunk();
        self.ended = true;
        self.allocator.free(self.interface.buffer);
        self.allocator.destroy(self);
    }

    //
    // Gets the IReadStream interface of this stream.
    //
    pub fn readStream(self: *S3RangeReadableStream) IReadStream {
        return .{ .ptr = self, .vtable = storage_module.implementReadStream(S3RangeReadableStream) };
    }

    //
    // Frees the current chunk.
    //
    fn freeChunk(self: *S3RangeReadableStream) void {
        if (self.chunkArena) |chunkArena| {
            chunkArena.deinit();
            std.heap.page_allocator.destroy(chunkArena);
        }
        self.chunkArena = null;
        self.chunk = &.{};
        self.chunkOffset = 0;
    }

    //
    // One attempt at fetching the next chunk (the function passed to retry in TypeScript).
    //
    const ChunkAttempt = struct {
        // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
        pub const source = "async () => {\n        successfulChunkIndex = nextChunkIndex;\n        nextChunkIndex = Math.min(nextChunkIndex + 1, CHUNK_SIZES.length - 1);\n        const chunkSize = CHUNK_SIZES[successfulChunkIndex];\n        requestedChunkSize = chunkSize;\n        const rangeStart = this.offset, rangeEnd = rangeStart + chunkSize - 1, response = await this.s3.send(new GetObjectCommand({\n          Bucket: this.bucket,\n          Key: this.key,\n          Range: `bytes=${rangeStart}-${rangeEnd}`\n        }));\n        if (this.fileSize === void 0 && response.ContentRange) {\n          const match = response.ContentRange.match(/\\/(\\d+)$/);\n          if (match)\n            this.fileSize = parseInt(match[1], 10);\n        }\n        if (!response.Body)\n          return;\n        return await response.Body.transformToByteArray();\n      }";

        // The stream.
        stream: *S3RangeReadableStream,

        // The chunk index used by the most recent attempt.
        successfulChunkIndex: usize,

        // The chunk index the next attempt uses.
        nextChunkIndex: usize,

        // How many bytes the successful attempt asked for, used to detect the end of the object
        // when the response carries no usable Content-Range.
        requestedChunkSize: u64,

        //
        // Fetches one chunk; returns null when the response has no body.
        //
        pub fn run(self: *ChunkAttempt, io: std.Io) !?ChunkData {
            const stream = self.stream;
            self.successfulChunkIndex = self.nextChunkIndex;
            self.nextChunkIndex = @min(self.nextChunkIndex + 1, CHUNK_SIZES.len - 1);

            const chunkSize = CHUNK_SIZES[self.successfulChunkIndex];
            self.requestedChunkSize = chunkSize;
            const rangeStart = stream.offset;
            const rangeEnd = rangeStart + chunkSize - 1;

            const arena = try std.heap.page_allocator.create(std.heap.ArenaAllocator);
            arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            var keepArena = false;
            defer {
                if (!keepArena) {
                    arena.deinit();
                    std.heap.page_allocator.destroy(arena);
                }
            }
            const requestAllocator = arena.allocator();
            const range = try std.fmt.allocPrint(requestAllocator, "bytes={d}-{d}", .{ rangeStart, rangeEnd });
            const response = try stream.s3.getObject(requestAllocator, io, stream.bucket, stream.key, range);

            if (stream.fileSize == null) {
                if (response.ContentRange) |contentRange| {
                    if (std.mem.lastIndexOfScalar(u8, contentRange, '/')) |slashIndex| {
                        stream.fileSize = std.fmt.parseInt(u64, contentRange[slashIndex + 1 ..], 10) catch null;
                    }
                }
            }

            const body = response.Body orelse {
                return null;
            };
            keepArena = true;
            return .{ .arena = arena, .body = body };
        }
    };

    //
    // A fetched chunk and the arena that owns it.
    //
    const ChunkData = struct {
        // Owns the body.
        arena: *std.heap.ArenaAllocator,

        // The bytes of the chunk.
        body: []u8,
    };

    //
    // Called when the consumer is ready for more data.
    // Fetches the next chunk via a range request.
    // Each attempt is raced against CHUNK_TIMEOUT; on failure the chunk size
    // is reduced before the next attempt.
    //
    fn _read(self: *S3RangeReadableStream) !void {
        // If we know the file size and have read all bytes, signal end-of-stream.
        if (self.fileSize != null and self.offset >= self.fileSize.?) {
            self.ended = true;
            return;
        }

        //
        // Retry getting the next chunk 3 times.
        // We down size the chunk size each time just in case it's a memory issue.
        // It could also be a connectivity issue.
        //
        var attempt: ChunkAttempt = .{
            .stream = self,
            .successfulChunkIndex = self.chunkSizeIndex,
            .nextChunkIndex = self.chunkSizeIndex,
            .requestedChunkSize = 0,
        };
        const chunkData = try retry(self.io, &attempt, 3, 100, 2, CHUNK_TIMEOUT, null);

        // Persist the chunk size that succeeded so future chunks use the same or smaller size.
        self.chunkSizeIndex = attempt.successfulChunkIndex;

        const data = chunkData orelse {
            self.ended = true;
            return;
        };

        self.offset += data.body.len;
        self.freeChunk();
        self.chunk = data.body;
        self.chunkArena = data.arena;

        // If this chunk brings us to the end of the file, signal end-of-stream.
        if (self.fileSize != null and self.offset >= self.fileSize.?) {
            self.ended = true;
        }
        else if (data.body.len < attempt.requestedChunkSize) {
            // A range request that comes back with fewer bytes than it asked for has reached the
            // end of the object, so this is the last chunk.
            //
            // The file size is normally learned from the Content-Range header, but it is not
            // always available: on the mobile worker the response reaches the SDK through the
            // native HTTP bridge without it, so fileSize stays undefined and the check above can
            // never fire. Without this the stream kept requesting ranges past the end of the
            // object and never ended, and every read from S3 on a device hung until its caller
            // timed out.
            self.ended = true;
        }
    }

    //
    // The std.Io.Reader stream function: serves the current chunk, fetching the next one when it runs out.
    //
    fn streamFunction(readerInterface: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *S3RangeReadableStream = @alignCast(@fieldParentPtr("interface", readerInterface));
        while (self.chunkOffset == self.chunk.len) {
            if (self.err != null) {
                return error.ReadFailed;
            }
            if (self.ended) {
                return error.EndOfStream;
            }
            self._read() catch |err| {
                self.err = err;
                return error.ReadFailed;
            };
        }
        const available = self.chunk[self.chunkOffset..];
        const count = try writer.write(limit.sliceConst(available));
        self.chunkOffset += count;
        return count;
    }
};
