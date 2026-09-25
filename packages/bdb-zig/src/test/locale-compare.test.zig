const std = @import("std");
const bdb = @import("bdb-zig");
const helpers = @import("test-helpers.zig");
const locale_compare = bdb.locale_compare;

test "localeCompare matches String.prototype.localeCompare for every golden pair" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const fixture = try helpers.readJsonFixture(allocator, io, "js-values.json");
    const strings = fixture.object.get("localeStrings").?.array.items;
    const matrix = fixture.object.get("localeMatrix").?.array.items;
    var mismatches: usize = 0;
    for (strings, 0..) |left, leftIndex| {
        const row = matrix[leftIndex].string;
        for (strings, 0..) |right, rightIndex| {
            const result = locale_compare.localeCompare(left.string, right.string);
            const actual: u8 = if (result < 0) '-' else if (result > 0) '+' else '0';
            if (actual != row[rightIndex]) {
                if (mismatches < 10) {
                    std.debug.print("\"{s}\".localeCompare(\"{s}\"): expected {c}, got {c}\n", .{ left.string, right.string, row[rightIndex], actual });
                }
                mismatches += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

test "localeCompare puts lowercase before uppercase and digits before letters" {
    try std.testing.expect(locale_compare.localeCompare("a", "A") < 0);
    try std.testing.expect(locale_compare.localeCompare("9", "a") < 0);
    try std.testing.expect(locale_compare.localeCompare("a-b", "ab") < 0);
    try std.testing.expectEqual(@as(i32, 0), locale_compare.localeCompare("abc", "abc"));
}
