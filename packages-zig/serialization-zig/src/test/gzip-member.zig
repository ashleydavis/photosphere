//
// Compares gzip output with golden fixtures Bun generated on Linux, field by field (no TypeScript counterpart).
//
// A gzip member (RFC 1952) starts with a 10-byte header: ID1 ID2 CM FLG, a 4-byte MTIME, XFL and OS. Everything in it
// and after it is the same on every platform except OS, which zlib-ng sets to the OS_CODE of the platform it is
// compiled for (zutil.h): 10 on Windows, 19 on macOS (__APPLE__) and 3 (Unix) elsewhere. The fixtures therefore hold 3,
// and output made on macOS or Windows is compared with them field by field: every byte but OS must equal the fixture's
// and OS must be this platform's OS_CODE.
//

const std = @import("std");
const builtin = @import("builtin");

//
// The index of the OS byte in a gzip member header.
//
pub const os_byte_index = 9;

//
// The length of a gzip member header without optional fields (FLG 0, as zlib writes it for gzipSync).
//
pub const header_length = 10;

//
// The OS byte of the gzip headers in the golden fixtures: OS_CODE on Linux, where Bun generated them.
//
pub const fixture_os_code: u8 = 3;

//
// The gzip member header of every golden fixture, as Bun's gzipSync at level 9 writes it on Linux: ID1 0x1f, ID2
// 0x8b, CM 8 (deflate), FLG 0, MTIME 0, XFL 2 (maximum compression) and OS 3.
//
pub const fixture_header = [header_length]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, fixture_os_code };

//
// The gzip header OS byte zlib-ng writes on the platform the tests run on (OS_CODE of zutil.h).
//
pub fn platformOsCode() u8 {
    return switch (builtin.os.tag) {
        .windows => 10,
        .macos => 19,
        else => 3,
    };
}

//
// Where a gzip member made on this platform differs from one Bun made on Linux.
//
pub const Difference = enum {
    // One of them is too short to hold a gzip member header.
    too_short,

    // A header field before OS (ID1, ID2, CM, FLG, MTIME or XFL) differs.
    header_field,

    // The fixture's OS is not Linux's OS_CODE.
    fixture_os,

    // The actual OS is not this platform's OS_CODE.
    os,

    // The deflate data or the trailer after the header differs.
    after_header,
};

//
// Finds where a gzip member made on this platform differs from one Bun made on Linux, or null when it matches: the
// header fields before OS are equal, the fixture's OS is Linux's OS_CODE and the actual OS is this platform's, and the
// deflate data and trailer after the header are equal.
//
pub fn findDifference(expected: []const u8, actual: []const u8) ?Difference {
    if (expected.len < header_length or actual.len < header_length) {
        return .too_short;
    }
    if (!std.mem.eql(u8, expected[0..os_byte_index], actual[0..os_byte_index])) {
        return .header_field;
    }
    if (expected[os_byte_index] != fixture_os_code) {
        return .fixture_os;
    }
    if (actual[os_byte_index] != platformOsCode()) {
        return .os;
    }
    if (!std.mem.eql(u8, expected[header_length..], actual[header_length..])) {
        return .after_header;
    }
    return null;
}

//
// Finds where the header of a gzip member made on this platform differs from the fixture header, or null when it
// matches it but for an OS field holding this platform's OS_CODE.
//
pub fn findHeaderDifference(actual: []const u8) ?Difference {
    return findDifference(&fixture_header, actual[0..@min(actual.len, header_length)]);
}

//
// Checks that a gzip member made on this platform matches one Bun made on Linux (see findDifference).
//
pub fn expectGzipMemberEqual(expected: []const u8, actual: []const u8) !void {
    try std.testing.expectEqual(@as(?Difference, null), findDifference(expected, actual));
}

//
// Checks that a gzip member made on this platform starts with the fixture header but for this platform's OS byte (see
// findHeaderDifference).
//
pub fn expectFixtureHeader(actual: []const u8) !void {
    try std.testing.expectEqual(@as(?Difference, null), findHeaderDifference(actual));
}
