//
// Compares a tree file saved on this platform with a golden fixture Bun saved on Linux (no TypeScript counterpart).
//
// A saved file is [data][SHA-256 checksum of data]. The data holds gzip members (RFC 1952), whose 10-byte header ends
// with an OS field that zlib-ng sets to the OS_CODE of the platform it is compiled for (zutil.h): 10 on Windows, 19
// on macOS (__APPLE__) and 3 (Unix) elsewhere. So a file saved on macOS or Windows differs from the Linux fixture in
// the OS field of each gzip member and therefore in its checksum. The comparison checks that the data equals the
// fixture's byte for byte, except that where the fixture has a gzip member header the file has this platform's
// OS_CODE, and that each checksum is the SHA-256 of its own data.
//

const std = @import("std");
const builtin = @import("builtin");
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// The index of the OS field in a gzip member header.
//
const os_byte_index = 9;

//
// The gzip member header of every golden fixture, as Bun's gzipSync at level 9 writes it on Linux: ID1 0x1f, ID2
// 0x8b, CM 8 (deflate), FLG 0, MTIME 0, XFL 2 (maximum compression) and OS 3.
//
const fixture_header = [_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x03 };

//
// The gzip header OS field zlib-ng writes on the platform the tests run on (OS_CODE of zutil.h).
//
pub fn platformOsCode() u8 {
    return switch (builtin.os.tag) {
        .windows => 10,
        .macos => 19,
        else => 3,
    };
}

//
// Returns a description of where a file saved on this platform differs from the fixture, or null when it matches.
//
pub fn findSavedFileDifference(expected: []const u8, actual: []const u8) ?[]const u8 {
    if (expected.len != actual.len) {
        return "the lengths differ";
    }
    if (expected.len < Sha256.digest_length) {
        return "the files are too short to hold a checksum";
    }
    const dataLength = expected.len - Sha256.digest_length;
    var index: usize = 0;
    while (index < dataLength) {
        if (index + fixture_header.len <= dataLength and std.mem.eql(u8, expected[index .. index + fixture_header.len], &fixture_header)) {
            if (!std.mem.eql(u8, expected[index .. index + os_byte_index], actual[index .. index + os_byte_index])) {
                return "a gzip member header field differs";
            }
            if (actual[index + os_byte_index] != platformOsCode()) {
                return "a gzip member OS field is not this platform's OS_CODE";
            }
            index += fixture_header.len;
            continue;
        }
        if (expected[index] != actual[index]) {
            return "the data differs";
        }
        index += 1;
    }
    var checksum: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(expected[0..dataLength], &checksum, .{});
    if (!std.mem.eql(u8, &checksum, expected[dataLength..])) {
        return "the fixture's checksum is not the SHA-256 of its data";
    }
    Sha256.hash(actual[0..dataLength], &checksum, .{});
    if (!std.mem.eql(u8, &checksum, actual[dataLength..])) {
        return "the checksum is not the SHA-256 of the data";
    }
    return null;
}

//
// Checks that a file saved on this platform matches the fixture (see findSavedFileDifference).
//
pub fn expectSavedFileMatches(expected: []const u8, actual: []const u8) !void {
    if (findSavedFileDifference(expected, actual)) |difference| {
        std.debug.print("Saved file differs from the fixture: {s}\n", .{difference});
        return error.TestExpectedEqual;
    }
}
