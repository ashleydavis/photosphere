//
// Tests for the field by field comparison of gzip members with golden fixtures (no TypeScript counterpart).
//

const std = @import("std");
const gzip_member = @import("gzip-member.zig");

//
// The gzip output of Bun's gzipSync for "a" at level 9 on Linux.
//
const fixture_of_a = gzip_member.fixture_header ++ [_]u8{ 0x4b, 0x04, 0x00, 0x43, 0xbe, 0xb7, 0xe8, 0x01, 0x00, 0x00, 0x00 };

//
// Returns a copy of the fixture of "a" with its OS byte set to this platform's OS_CODE.
//
fn fixtureOfAOnThisPlatform() [fixture_of_a.len]u8 {
    var member = fixture_of_a;
    member[gzip_member.os_byte_index] = gzip_member.platformOsCode();
    return member;
}

test "findDifference finds no difference in a member equal to the fixture but for this platform's OS byte" {
    const member = fixtureOfAOnThisPlatform();
    try std.testing.expectEqual(@as(?gzip_member.Difference, null), gzip_member.findDifference(&fixture_of_a, &member));
}

test "findDifference finds an OS byte that is not this platform's OS_CODE" {
    var member = fixtureOfAOnThisPlatform();
    member[gzip_member.os_byte_index] +%= 1;
    try std.testing.expectEqual(@as(?gzip_member.Difference, .os), gzip_member.findDifference(&fixture_of_a, &member));
}

test "findDifference finds a fixture whose OS byte is not Linux's OS_CODE" {
    var fixture = fixture_of_a;
    fixture[gzip_member.os_byte_index] = 19;
    const member = fixtureOfAOnThisPlatform();
    try std.testing.expectEqual(@as(?gzip_member.Difference, .fixture_os), gzip_member.findDifference(&fixture, &member));
}

test "findDifference finds a header field before OS that differs" {
    var member = fixtureOfAOnThisPlatform();
    // XFL.
    member[8] = 0;
    try std.testing.expectEqual(@as(?gzip_member.Difference, .header_field), gzip_member.findDifference(&fixture_of_a, &member));
}

test "findDifference finds a difference after the header" {
    var member = fixtureOfAOnThisPlatform();
    member[member.len - 1] +%= 1;
    try std.testing.expectEqual(@as(?gzip_member.Difference, .after_header), gzip_member.findDifference(&fixture_of_a, &member));
    try std.testing.expectEqual(@as(?gzip_member.Difference, .after_header), gzip_member.findDifference(&fixture_of_a, member[0 .. member.len - 1]));
}

test "findDifference finds a member too short for a gzip header" {
    const member = fixtureOfAOnThisPlatform();
    try std.testing.expectEqual(@as(?gzip_member.Difference, .too_short), gzip_member.findDifference(&fixture_of_a, member[0..9]));
}

test "findHeaderDifference accepts the fixture header with this platform's OS byte and finds other headers" {
    const member = fixtureOfAOnThisPlatform();
    try std.testing.expectEqual(@as(?gzip_member.Difference, null), gzip_member.findHeaderDifference(&member));

    var wrongOs = member;
    wrongOs[gzip_member.os_byte_index] +%= 1;
    try std.testing.expectEqual(@as(?gzip_member.Difference, .os), gzip_member.findHeaderDifference(&wrongOs));

    var wrongMtime = member;
    wrongMtime[4] = 1;
    try std.testing.expectEqual(@as(?gzip_member.Difference, .header_field), gzip_member.findHeaderDifference(&wrongMtime));
}
