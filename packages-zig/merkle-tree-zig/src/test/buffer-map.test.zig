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
    try std.testing.expectEqual(@as(usize, 2), bufferMap.size());
}

test "should update existing values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferMap = BufferMap([]const u8).init(arena.allocator());
    const key = sha256("test");
    _ = try bufferMap.set(&key, "value1");
    _ = try bufferMap.set(&key, "value2");
    try std.testing.expectEqualStrings("value2", (try bufferMap.get(&key)).?);
    try std.testing.expectEqual(@as(usize, 1), bufferMap.size());
}

test "should return undefined for non-existent keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferMap = BufferMap([]const u8).init(arena.allocator());
    const key = sha256("test");
    try std.testing.expect((try bufferMap.get(&key)) == null);
}

test "should check key existence with has" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferMap = BufferMap([]const u8).init(arena.allocator());
    const key = sha256("test");

    try std.testing.expectEqual(false, try bufferMap.has(&key));

    _ = try bufferMap.set(&key, "value");
    try std.testing.expectEqual(true, try bufferMap.has(&key));
}

test "should delete key-value pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferMap = BufferMap([]const u8).init(arena.allocator());
    const key = sha256("test");

    _ = try bufferMap.set(&key, "value");
    try std.testing.expectEqual(true, try bufferMap.has(&key));

    const deleted = try bufferMap.delete(&key);
    try std.testing.expectEqual(true, deleted);
    try std.testing.expectEqual(false, try bufferMap.has(&key));
    try std.testing.expect((try bufferMap.get(&key)) == null);
    try std.testing.expectEqual(@as(usize, 0), bufferMap.size());
}

test "should return false when deleting non-existent key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferMap = BufferMap([]const u8).init(arena.allocator());
    const key = sha256("test");
    const deleted = try bufferMap.delete(&key);
    try std.testing.expectEqual(false, deleted);
}

test "should handle buffer key content equality (not reference)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferMap = BufferMap([]const u8).init(arena.allocator());
    const key1 = sha256("test");
    const key2 = sha256("test");
    _ = try bufferMap.set(&key1, "value");
    try std.testing.expectEqualStrings("value", (try bufferMap.get(&key2)).?); // Different reference, same content
    try std.testing.expectEqual(true, try bufferMap.has(&key2));
}

test "should throw error for non-32-byte buffer keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferMap = BufferMap([]const u8).init(arena.allocator());
    try std.testing.expectError(error.Thrown, bufferMap.set("short", "value"));
    try std.testing.expect(std.mem.startsWith(u8, errors.lastErrorMessage(), "BufferMap expects 32-byte hashes"));
}

test "should clear all entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferMap = BufferMap([]const u8).init(arena.allocator());
    const key1 = sha256("test1");
    const key2 = sha256("test2");

    _ = try bufferMap.set(&key1, "value1");
    _ = try bufferMap.set(&key2, "value2");
    try std.testing.expectEqual(@as(usize, 2), bufferMap.size());

    bufferMap.clear();
    try std.testing.expectEqual(@as(usize, 0), bufferMap.size());
    try std.testing.expectEqual(false, try bufferMap.has(&key1));
    try std.testing.expectEqual(false, try bufferMap.has(&key2));
}

test "should iterate over values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferMap = BufferMap([]const u8).init(arena.allocator());
    const key1 = sha256("test1");
    const key2 = sha256("test2");

    _ = try bufferMap.set(&key1, "value1");
    _ = try bufferMap.set(&key2, "value2");

    var values: std.ArrayList([]const u8) = .empty;
    var valueIterator = bufferMap.values();
    while (valueIterator.next()) |value| {
        try values.append(arena.allocator(), value);
    }
    try std.testing.expectEqual(@as(usize, 2), values.items.len);
    try std.testing.expect(containsString(values.items, "value1"));
    try std.testing.expect(containsString(values.items, "value2"));
}

test "should iterate over keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferMap = BufferMap([]const u8).init(arena.allocator());
    const key1 = sha256("test1");
    const key2 = sha256("test2");

    _ = try bufferMap.set(&key1, "value1");
    _ = try bufferMap.set(&key2, "value2");

    var keys: std.ArrayList([]const u8) = .empty;
    var keyIterator = bufferMap.keys();
    while (keyIterator.next()) |key| {
        try keys.append(arena.allocator(), key);
    }
    try std.testing.expectEqual(@as(usize, 2), keys.items.len);
    try std.testing.expect(containsString(keys.items, &key1));
    try std.testing.expect(containsString(keys.items, &key2));
}

//
// Collects the pairs a map yields (TypeScript: `collected.push([key, value])`).
//
const PairCollector = struct {
    // Allocates the list.
    allocator: std.mem.Allocator,

    // The collected pairs.
    pairs: std.ArrayList(BufferMap([]const u8).Entry),
};

//
// The forEach callback: collects the pair.
//
fn collectPair(collector: *PairCollector, entry: BufferMap([]const u8).Entry) anyerror!void {
    try collector.pairs.append(collector.allocator, entry);
}

//
// Returns true when the pairs contain the key with the value.
//
fn containsPair(pairs: []const BufferMap([]const u8).Entry, key: []const u8, value: []const u8) bool {
    for (pairs) |pair| {
        if (std.mem.eql(u8, pair.key, key) and std.mem.eql(u8, pair.value, value)) {
            return true;
        }
    }
    return false;
}

//
// Returns true when the list contains the string.
//
fn containsString(strings: []const []const u8, text: []const u8) bool {
    for (strings) |candidate| {
        if (std.mem.eql(u8, candidate, text)) {
            return true;
        }
    }
    return false;
}

test "should support forEach" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferMap = BufferMap([]const u8).init(arena.allocator());
    const key1 = sha256("test1");
    const key2 = sha256("test2");

    _ = try bufferMap.set(&key1, "value1");
    _ = try bufferMap.set(&key2, "value2");

    var collector: PairCollector = .{
        .allocator = arena.allocator(),
        .pairs = .empty,
    };
    try bufferMap.forEach(&collector, collectPair);

    try std.testing.expectEqual(@as(usize, 2), collector.pairs.items.len);
    try std.testing.expect(containsPair(collector.pairs.items, &key1, "value1"));
    try std.testing.expect(containsPair(collector.pairs.items, &key2, "value2"));
}

test "should support iteration with for...of" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferMap = BufferMap([]const u8).init(arena.allocator());
    const key1 = sha256("test1");
    const key2 = sha256("test2");

    _ = try bufferMap.set(&key1, "value1");
    _ = try bufferMap.set(&key2, "value2");

    // The Zig form of `for (const entry of bufferMap)` is iterating entries().
    var collected: std.ArrayList(BufferMap([]const u8).Entry) = .empty;
    var entryIterator = bufferMap.entries();
    while (entryIterator.next()) |entry| {
        try collected.append(arena.allocator(), entry);
    }

    try std.testing.expectEqual(@as(usize, 2), collected.items.len);
    try std.testing.expect(containsPair(collected.items, &key1, "value1"));
    try std.testing.expect(containsPair(collected.items, &key2, "value2"));
}

test "should handle entries iteration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferMap = BufferMap([]const u8).init(arena.allocator());
    const key1 = sha256("test1");
    const key2 = sha256("test2");

    _ = try bufferMap.set(&key1, "value1");
    _ = try bufferMap.set(&key2, "value2");

    var entries: std.ArrayList(BufferMap([]const u8).Entry) = .empty;
    var entryIterator = bufferMap.entries();
    while (entryIterator.next()) |entry| {
        try entries.append(arena.allocator(), entry);
    }
    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
    try std.testing.expect(containsPair(entries.items, &key1, "value1"));
    try std.testing.expect(containsPair(entries.items, &key2, "value2"));
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
    try std.testing.expectEqual(@as(usize, 100), bufferMap.size());

    // Verify all entries are still accessible
    for (&keys, values) |*key, value| {
        try std.testing.expectEqualStrings(value, (try bufferMap.get(key)).?);
        try std.testing.expectEqual(true, try bufferMap.has(key));
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
    try std.testing.expectEqual(@as(usize, 2), bufferMap.size());
    try std.testing.expectEqualStrings("value1", (try bufferMap.get(&key1)).?);
    try std.testing.expectEqualStrings("value2", (try bufferMap.get(&key2)).?);
}
