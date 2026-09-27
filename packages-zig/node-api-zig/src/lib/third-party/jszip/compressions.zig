//
// Port of JSZip 3.10.1 lib/compressions.js: the compressions a zip entry can use.
//
// JSZip (c) 2009-2016 Stuart Knightley, David Duponchel, Franz Buchinger, António Afonso, MIT license.
//

const std = @import("std");
const flate = @import("flate.zig");

//
// A compression JSZip knows (only uncompressing is ported).
//
pub const ICompression = struct {
    // The compression method as it is stored in a zip (two bytes, little endian).
    magic: []const u8,

    // Uncompresses the whole content (JSZip: the uncompressWorker the content is piped through).
    uncompress: *const fn (allocator: std.mem.Allocator, compressedContent: []const u8) anyerror![]u8,
};

//
// The STORE uncompressWorker: a GenericWorker that hands its input on unchanged.
//
fn storeUncompress(allocator: std.mem.Allocator, compressedContent: []const u8) anyerror![]u8 {
    return allocator.dupe(u8, compressedContent);
}

//
// No compression.
//
pub const STORE: ICompression = .{
    .magic = "\x00\x00",
    .uncompress = storeUncompress,
};

//
// DEFLATE, through flate.js.
//
pub const DEFLATE: ICompression = .{
    .magic = flate.magic,
    .uncompress = flate.uncompress,
};

//
// The compressions in the order JSZip's findCompression looks through them.
//
pub const all = [_]*const ICompression{
    &STORE,
    &DEFLATE,
};
