//
// Port of JSZip 3.10.1 lib/flate.js: only the inflate side (uncompressWorker), which reading a zip uses.
//
// JSZip (c) 2009-2016 Stuart Knightley, David Duponchel, Franz Buchinger, António Afonso, MIT license.
//
// JSZip inflates with pako 1.0.11, a JavaScript port of zlib, as `new pako.Inflate({ raw: true })`. Here zlib-ng, the
// zlib that pako is a port of (built from its upstream sources by serialization-zig), does the inflating, and the
// loop around it is pako's Inflate.push: the input arrives in the 16 KiB chunks JSZip's DataWorker produces, output is
// gathered 16 KiB at a time (pako's chunkSize), and a chunk is only handed on when it is full, at the end of the
// stream, or when the input runs out on the final push. On an error pako stops and hands on nothing more, and
// FlateWorker ignores that, so what was inflated before the error is what the next worker sees.
//

const std = @import("std");
const serialization_zig = @import("serialization-zig");
const zlib = serialization_zig.zlib;

//
// The compression method magic of DEFLATE.
//
pub const magic = "\x08\x00";

//
// The size of the chunks JSZip's DataWorker cuts data into (stream/DataWorker.js DEFAULT_BLOCK_SIZE).
//
const DEFAULT_BLOCK_SIZE = 16 * 1024;

//
// The size of the output chunks pako gathers (pako's default chunkSize).
//
const PAKO_CHUNK_SIZE = 16384;

//
// Inflates raw DEFLATE data the way FlateWorker("Inflate") does when DataWorker feeds it the whole compressed content
// (the uncompressWorker of this compression). Returns what the worker pushes on.
//
pub fn uncompress(allocator: std.mem.Allocator, compressedContent: []const u8) ![]u8 {
    var inflate: PakoInflate = undefined;
    try inflate.init(allocator);
    defer inflate.deinit();

    // processChunk for each chunk DataWorker emits.
    var offset: usize = 0;
    while (offset < compressedContent.len) {
        const end = @min(offset + DEFAULT_BLOCK_SIZE, compressedContent.len);
        _ = try inflate.push(compressedContent[offset..end], false);
        offset = end;
    }

    // flush.
    _ = try inflate.push(&.{}, true);
    return inflate.output.toOwnedSlice(allocator);
}

//
// pako's Inflate object with the options FlateWorker gives it (`{ raw: true }`), inflating with zlib-ng.
//
const PakoInflate = struct {
    // Allocates the output.
    allocator: std.mem.Allocator,

    // The zlib stream.
    strm: zlib.z_stream,

    // The chunk being filled (pako: strm.output).
    chunk: [PAKO_CHUNK_SIZE]u8,

    // How much of the chunk has been filled (pako: strm.next_out).
    nextOut: usize,

    // How much room is left in the chunk (pako: strm.avail_out).
    availOut: usize,

    // Everything handed on through onData.
    output: std.ArrayList(u8),

    // Set once the stream has ended or failed.
    ended: bool,

    //
    // Creates the inflater (pako: `new Inflate({ raw: true })`, windowBits -15).
    // (Zig: initialised in place, because zlib keeps a pointer back to the stream and checks it on every call.)
    //
    fn init(self: *PakoInflate, allocator: std.mem.Allocator) !void {
        self.* = .{
            .allocator = allocator,
            .strm = std.mem.zeroes(zlib.z_stream),
            .chunk = undefined,
            .nextOut = 0,
            .availOut = 0,
            .output = .empty,
            .ended = false,
        };
        const status = zlib.inflateInit2_(&self.strm, -15, zlib.ZLIB_VERSION, @sizeOf(zlib.z_stream));
        if (status != zlib.Z_OK) {
            return error.OutOfMemory;
        }
    }

    //
    // Frees the zlib state.
    //
    fn deinit(self: *PakoInflate) void {
        if (!self.ended) {
            _ = zlib.inflateEnd(&self.strm);
        }
    }

    //
    // pako's Inflate.push: inflates the data and hands on full chunks (and the rest at the end).
    // Returns false when the stream has already ended or has failed.
    //
    fn push(self: *PakoInflate, data: []const u8, finish: bool) !bool {
        // Flag to properly process Z_BUF_ERROR on testing inflate call
        // when we check that all output data was flushed.
        var allowBufError = false;

        if (self.ended) {
            return false;
        }

        self.strm.next_in = @constCast(data.ptr);
        self.strm.avail_in = @intCast(data.len);

        var status: c_int = zlib.Z_OK;
        while (true) {
            if (self.availOut == 0) {
                self.nextOut = 0;
                self.availOut = PAKO_CHUNK_SIZE;
            }

            self.strm.next_out = self.chunk[self.nextOut..].ptr;
            self.strm.avail_out = @intCast(self.availOut);
            status = zlib.inflate(&self.strm, zlib.Z_NO_FLUSH); // no bad return value
            self.nextOut = PAKO_CHUNK_SIZE - self.strm.avail_out;
            self.availOut = self.strm.avail_out;

            if (status == zlib.Z_BUF_ERROR and allowBufError) {
                status = zlib.Z_OK;
                allowBufError = false;
            }

            if (status != zlib.Z_STREAM_END and status != zlib.Z_OK) {
                self.onEnd();
                return false;
            }

            if (self.nextOut > 0) {
                if (self.availOut == 0 or status == zlib.Z_STREAM_END or (self.strm.avail_in == 0 and finish)) {
                    try self.output.appendSlice(self.allocator, self.chunk[0..self.nextOut]);
                }
            }

            // When no more input data, we should check that internal inflate buffers
            // are flushed. The only way to do it when avail_out = 0 - run one more
            // inflate pass. But if output data not exists, inflate return Z_BUF_ERROR.
            // Here we set flag to process this error properly.
            if (self.strm.avail_in == 0 and self.availOut == 0) {
                allowBufError = true;
            }

            if (!((self.strm.avail_in > 0 or self.availOut == 0) and status != zlib.Z_STREAM_END)) {
                break;
            }
        }

        // Finalize on the last chunk.
        if (status == zlib.Z_STREAM_END or finish) {
            self.onEnd();
            return true;
        }

        return true;
    }

    //
    // Ends the stream (pako: inflateEnd and onEnd).
    //
    fn onEnd(self: *PakoInflate) void {
        _ = zlib.inflateEnd(&self.strm);
        self.ended = true;
    }
};
