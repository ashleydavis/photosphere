const std = @import("std");
const storage_zig = @import("storage-zig");
const helpers = @import("test-helpers.zig");

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

test "localeCompareNumeric sorts storage names exactly like TypeScript localeCompare with numeric ordering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    //
    // Names like the ones storage holds: uuids, hex hashes, shard numbers, index directories and file names.
    //
    var names: std.ArrayList([]const u8) = .empty;
    const fixed = [_][]const u8{
        "README.md",    ".db",        "db.dat",       "collection.dat", "tree.dat",   "metadata",     "Metadata",
        "asset",        "display",    "thumb",        "10",             "9",          "010",          "1",
        "a-b",          "a_b",        "a.b",          "ab",             "aB",         "Ab",           "a1b",
        "a10b",         "a2b",        "x-1",          "x-01",           "photo.JPG",  "photo.jpg",    "photo (1).jpg",
        "IMG_0001.jpg", "img_0002.JPG", "file~1",     "file+1",         "file=1",     "file@1",       "file#1",
        "hash=asc",     "hash=desc",  "date_desc",    "dateAsc",        "Z",          "z",            "0x1f",
    };
    try names.appendSlice(allocator, &fixed);
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();
    const alphabet = "0123456789abcdefABCDEF-_.";
    var index: usize = 0;
    while (index < 200) : (index += 1) {
        const length = random.intRangeAtMost(usize, 1, 12);
        const name = try allocator.alloc(u8, length);
        for (name) |*character| {
            character.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        }
        try names.append(allocator, name);
    }

    const tempDir = try helpers.makeTempDir(allocator, io, "locale-compare");
    defer helpers.removeTempDir(io, tempDir);
    const namesFile = try std.fmt.allocPrint(allocator, "{s}/names.txt", .{tempDir});
    try helpers.writeFile(io, namesFile, try std.mem.join(allocator, "\n", names.items));

    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "bun", "run", "src/test/fixtures/locale-sort.ts", namesFile },
    });
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("locale-sort.ts failed:\n{s}\n", .{result.stderr});
        return error.TestUnexpectedResult;
    }

    std.mem.sort([]const u8, names.items, {}, locale_compare.lessThan);
    const zigSorted = try std.mem.join(allocator, "\n", names.items);
    try std.testing.expectEqualStrings(std.mem.trimEnd(u8, result.stdout, "\n"), zigSorted);
}
