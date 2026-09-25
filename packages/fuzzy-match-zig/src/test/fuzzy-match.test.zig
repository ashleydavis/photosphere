const std = @import("std");
const fuzzy_match_package = @import("fuzzy-match-zig");
const fuzzy_match = fuzzy_match_package.fuzzy_match;
const levenshteinDistance = fuzzy_match.levenshteinDistance;
const fuzzyMatch = fuzzy_match.fuzzyMatch;

//
// Returns true when `matches` contains `expected`.
//
fn contains(matches: []const []const u8, expected: []const u8) bool {
    for (matches) |match| {
        if (std.mem.eql(u8, match, expected)) {
            return true;
        }
    }
    return false;
}

test "returns 0 for identical strings" {
    try std.testing.expectEqual(@as(usize, 0), try levenshteinDistance(std.testing.allocator, "abc", "abc"));
}

test "returns 0 for two empty strings" {
    try std.testing.expectEqual(@as(usize, 0), try levenshteinDistance(std.testing.allocator, "", ""));
}

test "returns length of non-empty string when other is empty" {
    try std.testing.expectEqual(@as(usize, 3), try levenshteinDistance(std.testing.allocator, "abc", ""));
    try std.testing.expectEqual(@as(usize, 3), try levenshteinDistance(std.testing.allocator, "", "abc"));
}

test "counts a single substitution" {
    try std.testing.expectEqual(@as(usize, 1), try levenshteinDistance(std.testing.allocator, "cat", "bat"));
}

test "counts a single insertion" {
    try std.testing.expectEqual(@as(usize, 1), try levenshteinDistance(std.testing.allocator, "cat", "cats"));
}

test "counts a single deletion" {
    try std.testing.expectEqual(@as(usize, 1), try levenshteinDistance(std.testing.allocator, "cats", "cat"));
}

test "counts multiple edits" {
    try std.testing.expectEqual(@as(usize, 3), try levenshteinDistance(std.testing.allocator, "kitten", "sitting"));
}

test "is symmetric" {
    try std.testing.expectEqual(try levenshteinDistance(std.testing.allocator, "abc", "xyz"), try levenshteinDistance(std.testing.allocator, "xyz", "abc"));
}

test "counts UTF-16 code units like JavaScript" {
    // 'é' is one UTF-16 code unit, the emoji is two.
    try std.testing.expectEqual(@as(usize, 1), try levenshteinDistance(std.testing.allocator, "caf\u{e9}", "cafe"));
    try std.testing.expectEqual(@as(usize, 2), try levenshteinDistance(std.testing.allocator, "a\u{1F600}", "a"));
}

test "returns empty array when candidates is empty" {
    const matches = try fuzzyMatch(std.testing.allocator, "mydb", &.{});
    defer std.testing.allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "skips exact match (distance 0)" {
    const matches = try fuzzyMatch(std.testing.allocator, "mydb", &.{"mydb"});
    defer std.testing.allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "returns candidate within threshold" {
    // 'mydb' vs 'mydb2': distance 1, threshold max(3, floor(4/4))=3 -> included
    const matches = try fuzzyMatch(std.testing.allocator, "mydb", &.{"mydb2"});
    defer std.testing.allocator.free(matches);
    try std.testing.expect(contains(matches, "mydb2"));
}

test "skips candidate beyond threshold" {
    // 'abc' vs 'zyxwvut': distance 7, threshold max(3,0)=3 -> excluded
    const matches = try fuzzyMatch(std.testing.allocator, "abc", &.{"zyxwvut"});
    defer std.testing.allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "is case-insensitive" {
    const matches = try fuzzyMatch(std.testing.allocator, "mydb", &.{"MyDB2"});
    defer std.testing.allocator.free(matches);
    try std.testing.expect(contains(matches, "MyDB2"));
}

test "returns multiple matches when several candidates qualify" {
    const matches = try fuzzyMatch(std.testing.allocator, "mydb", &.{ "mydb1", "mydb2", "totallydifferent" });
    defer std.testing.allocator.free(matches);
    try std.testing.expect(contains(matches, "mydb1"));
    try std.testing.expect(contains(matches, "mydb2"));
    try std.testing.expect(!contains(matches, "totallydifferent"));
}

test "threshold grows with the query length" {
    // 20 character query: threshold max(3, floor(20/4)) = 5.
    const matches = try fuzzyMatch(std.testing.allocator, "abcdefghijklmnopqrst", &.{ "abcdefghijklmnoXXXXX", "abcdefghijklmnXXXXXX" });
    defer std.testing.allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("abcdefghijklmnoXXXXX", matches[0]);
}
