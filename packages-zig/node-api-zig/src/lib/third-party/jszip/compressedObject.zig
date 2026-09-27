//
// Port of JSZip 3.10.1 lib/compressedObject.js: only getContentWorker, which reading an entry uses.
//
// JSZip (c) 2009-2016 Stuart Knightley, David Duponchel, Franz Buchinger, António Afonso, MIT license.
//

const std = @import("std");
const utils_zig = @import("utils-zig");
const compressions = @import("compressions.zig");
const errors = utils_zig.errors;
const ICompression = compressions.ICompression;

//
// Represent a compressed object, with everything needed to decompress it.
//
pub const CompressedObject = struct {
    // The size of the data compressed.
    compressedSize: i64,

    // The size of the data after decompression.
    uncompressedSize: i64,

    // The crc32 of the decompressed file.
    crc32: i64,

    // The type of compression, see lib/compressions.js.
    compression: *const ICompression,

    // The compressed data.
    compressedContent: []const u8,

    //
    // Gets the uncompressed content (JSZip: the result of the worker getContentWorker returns, a DataWorker piped
    // through the compression's uncompressWorker and a DataLengthProbe, whose "end" listener checks the length).
    //
    pub fn getContent(self: *const CompressedObject, allocator: std.mem.Allocator) ![]u8 {
        const data = try self.compression.uncompress(allocator, self.compressedContent);
        if (@as(i64, @intCast(data.len)) != self.uncompressedSize) {
            return errors.throwError("Bug : uncompressed data size mismatch", .{});
        }
        return data;
    }
};
