const std = @import("std");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const hash_cache = node_api.hash_cache;
const HashCache = hash_cache.HashCache;
const loadSharedHashCache = hash_cache.loadSharedHashCache;
const forgetSharedHashCaches = hash_cache.forgetSharedHashCaches;

//
// Covers the read-only hash cache that every file hashed in one engine shares, and the one thing it
// has to get right: it must not go on answering from a copy of a cache that has since been written.
//

//
// Writes one entry into the cache on disk, as a separate writer would.
//
fn writeAnEntry(cacheDir: []const u8, key: []const u8, length: u64) !void {
    const io = std.testing.io;
    var writable = try HashCache.init(cacheDir, false);
    defer writable.deinit();
    _ = try writable.load(io);
    var randomHash: [32]u8 = undefined;
    io.random(&randomHash);
    try writable.addHash(key, .{
        .hash = &randomHash,
        .length = length,
        .lastModified = 1700000000000,
    });
    try writable.save(io);
}

//
// The state each test starts from (TypeScript: the beforeEach of the describe block).
//
const SharedCacheTest = struct {
    // Holds the test's allocations.
    arena: std.heap.ArenaAllocator,

    // The cache directory of the test.
    cacheDir: []const u8,

    //
    // Creates the directory and forgets the caches earlier tests loaded.
    //
    fn init(self: *SharedCacheTest) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.cacheDir = try temp_dirs.makeTempDir(self.arena.allocator(), std.testing.io, "shared-hash-cache-test");
        forgetSharedHashCaches();
    }

    //
    // Removes the directory.
    //
    fn deinit(self: *SharedCacheTest) void {
        forgetSharedHashCaches();
        temp_dirs.removeTempDir(std.testing.io, self.cacheDir);
        self.arena.deinit();
    }
};

test "two readers of an unchanged cache get the same one" {
    var context: SharedCacheTest = undefined;
    try context.init();
    defer context.deinit();
    const io = std.testing.io;
    try writeAnEntry(context.cacheDir, "photo-1.jpg", 100);

    const first = try loadSharedHashCache(io, context.cacheDir);
    const second = try loadSharedHashCache(io, context.cacheDir);

    try std.testing.expect(second == first);
}

test "a cache that has been written since is read again" {
    var context: SharedCacheTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    try writeAnEntry(context.cacheDir, "photo-1.jpg", 100);
    const first = try loadSharedHashCache(io, context.cacheDir);
    const firstEntryCount = first.getEntryCount();

    try writeAnEntry(context.cacheDir, "photo-2.jpg", 200);
    const second = try loadSharedHashCache(io, context.cacheDir);

    // (Zig: the replaced cache is freed, and a new one can be allocated at the same address, so the cache is told
    // apart by what it holds rather than by its identity.)
    try std.testing.expectEqual(@as(u32, 1), firstEntryCount);
    try std.testing.expectEqual(@as(u32, 2), second.getEntryCount());
    try std.testing.expect(try second.getHash(allocator, "photo-2.jpg") != null);
}

test "a cache that is not there yet is read once it appears" {
    var context: SharedCacheTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    const before = try loadSharedHashCache(io, context.cacheDir);
    try std.testing.expect(try before.getHash(allocator, "photo-1.jpg") == null);

    try writeAnEntry(context.cacheDir, "photo-1.jpg", 100);

    const after = try loadSharedHashCache(io, context.cacheDir);
    try std.testing.expect(try after.getHash(allocator, "photo-1.jpg") != null);
}

test "caches in different directories are kept apart" {
    var context: SharedCacheTest = undefined;
    try context.init();
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    const otherDir = try temp_dirs.makeTempDir(allocator, io, "shared-hash-cache-other-test");
    defer temp_dirs.removeTempDir(io, otherDir);
    try writeAnEntry(context.cacheDir, "photo-1.jpg", 100);

    const here = try loadSharedHashCache(io, context.cacheDir);
    const there = try loadSharedHashCache(io, otherDir);

    try std.testing.expect(there != here);
    try std.testing.expect(try there.getHash(allocator, "photo-1.jpg") == null);
}
