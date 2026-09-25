//
// Tests for BufferMap (port of src/test/buffer-map.test.ts).
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const errors = @import("utils-zig").errors;
const BufferMap = merkle_tree_zig.buffer_map.BufferMap;
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// The SHA-256 of a string (TypeScript: `crypto.createHash("sha256").update(text).digest()`).
//
fn sha256(text: []const u8) [Sha256.digest_length]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(text, &digest, .{});
    return digest;
}

test "should set and get values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferMap = BufferMap([]const u8).init(arena.allocator());
    const key1 = sha256("test1");
    const key2 = sha256("test2");
    _ = try bufferMap.set(&key1, "value1");
    _ = try bufferMap.set(&key2, "value2");
    try std.testing.expectEqualStrings("value1", (try bufferMap.get(&key1)).?);
    try std.testing.expectEqualStrings("value2", (try bufferMap.get(&key2)).?);
}

test "should update existing values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferMap = BufferMap([]const u8).init(arena.allocator());
    const key = sha256("test");
    _ = try bufferMap.set(&key, "value1");
    _ = try bufferMap.set(&key, "value2");
    try std.testing.expectEqualStrings("value2", (try bufferMap.get(&key)).?);
}

test "should return undefined for non-existent keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferMap = BufferMap([]const u8).init(arena.allocator());
    const key = sha256("test");
    try std.testing.expect((try bufferMap.get(&key)) == null);
}

test "should handle buffer key content equality (not reference)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferMap = BufferMap([]const u8).init(arena.allocator());
    const key1 = sha256("test");
    const key2 = sha256("test");
    _ = try bufferMap.set(&key1, "value");
    try std.testing.expectEqualStrings("value", (try bufferMap.get(&key2)).?); // Different reference, same content
}

test "should throw error for non-32-byte buffer keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferMap = BufferMap([]const u8).init(arena.allocator());
    try std.testing.expectError(error.Thrown, bufferMap.set("short", "value"));
    try std.testing.expect(std.mem.startsWith(u8, errors.lastErrorMessage(), "BufferMap expects 32-byte hashes"));
}

test "should handle hash collisions correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var bufferMap = BufferMap([]const u8).init(allocator);
    var keys: [100][32]u8 = undefined;
    var values: [100][]const u8 = undefined;
    for (&keys, &values, 0..) |*key, *value, index| {
        key.* = sha256(try std.fmt.allocPrint(allocator, "test{d}", .{index}));
        value.* = try std.fmt.allocPrint(allocator, "value{d}", .{index});
        _ = try bufferMap.set(key, value.*);
    }
    // Verify all entries are still accessible
    for (&keys, values) |*key, value| {
        try std.testing.expectEqualStrings(value, (try bufferMap.get(key)).?);
    }
}

test "should work with different value types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var numberMap = BufferMap(u64).init(arena.allocator());
    const key = sha256("test");
    _ = try numberMap.set(&key, 42);
    try std.testing.expectEqual(@as(?u64, 42), try numberMap.get(&key));
}

//
// An object value for the map tests.
//
const TestObject = struct {
    // A name.
    name: []const u8,

    // A count.
    count: u32,
};

test "should work with object values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var objectMap = BufferMap(*const TestObject).init(arena.allocator());
    const key = sha256("test");
    const object: TestObject = .{ .name = "test", .count = 5 };
    _ = try objectMap.set(&key, &object);
    try std.testing.expectEqual(&object, (try objectMap.get(&key)).?);
    try std.testing.expectEqualStrings("test", (try objectMap.get(&key)).?.name);
    try std.testing.expectEqual(@as(u32, 5), (try objectMap.get(&key)).?.count);
}

test "should return this from set method for chaining" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferMap = BufferMap([]const u8).init(arena.allocator());
    const key1 = sha256("test1");
    const key2 = sha256("test2");
    const result = try (try bufferMap.set(&key1, "value1")).set(&key2, "value2");
    try std.testing.expectEqual(&bufferMap, result);
    try std.testing.expectEqualStrings("value1", (try bufferMap.get(&key1)).?);
    try std.testing.expectEqualStrings("value2", (try bufferMap.get(&key2)).?);
}
