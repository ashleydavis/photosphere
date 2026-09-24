const std = @import("std");
const node_api = @import("node-api-zig");
const hash = node_api.hash;
const Sha256 = std.crypto.hash.sha2.Sha256;

test "computeHash returns the sha256 of the stream" {
    var reader = std.Io.Reader.fixed("hello world");
    const digest = try hash.computeHash(&reader);
    var expected: [32]u8 = undefined;
    Sha256.hash("hello world", &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "computeHash of an empty stream is the sha256 of nothing" {
    var reader = std.Io.Reader.fixed("");
    const digest = try hash.computeHash(&reader);
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &std.fmt.bytesToHex(digest, .lower));
}

test "computeHash hashes streams larger than its buffer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const data = try arena.allocator().alloc(u8, 300 * 1024 + 17);
    for (data, 0..) |*byte, index| {
        byte.* = @truncate(index *% 31 +% 7);
    }
    var reader = std.Io.Reader.fixed(data);
    const digest = try hash.computeHash(&reader);
    var expected: [32]u8 = undefined;
    Sha256.hash(data, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "computeAssetHash returns the hash with the length and date of the file stat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reader = std.Io.Reader.fixed("abc");
    const hashed = try hash.computeAssetHash(arena.allocator(), &reader, .{ .length = 3, .lastModified = 1234 });
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &std.fmt.bytesToHex(hashed.hash[0..32].*, .lower));
    try std.testing.expectEqual(@as(u64, 3), hashed.length);
    try std.testing.expectEqual(@as(i64, 1234), hashed.lastModified);
}
