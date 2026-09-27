//
// Tests for the comparison of saved tree files with golden fixtures (no TypeScript counterpart).
//

const std = @import("std");
const saved_file = @import("saved-file.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// The data of a fixture: a byte, then the gzip member Bun's gzipSync at level 9 writes on Linux for "a", then a byte.
//
const fixture_data = [_]u8{ 0xaa, 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x03, 0x4b, 0x04, 0x00, 0x43, 0xbe, 0xb7, 0xe8, 0x01, 0x00, 0x00, 0x00, 0x55 };

//
// The index of the OS field of the gzip member in fixture_data.
//
const os_index = 10;

//
// Returns data followed by the SHA-256 of the data, as a saved file.
//
fn savedFile(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var checksum: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &checksum, .{});
    return std.mem.concat(allocator, u8, &.{ data, &checksum });
}

//
// Returns the fixture data with the OS field set to this platform's OS_CODE, as this platform saves it.
//
fn platformData() [fixture_data.len]u8 {
    var data = fixture_data;
    data[os_index] = saved_file.platformOsCode();
    return data;
}

test "a file saved on this platform matches the fixture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const data = platformData();
    try std.testing.expectEqual(@as(?[]const u8, null), saved_file.findSavedFileDifference(try savedFile(allocator, &fixture_data), try savedFile(allocator, &data)));
}

test "a gzip member OS field other than this platform's OS_CODE is a difference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var data = platformData();
    data[os_index] +%= 1;
    try std.testing.expectEqualStrings("a gzip member OS field is not this platform's OS_CODE", saved_file.findSavedFileDifference(try savedFile(allocator, &fixture_data), try savedFile(allocator, &data)).?);
}

test "a gzip member header field other than OS is a difference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var data = platformData();
    data[os_index - 1] = 0x04;
    try std.testing.expectEqualStrings("a gzip member header field differs", saved_file.findSavedFileDifference(try savedFile(allocator, &fixture_data), try savedFile(allocator, &data)).?);
}

test "a data byte outside a gzip member header is a difference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var data = platformData();
    data[data.len - 1] = 0x56;
    try std.testing.expectEqualStrings("the data differs", saved_file.findSavedFileDifference(try savedFile(allocator, &fixture_data), try savedFile(allocator, &data)).?);
}

test "a checksum that is not the SHA-256 of the data is a difference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const data = platformData();
    const actual = try savedFile(allocator, &data);
    actual[actual.len - 1] +%= 1;
    try std.testing.expectEqualStrings("the checksum is not the SHA-256 of the data", saved_file.findSavedFileDifference(try savedFile(allocator, &fixture_data), actual).?);
}

test "files of different lengths differ" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const data = platformData();
    try std.testing.expectEqualStrings("the lengths differ", saved_file.findSavedFileDifference(try savedFile(allocator, &fixture_data), try savedFile(allocator, data[1..])).?);
}
