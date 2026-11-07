//
// Port of JSZip 3.10.1 lib/utils.js: only resolve, pretty and the MAX_VALUE constants, which loading a zip uses.
//
// JSZip (c) 2009-2016 Stuart Knightley, David Duponchel, Franz Buchinger, António Afonso, MIT license.
//

const std = @import("std");

//
// The largest 16-bit value, which marks a field of the end of central directory that is in the zip64 record instead.
//
pub const MAX_VALUE_16BITS: i64 = 65535;

//
// "\xFF\xFF\xFF\xFF" as DataReader.readInt reads it: well, "\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF" is parsed as -1.
//
pub const MAX_VALUE_32BITS: i64 = -1;

//
// Resolve all relative path components, "." and "..", in a path. If these relative components
// traverse above the root then the resulting path will only contain the final path component.
//
// All empty components, e.g. "//", are removed.
//
pub fn resolve(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var splitParts = std.mem.splitScalar(u8, path, '/');
    while (splitParts.next()) |part| {
        try parts.append(allocator, part);
    }
    var result: std.ArrayList([]const u8) = .empty;
    for (parts.items, 0..) |part, index| {
        // Allow the first and last component to be empty for trailing slashes.
        if (std.mem.eql(u8, part, ".") or (part.len == 0 and index != 0 and index != parts.items.len - 1)) {
            continue;
        }
        else if (std.mem.eql(u8, part, "..")) {
            _ = result.pop();
        }
        else {
            try result.append(allocator, part);
        }
    }
    return std.mem.join(allocator, "/", result.items);
}

//
// Prettify a string read as binary: each byte as "\x" and two upper-case hex digits.
//
pub fn pretty(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    for (text) |code| {
        try result.print(allocator, "\\x{s}{X}", .{ if (code < 16) "0" else "", code });
    }
    return result.items;
}
