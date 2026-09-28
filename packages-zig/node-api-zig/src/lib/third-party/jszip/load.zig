//
// Port of JSZip 3.10.1 lib/load.js: loads a zip from a Node Buffer, with the default options.
//
// JSZip (c) 2009-2016 Stuart Knightley, David Duponchel, Franz Buchinger, António Afonso, MIT license.
//

const std = @import("std");
const utils = @import("utils.zig");
const errors = @import("utils-zig").errors;
const ZipEntries = @import("zipEntries.zig").ZipEntries;
const object = @import("object.zig");
const Files = object.Files;

// Not ported: checkEntryCRC32 (checkCRC32 is off by default, and Photosphere does not turn it on).

//
// Loads the zip into the files (JSZip: `zip.loadAsync(data)` resolving to the zip).
//
pub fn load(allocator: std.mem.Allocator, files: *Files, data: []const u8) !void {
    var zipEntries: ZipEntries = .{
        .allocator = allocator,
    };
    try zipEntries.load(data);

    for (zipEntries.files.items) |input| {
        const safeName = try utils.resolve(allocator, input.fileNameStr);

        try object.fileAdd(allocator, files, safeName, input.decompressed.?, .{
            .date = input.date,
            .dir = input.dir,
            .unixPermissions = input.unixPermissions,
            .dosPermissions = input.dosPermissions,
        });

        // JSZip: `if (!input.dir) { zip.file(safeName).unsafeOriginalName = unsafeName; }`. zip.file(name) gives null
        // for a folder, so this throws when the entry's unix permissions made fileAdd store it as a folder.
        if (!input.dir) {
            if (files.get(safeName) == null) {
                return errors.throwError("TypeError: Cannot set properties of null (setting 'unsafeOriginalName')", .{});
            }
        }
    }
}
