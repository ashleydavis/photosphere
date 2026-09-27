//
// Port of JSZip 3.10.1 lib/zipObject.js: only what reading a loaded entry as a Node Buffer uses.
//
// JSZip (c) 2009-2016 Stuart Knightley, David Duponchel, Franz Buchinger, António Afonso, MIT license.
//

const std = @import("std");
const compressedObject = @import("compressedObject.zig");
const CompressedObject = compressedObject.CompressedObject;

//
// A simple object representing a file in the zip file.
//
pub const ZipObject = struct {
    // The name of the file.
    name: []const u8,

    // Whether the entry is a folder.
    dir: bool,

    // The date of the file (milliseconds since the epoch, like the time of a JavaScript Date).
    date: i64,

    // The data: the entry's compressed object, or null for the empty string fileAdd stores for a folder or an empty
    // entry.
    _data: ?CompressedObject,

    // Not ported: comment, unixPermissions, dosPermissions, _dataBinary and options (not read by Photosphere).

    //
    // Prepare the content in the asked type (only "nodebuffer" is ported, as the Zig bytes).
    //
    pub fn asyncNodeBuffer(self: *const ZipObject, allocator: std.mem.Allocator) ![]u8 {
        return self._decompressWorker(allocator);
    }

    //
    // Return the decompressed content (JSZip: a worker for it).
    //
    fn _decompressWorker(self: *const ZipObject, allocator: std.mem.Allocator) ![]u8 {
        if (self._data) |data| {
            return data.getContent(allocator);
        }
        return allocator.alloc(u8, 0);
    }
};
