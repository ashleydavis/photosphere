//
// Tests for BufferSet (port of src/test/buffer-set.test.ts).
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const errors = @import("utils-zig").errors;
const BufferSet = merkle_tree_zig.buffer_set.BufferSet;
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// The SHA-256 of a string (TypeScript: `crypto.createHash("sha256").update(text).digest()`).
//
fn sha256(text: []const u8) [Sha256.digest_length]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(text, &digest, .{});
    return digest;
}

//
// Returns true when the list contains the buffer.
//
fn containsBuffer(buffers: []const []const u8, buffer: []const u8) bool {
    for (buffers) |candidate| {
        if (std.mem.eql(u8, candidate, buffer)) {
            return true;
        }
    }
    return false;
}

//
// Collects the buffers values() yields.
//
fn collectValues(allocator: std.mem.Allocator, bufferSet: *const BufferSet) ![]const []const u8 {
    var valueList: std.ArrayList([]const u8) = .empty;
    var valueIterator = bufferSet.values();
    while (valueIterator.next()) |value| {
        try valueList.append(allocator, value);
    }
    return valueList.items;
}

test "should add and check existence of buffers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferSet = BufferSet.init(arena.allocator());
    const hash1 = sha256("test1");
    const hash2 = sha256("test2");
    _ = try bufferSet.add(&hash1);
    _ = try bufferSet.add(&hash2);
    try std.testing.expect(try bufferSet.has(&hash1));
    try std.testing.expect(try bufferSet.has(&hash2));
    const values = try collectValues(arena.allocator(), &bufferSet);
    try std.testing.expect(containsBuffer(values, &hash1));
    try std.testing.expect(containsBuffer(values, &hash2));
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expectEqual(@as(usize, 2), bufferSet.size());
}

test "should delete buffers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferSet = BufferSet.init(arena.allocator());
    const hash = sha256("test");

    _ = try bufferSet.add(&hash);
    try std.testing.expect(try bufferSet.has(&hash));

    const deleted = try bufferSet.delete(&hash);
    try std.testing.expect(deleted);
    try std.testing.expect(!try bufferSet.has(&hash));
    try std.testing.expectEqual(@as(usize, 0), (try collectValues(arena.allocator(), &bufferSet)).len);
    try std.testing.expectEqual(@as(usize, 0), bufferSet.size());
}

test "should return false when deleting non-existent buffer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferSet = BufferSet.init(arena.allocator());
    const hash = sha256("test");
    const deleted = try bufferSet.delete(&hash);
    try std.testing.expect(!deleted);
}

test "should not add duplicate buffers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferSet = BufferSet.init(arena.allocator());
    const hash = sha256("test");
    _ = try bufferSet.add(&hash);
    _ = try bufferSet.add(&hash);
    try std.testing.expectEqual(@as(usize, 1), (try collectValues(arena.allocator(), &bufferSet)).len);
    try std.testing.expectEqual(@as(usize, 1), bufferSet.size());
}

test "should handle buffer content equality (not reference)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferSet = BufferSet.init(arena.allocator());
    const hash1 = sha256("test");
    const hash2 = sha256("test");
    _ = try bufferSet.add(&hash1);
    _ = try bufferSet.add(&hash2); // Different reference, same content
    try std.testing.expect(try bufferSet.has(&hash2));
    try std.testing.expectEqual(@as(usize, 1), (try collectValues(arena.allocator(), &bufferSet)).len);
}

test "should throw error for non-32-byte buffers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferSet = BufferSet.init(arena.allocator());
    try std.testing.expectError(error.Thrown, bufferSet.add("short"));
    try std.testing.expect(std.mem.startsWith(u8, errors.lastErrorMessage(), "BufferSet expects 32-byte hashes"));
}

test "should clear all buffers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferSet = BufferSet.init(arena.allocator());
    const hash1 = sha256("test1");
    const hash2 = sha256("test2");

    _ = try bufferSet.add(&hash1);
    _ = try bufferSet.add(&hash2);
    try std.testing.expectEqual(@as(usize, 2), bufferSet.size());

    bufferSet.clear();
    try std.testing.expectEqual(@as(usize, 0), bufferSet.size());
    try std.testing.expectEqual(false, try bufferSet.has(&hash1));
    try std.testing.expectEqual(false, try bufferSet.has(&hash2));
}

test "should iterate over values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferSet = BufferSet.init(arena.allocator());
    const hash1 = sha256("test1");
    const hash2 = sha256("test2");
    _ = try bufferSet.add(&hash1);
    _ = try bufferSet.add(&hash2);
    var valueIterator = bufferSet.values();
    var valueList: std.ArrayList([]const u8) = .empty;
    while (valueIterator.next()) |value| {
        try valueList.append(arena.allocator(), value);
    }
    const values = valueList.items;
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expect(containsBuffer(values, &hash1));
    try std.testing.expect(containsBuffer(values, &hash2));
}

//
// Collects the buffers forEach passes (TypeScript: `collected.push(value)`).
//
const BufferCollector = struct {
    // Allocates the list.
    allocator: std.mem.Allocator,

    // The collected buffers.
    buffers: std.ArrayList([]const u8),
};

//
// The forEach callback: collects the buffer.
//
fn collectBuffer(collector: *BufferCollector, buffer: []const u8) anyerror!void {
    try collector.buffers.append(collector.allocator, buffer);
}

test "should support forEach" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferSet = BufferSet.init(arena.allocator());
    const hash1 = sha256("test1");
    const hash2 = sha256("test2");

    _ = try bufferSet.add(&hash1);
    _ = try bufferSet.add(&hash2);

    var collector: BufferCollector = .{
        .allocator = arena.allocator(),
        .buffers = .empty,
    };
    try bufferSet.forEach(&collector, collectBuffer);

    try std.testing.expectEqual(@as(usize, 2), collector.buffers.items.len);
    try std.testing.expect(containsBuffer(collector.buffers.items, &hash1));
    try std.testing.expect(containsBuffer(collector.buffers.items, &hash2));
}

test "should support iteration with for...of" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferSet = BufferSet.init(arena.allocator());
    const hash1 = sha256("test1");
    const hash2 = sha256("test2");
    _ = try bufferSet.add(&hash1);
    _ = try bufferSet.add(&hash2);
    var count: usize = 0;
    var values = bufferSet.values();
    while (values.next()) |buffer| {
        try std.testing.expect(std.mem.eql(u8, buffer, &hash1) or std.mem.eql(u8, buffer, &hash2));
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(usize, 2), bufferSet.size());
}

test "should handle hash collisions correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var bufferSet = BufferSet.init(allocator);
    var buffers: [100][32]u8 = undefined;
    for (&buffers, 0..) |*buffer, index| {
        buffer.* = sha256(try std.fmt.allocPrint(allocator, "test{d}", .{index}));
        _ = try bufferSet.add(buffer);
    }
    const values = try collectValues(allocator, &bufferSet);
    try std.testing.expectEqual(@as(usize, 100), values.len);
    try std.testing.expectEqual(@as(usize, 100), bufferSet.size());

    // Verify all buffers are still accessible
    for (&buffers) |*buffer| {
        try std.testing.expect(containsBuffer(values, buffer));
        try std.testing.expectEqual(true, try bufferSet.has(buffer));
    }
}

test "should handle entries iteration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferSet = BufferSet.init(arena.allocator());
    const hash1 = sha256("test1");
    const hash2 = sha256("test2");

    _ = try bufferSet.add(&hash1);
    _ = try bufferSet.add(&hash2);

    var count: usize = 0;
    var entryIterator = bufferSet.entries();
    while (entryIterator.next()) |entry| {
        // Each entry should be [buffer, buffer] since it's a Set
        try std.testing.expect(std.mem.eql(u8, entry.key, entry.value));
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "should find hash 0034217e5269895c55acc694c6423f3ddb695ecbbb68635d950cee57542a4d14 after adding it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bufferSet = BufferSet.init(arena.allocator());

    // Both have the same TypeScript bucket value (0x6094cf5e) and would be in the same bucket
    var hashBuffer: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&hashBuffer, "0034217e5269895c55acc694c6423f3ddb695ecbbb68635d950cee57542a4d14");
    var collisionBuffer: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&collisionBuffer, "111111112222222233333333444444445555555566666666777777776094cf5e");

    // Add both buffers to the set (they will collide in the same bucket)
    _ = try bufferSet.add(&hashBuffer);
    _ = try bufferSet.add(&collisionBuffer);

    // Verify both were added
    const values = try collectValues(arena.allocator(), &bufferSet);
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expect(containsBuffer(values, &hashBuffer));
    try std.testing.expect(containsBuffer(values, &collisionBuffer));
    try std.testing.expectEqual(@as(usize, 2), bufferSet.size());
    try std.testing.expectEqual(true, try bufferSet.has(&hashBuffer));
    try std.testing.expectEqual(true, try bufferSet.has(&collisionBuffer));

    // Delete the collision buffer first (simulating deleting a different node that collides)
    _ = try bufferSet.delete(&collisionBuffer);

    // Verify the collision buffer is gone
    try std.testing.expectEqual(false, try bufferSet.has(&collisionBuffer));
    try std.testing.expectEqual(@as(usize, 1), bufferSet.size());

    // A buffer with the same content as hashBuffer (different reference, simulating nodeA.hash) is still found
    var hashBuffer2: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&hashBuffer2, "0034217e5269895c55acc694c6423f3ddb695ecbbb68635d950cee57542a4d14");
    try std.testing.expectEqual(true, try bufferSet.has(&hashBuffer2));
}
