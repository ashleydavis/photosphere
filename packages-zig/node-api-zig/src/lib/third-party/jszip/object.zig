//
// Port of JSZip 3.10.1 lib/object.js: only fileAdd with the options load.js passes, which loading a zip uses.
//
// JSZip (c) 2009-2016 Stuart Knightley, David Duponchel, Franz Buchinger, António Afonso, MIT license.
//

const std = @import("std");
const serialization_zig = @import("serialization-zig");
const compressedObject = @import("compressedObject.zig");
const zipObject = @import("zipObject.zig");
const CompressedObject = compressedObject.CompressedObject;
const ZipObject = zipObject.ZipObject;
const parseArrayIndex = serialization_zig.bson.parseArrayIndex;

//
// The options load.js adds a loaded entry with.
//
pub const IFileAddOptions = struct {
    // The date of the entry (milliseconds since the epoch).
    date: i64,

    // Whether the entry is a folder.
    dir: bool,

    // The unix permissions, when the entry was made on unix.
    unixPermissions: ?i64,

    // The DOS permissions, when the entry was made on DOS.
    dosPermissions: ?i64,

    // Not ported: binary, optimizedBinaryString, comment and createFolders (load.js passes true, true, the comment
    // and false, and none of them changes the entry Photosphere reads).
};

//
// The files of a zip (JSZip: `this.files`, a plain object keyed by name). Iterated in JavaScript property order:
// names that are array indexes first, in ascending order, then the others in the order they were added.
//
pub const Files = struct {
    // The names, in property order.
    names: std.ArrayList([]const u8) = .empty,

    // The objects by name.
    objects: std.StringHashMapUnmanaged(ZipObject) = .empty,

    //
    // Sets a file like a JS property assignment (`this.files[name] = object`): an existing name keeps its position.
    //
    pub fn put(self: *Files, allocator: std.mem.Allocator, name: []const u8, object: ZipObject) !void {
        if (self.objects.getPtr(name)) |existing| {
            existing.* = object;
            return;
        }
        try self.objects.put(allocator, name, object);
        const newIndex = parseArrayIndex(name) orelse {
            try self.names.append(allocator, name);
            return;
        };
        var position: usize = 0;
        while (position < self.names.items.len) : (position += 1) {
            const existingIndex = parseArrayIndex(self.names.items[position]) orelse {
                break;
            };
            if (existingIndex > newIndex) {
                break;
            }
        }
        try self.names.insert(allocator, position, name);
    }

    //
    // Gets a file by name.
    //
    pub fn get(self: *const Files, name: []const u8) ?ZipObject {
        return self.objects.get(name);
    }
};

//
// Returns the path with a slash at the end.
//
fn forceTrailingSlash(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    // Check the name ends with a /
    if (!std.mem.endsWith(u8, path, "/")) {
        return std.mem.concat(allocator, u8, &.{ path, "/" }); // IE doesn't like substr(-1)
    }
    return path;
}

//
// Add a file in the current folder.
//
pub fn fileAdd(allocator: std.mem.Allocator, files: *Files, originalName: []const u8, data: CompressedObject, originalOptions: IFileAddOptions) !void {
    var name = originalName;
    var dir = originalOptions.dir;

    // UNX_IFDIR  0040000 see zipinfo.c
    if (originalOptions.unixPermissions != null and originalOptions.unixPermissions.? != 0 and (originalOptions.unixPermissions.? & 0x4000) != 0) {
        dir = true;
    }
    // Bit 4    Directory
    if (originalOptions.dosPermissions != null and originalOptions.dosPermissions.? != 0 and (originalOptions.dosPermissions.? & 0x0010) != 0) {
        dir = true;
    }

    if (dir) {
        name = try forceTrailingSlash(allocator, name);
    }

    const isCompressedEmpty = data.uncompressedSize == 0;

    // A folder or an empty entry is stored as an empty string with STORE, which is not a CompressedObject.
    const zipObjectContent: ?CompressedObject = if (isCompressedEmpty or dir) null else data;

    try files.put(allocator, name, .{
        .name = name,
        .dir = dir,
        .date = originalOptions.date,
        ._data = zipObjectContent,
    });
}
