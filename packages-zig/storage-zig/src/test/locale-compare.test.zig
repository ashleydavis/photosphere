const std = @import("std");
const storage_zig = @import("storage-zig");

const locale_compare = storage_zig.locale_compare;

test "localeCompareNumeric compares numbers by value and letters case-insensitively first" {
    try std.testing.expect(locale_compare.localeCompareNumeric("file2", "file10") < 0);
    try std.testing.expect(locale_compare.localeCompareNumeric("file10", "file2") > 0);
    try std.testing.expect(locale_compare.localeCompareNumeric("a", "B") < 0);
    try std.testing.expect(locale_compare.localeCompareNumeric("a", "A") < 0);
    try std.testing.expect(locale_compare.localeCompareNumeric("same", "same") == 0);
    try std.testing.expect(locale_compare.localeCompareNumeric("_", "0") < 0);
    try std.testing.expect(locale_compare.localeCompareNumeric("", "a") < 0);
}

//
// A pair of names and the sign of `left.localeCompare(right, undefined, { numeric: true })` in TypeScript.
//
const ExpectedComparison = struct {
    // The left name.
    left: []const u8,

    // The right name.
    right: []const u8,

    // The sign TypeScript localeCompare gives: -1, 0 or 1.
    sign: i32,
};

//
// Name pairs and the signs TypeScript localeCompare gives for them, copied from the committed golden fixture
// packages-zig/merkle-tree-zig/src/test/fixtures/compare-names.json (generated with compareNames, which is
// `left.localeCompare(right, undefined, { numeric: true })` like FileStorage.listFiles). They are the hand-picked pairs
// followed by generated pairs over the alphabet "aAbB01-_./ " and over digits.
//
const expected_comparisons = [_]ExpectedComparison{
    .{ .left = "01", .right = "1", .sign = 0 },
    .{ .left = "1", .right = "01", .sign = 0 },
    .{ .left = "a01", .right = "a1", .sign = 0 },
    .{ .left = "a1", .right = "a01", .sign = 0 },
    .{ .left = "a01b", .right = "a1a", .sign = 1 },
    .{ .left = "a1a", .right = "a01b", .sign = -1 },
    .{ .left = "a1a", .right = "a01b", .sign = -1 },
    .{ .left = "a01b", .right = "a1a", .sign = 1 },
    .{ .left = "a", .right = "A", .sign = -1 },
    .{ .left = "A", .right = "a", .sign = 1 },
    .{ .left = "ab", .right = "Ab", .sign = -1 },
    .{ .left = "Ab", .right = "ab", .sign = 1 },
    .{ .left = "aB", .right = "Ab", .sign = -1 },
    .{ .left = "Ab", .right = "aB", .sign = 1 },
    .{ .left = "a-b", .right = "ab", .sign = -1 },
    .{ .left = "ab", .right = "a-b", .sign = 1 },
    .{ .left = "a b", .right = "ab", .sign = -1 },
    .{ .left = "ab", .right = "a b", .sign = 1 },
    .{ .left = "a_b", .right = "a-b", .sign = -1 },
    .{ .left = "a-b", .right = "a_b", .sign = 1 },
    .{ .left = "x\x00", .right = "x", .sign = 0 },
    .{ .left = "x", .right = "x\x00", .sign = 0 },
    .{ .left = "a", .right = "a\x01", .sign = 0 },
    .{ .left = "a\x01", .right = "a", .sign = 0 },
    .{ .left = "a\x09", .right = "a", .sign = 1 },
    .{ .left = "a", .right = "a\x09", .sign = -1 },
    .{ .left = "001", .right = "01", .sign = 0 },
    .{ .left = "01", .right = "001", .sign = 0 },
    .{ .left = "9", .right = "10", .sign = -1 },
    .{ .left = "10", .right = "9", .sign = 1 },
    .{ .left = "99999999999999999999999", .right = "100000000000000000000000", .sign = -1 },
    .{ .left = "100000000000000000000000", .right = "99999999999999999999999", .sign = 1 },
    .{ .left = "a-", .right = "a", .sign = 1 },
    .{ .left = "a", .right = "a-", .sign = -1 },
    .{ .left = "-a", .right = "a", .sign = -1 },
    .{ .left = "a", .right = "-a", .sign = 1 },
    .{ .left = "1a", .right = "1-a", .sign = 1 },
    .{ .left = "1-a", .right = "1a", .sign = -1 },
    .{ .left = "file1", .right = "file10", .sign = -1 },
    .{ .left = "file10", .right = "file1", .sign = 1 },
    .{ .left = "file2", .right = "file10", .sign = -1 },
    .{ .left = "file10", .right = "file2", .sign = 1 },
    .{ .left = "file02", .right = "file2", .sign = 0 },
    .{ .left = "file2", .right = "file02", .sign = 0 },
    .{ .left = "File2", .right = "file2", .sign = 1 },
    .{ .left = "file2", .right = "File2", .sign = -1 },
    .{ .left = "README.md", .right = "asset/1", .sign = 1 },
    .{ .left = "asset/1", .right = "README.md", .sign = -1 },
    .{ .left = "thumb/x", .right = "display/x", .sign = 1 },
    .{ .left = "display/x", .right = "thumb/x", .sign = -1 },
    .{ .left = "", .right = "a", .sign = -1 },
    .{ .left = "a", .right = "", .sign = 1 },
    .{ .left = "", .right = "", .sign = 0 },
    .{ .left = "", .right = "", .sign = 0 },
    .{ .left = "0", .right = "00", .sign = 0 },
    .{ .left = "00", .right = "0", .sign = 0 },
    .{ .left = "0", .right = "", .sign = 1 },
    .{ .left = "", .right = "0", .sign = -1 },
    .{ .left = "a0", .right = "a", .sign = 1 },
    .{ .left = "a", .right = "a0", .sign = -1 },
    .{ .left = "a$", .right = "a0", .sign = -1 },
    .{ .left = "a0", .right = "a$", .sign = 1 },
    .{ .left = "a~", .right = "a$", .sign = -1 },
    .{ .left = "a$", .right = "a~", .sign = 1 },
    .{ .left = "x.y", .right = "x/y", .sign = -1 },
    .{ .left = "x/y", .right = "x.y", .sign = 1 },
    .{ .left = "x/y", .right = "x-y", .sign = 1 },
    .{ .left = "x-y", .right = "x/y", .sign = -1 },
    .{ .left = "A1B", .right = "1b01A /1", .sign = 1 },
    .{ .left = "A111B.", .right = "1/", .sign = 1 },
    .{ .left = " 10..", .right = " /10..", .sign = 1 },
    .{ .left = "", .right = "bbB.. B", .sign = -1 },
    .{ .left = "--.bb", .right = "_/-.bB", .sign = 1 },
    .{ .left = "", .right = "/aB", .sign = -1 },
    .{ .left = "a B. ", .right = "/AB__1/B", .sign = 1 },
    .{ .left = "b.10.1a", .right = "", .sign = 1 },
    .{ .left = "1-0_", .right = "-0_", .sign = 1 },
    .{ .left = "_ 0/ba- ", .right = "A", .sign = -1 },
    .{ .left = "aA", .right = "/00///", .sign = 1 },
    .{ .left = ".b-1 ", .right = ".b-0 ", .sign = 1 },
    .{ .left = "a0bA_/ A", .right = "AA.0_", .sign = -1 },
    .{ .left = "a/a_ ab", .right = "._Bb.", .sign = 1 },
    .{ .left = "1aa_BBb", .right = "aaa_BBb", .sign = -1 },
    .{ .left = "AB_b/", .right = "", .sign = 1 },
    .{ .left = "a", .right = "0/A1", .sign = 1 },
    .{ .left = "1.", .right = ".1.", .sign = 1 },
    .{ .left = "/1./0aBA", .right = "", .sign = 1 },
    .{ .left = "ba", .right = "-", .sign = 1 },
    .{ .left = "a1..Aa", .right = "aB1..Aa", .sign = -1 },
    .{ .left = "a BA1B0A", .right = " ", .sign = 1 },
    .{ .left = "/.  /", .right = "a__1__", .sign = -1 },
    .{ .left = "a.0Ba", .right = "a.0B", .sign = 1 },
    .{ .left = ".-b/.b", .right = "00b/a1", .sign = -1 },
    .{ .left = "--", .right = "/Aa", .sign = -1 },
    .{ .left = "1 b-a-0 ", .right = "1/ b-a-0 ", .sign = -1 },
    .{ .left = "/1b.bA ", .right = "1", .sign = -1 },
    .{ .left = "", .right = "-1", .sign = -1 },
    .{ .left = "1b", .right = "b", .sign = -1 },
    .{ .left = "a0A", .right = "/10.0a__", .sign = 1 },
    .{ .left = ".ABbBa-", .right = "_", .sign = 1 },
    .{ .left = "a_-_", .right = "a_--_", .sign = -1 },
    .{ .left = "_babb", .right = "_/ _", .sign = 1 },
    .{ .left = "-10/ .- ", .right = " 1-B 0", .sign = 1 },
    .{ .left = "a /", .right = "a -/", .sign = 1 },
    .{ .left = "Aa", .right = "B", .sign = -1 },
    .{ .left = " ./.1", .right = "ba", .sign = -1 },
    .{ .left = "", .right = "0", .sign = -1 },
    .{ .left = "", .right = " B/-A_", .sign = -1 },
    .{ .left = "A_A_1a1", .right = "0a", .sign = 1 },
    .{ .left = "", .right = "bA 0A/B/", .sign = -1 },
    .{ .left = "a00 -", .right = "/A0-A/.-", .sign = 1 },
    .{ .left = "/AAbBb", .right = "_", .sign = 1 },
    .{ .left = "1B/", .right = "1BA/", .sign = -1 },
    .{ .left = "_./B B", .right = "0b0//A0", .sign = -1 },
    .{ .left = "_aa .b", .right = " 00 ", .sign = 1 },
    .{ .left = "", .right = " _1A", .sign = -1 },
    .{ .left = "aB_", .right = "1", .sign = 1 },
    .{ .left = "B", .right = ". a0/ a ", .sign = 1 },
    .{ .left = "A/_01A", .right = "0/_01A", .sign = 1 },
    .{ .left = "/", .right = "-/1", .sign = 1 },
    .{ .left = ".1AB", .right = "./A_Aa1", .sign = 1 },
    .{ .left = " _-", .right = " __-", .sign = 1 },
    .{ .left = "b /a", .right = "/a/", .sign = 1 },
    .{ .left = "b", .right = "00 a", .sign = 1 },
    .{ .left = "/_1b-.", .right = "/_1 b-.", .sign = 1 },
    .{ .left = ".", .right = "-A . ", .sign = 1 },
    .{ .left = "", .right = " .", .sign = -1 },
    .{ .left = "a1Bab", .right = "B1Bab", .sign = -1 },
    .{ .left = "92615689", .right = "15", .sign = 1 },
    .{ .left = "1261", .right = "12671", .sign = -1 },
    .{ .left = "38680964", .right = "09220372", .sign = 1 },
    .{ .left = "", .right = "64", .sign = -1 },
    .{ .left = "24", .right = "924", .sign = -1 },
    .{ .left = "0890", .right = "", .sign = 1 },
    .{ .left = "15830183", .right = "423588", .sign = 1 },
    .{ .left = "479065", .right = "4790615", .sign = -1 },
    .{ .left = "01346587", .right = "980", .sign = 1 },
    .{ .left = "4037", .right = "", .sign = 1 },
    .{ .left = "620478", .right = "620178", .sign = 1 },
    .{ .left = "4820", .right = "91", .sign = 1 },
    .{ .left = "66831", .right = "674", .sign = 1 },
    .{ .left = "680458", .right = "6806458", .sign = -1 },
    .{ .left = "02", .right = "47", .sign = -1 },
    .{ .left = "472", .right = "", .sign = 1 },
    .{ .left = "786065", .right = "766065", .sign = 1 },
    .{ .left = "20", .right = "4", .sign = 1 },
    .{ .left = "7486562", .right = "6223140", .sign = 1 },
    .{ .left = "94320", .right = "94324", .sign = -1 },
};

test "localeCompareNumeric gives the sign TypeScript localeCompare gives for storage names" {
    var mismatches: usize = 0;
    for (expected_comparisons) |comparison| {
        const actualSign = std.math.sign(locale_compare.localeCompareNumeric(comparison.left, comparison.right));
        const actualLessThan = locale_compare.lessThan({}, comparison.left, comparison.right);
        if (actualSign != comparison.sign or actualLessThan != (comparison.sign < 0)) {
            std.debug.print("localeCompareNumeric(\"{f}\", \"{f}\") = {d}, localeCompare = {d}\n", .{ std.zig.fmtString(comparison.left), std.zig.fmtString(comparison.right), actualSign, comparison.sign });
            mismatches += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}
