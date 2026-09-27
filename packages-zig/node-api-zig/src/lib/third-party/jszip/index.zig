//
// Port of JSZip 3.10.1 (MIT license; (c) 2009-2016 Stuart Knightley, David Duponchel, Franz Buchinger, António
// Afonso), the zip reader file-scanner.ts uses: `new JSZip()`, `loadAsync(buffer)`, `files` and a file's
// `async("nodebuffer")`, with JSZip's default load options.
//
// Only reading is ported. Inflating goes through zlib-ng (see flate.zig), where JSZip uses pako, a JavaScript port of
// zlib. Not ported: writing and generating zips, streams, the browser readers, and the options Photosphere never sets.
//

const std = @import("std");
const load_module = @import("load.zig");
const object = @import("object.zig");
pub const ZipObject = @import("zipObject.zig").ZipObject;
pub const Files = object.Files;

//
// A zip file (JSZip: the JSZip object).
//
pub const JSZip = struct {
    // Allocates everything the zip reads.
    allocator: std.mem.Allocator,

    // The files of the zip, keyed by name.
    files: Files = .{},

    //
    // Creates an empty zip (JSZip: `new JSZip()`).
    //
    pub fn init(allocator: std.mem.Allocator) JSZip {
        return .{
            .allocator = allocator,
        };
    }

    //
    // Loads a zip from its bytes (JSZip: `loadAsync(data)`, which resolves to this zip).
    //
    pub fn loadAsync(self: *JSZip, data: []const u8) !*JSZip {
        try load_module.load(self.allocator, &self.files, data);
        return self;
    }
};
