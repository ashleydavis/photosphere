const std = @import("std");

//
// Builds the zip files the tests scan and read. (Imported by path by the test files that need it.)
//

//
// One entry of a zip the tests build (TypeScript: what is added with `zip.file` and `zip.folder`).
//
pub const IZipEntry = struct {
    // The name of the entry in the zip ("folder/" for a folder).
    name: []const u8,

    // The contents of a file.
    data: []const u8 = "",
};

//
// Builds a zip of the given entries, stored without compression, the way JSZip's generateAsync writes one by
// default. (Zig: the Zig port of JSZip reads zips and does not write them, so the tests write their fixtures
// themselves. Folder entries are added for every folder a file name goes through, as JSZip's createFolders does.)
//
pub fn buildZip(allocator: std.mem.Allocator, entries: []const IZipEntry) ![]u8 {
    var allEntries: std.ArrayList(IZipEntry) = .empty;
    for (entries) |entry| {
        var slashIndex: usize = 0;
        while (std.mem.indexOfScalarPos(u8, entry.name, slashIndex, '/')) |found| {
            const folderName = entry.name[0 .. found + 1];
            var known = false;
            for (allEntries.items) |existing| {
                if (std.mem.eql(u8, existing.name, folderName)) {
                    known = true;
                }
            }
            if (!known and found + 1 < entry.name.len) {
                try allEntries.append(allocator, .{ .name = folderName });
            }
            slashIndex = found + 1;
        }
        try allEntries.append(allocator, entry);
    }

    var output: std.ArrayList(u8) = .empty;
    var centralDirectory: std.ArrayList(u8) = .empty;
    // 2020-01-01 00:00:00 in DOS form.
    const dosTime: u16 = 0;
    const dosDate: u16 = ((2020 - 1980) << 9) | (1 << 5) | 1;
    for (allEntries.items) |entry| {
        const isFolder = std.mem.endsWith(u8, entry.name, "/");
        const crc = std.hash.Crc32.hash(entry.data);
        const offset: u32 = @intCast(output.items.len);
        try writeInt(allocator, &output, u32, 0x04034b50);
        try writeInt(allocator, &output, u16, 10);
        try writeInt(allocator, &output, u16, 0);
        try writeInt(allocator, &output, u16, 0);
        try writeInt(allocator, &output, u16, dosTime);
        try writeInt(allocator, &output, u16, dosDate);
        try writeInt(allocator, &output, u32, crc);
        try writeInt(allocator, &output, u32, @intCast(entry.data.len));
        try writeInt(allocator, &output, u32, @intCast(entry.data.len));
        try writeInt(allocator, &output, u16, @intCast(entry.name.len));
        try writeInt(allocator, &output, u16, 0);
        try output.appendSlice(allocator, entry.name);
        try output.appendSlice(allocator, entry.data);

        try writeInt(allocator, &centralDirectory, u32, 0x02014b50);
        try writeInt(allocator, &centralDirectory, u16, 0x0014);
        try writeInt(allocator, &centralDirectory, u16, 10);
        try writeInt(allocator, &centralDirectory, u16, 0);
        try writeInt(allocator, &centralDirectory, u16, 0);
        try writeInt(allocator, &centralDirectory, u16, dosTime);
        try writeInt(allocator, &centralDirectory, u16, dosDate);
        try writeInt(allocator, &centralDirectory, u32, crc);
        try writeInt(allocator, &centralDirectory, u32, @intCast(entry.data.len));
        try writeInt(allocator, &centralDirectory, u32, @intCast(entry.data.len));
        try writeInt(allocator, &centralDirectory, u16, @intCast(entry.name.len));
        try writeInt(allocator, &centralDirectory, u16, 0);
        try writeInt(allocator, &centralDirectory, u16, 0);
        try writeInt(allocator, &centralDirectory, u16, 0);
        try writeInt(allocator, &centralDirectory, u16, 0);
        try writeInt(allocator, &centralDirectory, u32, if (isFolder) 0x10 else 0);
        try writeInt(allocator, &centralDirectory, u32, offset);
        try centralDirectory.appendSlice(allocator, entry.name);
    }
    const centralDirectoryOffset: u32 = @intCast(output.items.len);
    try output.appendSlice(allocator, centralDirectory.items);
    try writeInt(allocator, &output, u32, 0x06054b50);
    try writeInt(allocator, &output, u16, 0);
    try writeInt(allocator, &output, u16, 0);
    try writeInt(allocator, &output, u16, @intCast(allEntries.items.len));
    try writeInt(allocator, &output, u16, @intCast(allEntries.items.len));
    try writeInt(allocator, &output, u32, @intCast(centralDirectory.items.len));
    try writeInt(allocator, &output, u32, centralDirectoryOffset);
    try writeInt(allocator, &output, u16, 0);
    return output.items;
}

//
// Appends a little-endian integer.
//
fn writeInt(allocator: std.mem.Allocator, output: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try output.appendSlice(allocator, &bytes);
}

