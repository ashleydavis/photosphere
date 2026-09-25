const std = @import("std");
const encryption = @import("encryption-zig");
const helpers = @import("test-helpers.zig");

const pem = encryption.pem;

test "encode writes 64-character lines like node:crypto" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const der = try allocator.alloc(u8, 100);
    for (der, 0..) |*byte, index| {
        byte.* = @truncate(index);
    }
    const text = try pem.encode(allocator, "PUBLIC KEY", der);
    var lines = std.mem.splitScalar(u8, text, '\n');
    try std.testing.expectEqualStrings("-----BEGIN PUBLIC KEY-----", lines.next().?);
    try std.testing.expectEqual(@as(usize, 64), lines.next().?.len);
    try std.testing.expectEqual(@as(usize, 64), lines.next().?.len);
    try std.testing.expectEqual(@as(usize, 8), lines.next().?.len);
    try std.testing.expectEqualStrings("-----END PUBLIC KEY-----", lines.next().?);
    try std.testing.expectEqualStrings("", lines.next().?);
    try std.testing.expect(lines.next() == null);
}

test "decode then encode reproduces the TypeScript PEM files exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const fileNames = [_][]const u8{ "ts-public.pem", "ts-private.pem" };
    for (fileNames) |fileName| {
        const text = try helpers.readFixture(allocator, fileName);
        const block = try pem.decode(allocator, text);
        const encoded = try pem.encode(allocator, block.label, block.der);
        try std.testing.expectEqualStrings(text, encoded);
    }
}

test "decode accepts CRLF line endings and surrounding text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const block = try pem.decode(allocator, "junk\r\n-----BEGIN TEST-----\r\nAAEC\r\nAw==\r\n-----END TEST-----\r\n");
    try std.testing.expectEqualStrings("TEST", block.label);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3 }, block.der);
}

test "decode rejects text without a PEM block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.InvalidPem, pem.decode(allocator, "not a key"));
    try std.testing.expectError(error.InvalidPem, pem.decode(allocator, "-----BEGIN X-----\nAAAA\n"));
    try std.testing.expectError(error.InvalidPem, pem.decode(allocator, "-----BEGIN X-----\n!!!!\n-----END X-----\n"));
}
