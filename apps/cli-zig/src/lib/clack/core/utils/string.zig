const std = @import("std");

//
// Returns the indexes of the lines that differ between two frames, or null when the frames are equal.
//
pub fn diffLines(allocator: std.mem.Allocator, previous: []const u8, next: []const u8) !?[]const usize {
    if (std.mem.eql(u8, previous, next)) {
        return null;
    }

    var aLines: std.ArrayList([]const u8) = .empty;
    var aIterator = std.mem.splitScalar(u8, previous, '\n');
    while (aIterator.next()) |line| {
        try aLines.append(allocator, line);
    }
    var bLines: std.ArrayList([]const u8) = .empty;
    var bIterator = std.mem.splitScalar(u8, next, '\n');
    while (bIterator.next()) |line| {
        try bLines.append(allocator, line);
    }
    var diff: std.ArrayList(usize) = .empty;

    const count = @max(aLines.items.len, bLines.items.len);
    var index: usize = 0;
    while (index < count) {
        const aLine: ?[]const u8 = if (index < aLines.items.len) aLines.items[index] else null;
        const bLine: ?[]const u8 = if (index < bLines.items.len) bLines.items[index] else null;
        const same = if (aLine != null and bLine != null) std.mem.eql(u8, aLine.?, bLine.?) else aLine == null and bLine == null;
        if (!same) {
            try diff.append(allocator, index);
        }
        index += 1;
    }

    return diff.items;
}
