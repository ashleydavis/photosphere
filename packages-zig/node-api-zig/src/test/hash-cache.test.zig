const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const hash_cache = node_api.hash_cache;
const HashCache = hash_cache.HashCache;
const IHashCacheEntry = hash_cache.IHashCacheEntry;
const getHashCacheDir = hash_cache.getHashCacheDir;
const getDatabaseCacheDir = node_api.database_cache_dir.getDatabaseCacheDir;
const getCacheDir = node_utils.fs.getCacheDir;
const getProcessTmpDir = node_utils.fs.getProcessTmpDir;
const path = node_utils.path;
const errors = utils.errors;
const Sha256 = std.crypto.hash.sha2.Sha256;

// Not ported: MockStorage (TypeScript keeps it only for reference; no test uses it).

//
// Helper function to create a file hash.
//
fn createHash(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(content, &digest, .{});
    return allocator.dupe(u8, &digest);
}

//
// `new Date(year, monthIndex, day).getTime()` in UTC, the time zone the tests run in. (No TypeScript counterpart.)
//
fn localDate(year: i64, monthIndex: i64, day: i64) i64 {
    // Days from 1970-01-01 to the date, by the civil-from-days algorithm run backwards.
    const adjustedYear = if (monthIndex < 2) year - 1 else year;
    const era = @divFloor(adjustedYear, 400);
    const yearOfEra = adjustedYear - era * 400;
    const monthFromMarch = if (monthIndex < 2) monthIndex + 10 else monthIndex - 2;
    const dayOfYear = @divFloor(153 * monthFromMarch + 2, 5) + day - 1;
    const dayOfEra = yearOfEra * 365 + @divFloor(yearOfEra, 4) - @divFloor(yearOfEra, 100) + dayOfYear;
    const days = era * 146097 + dayOfEra - 719468;
    return days * 86_400_000;
}

//
// The state each HashCache test starts from (TypeScript: the beforeEach of the describe block).
//
const CacheTest = struct {
    // Holds the test's allocations.
    arena: std.heap.ArenaAllocator,

    // The cache directory of the test.
    cacheDir: []const u8,

    // The cache under test.
    hashCache: HashCache,

    //
    // Creates the cache in a directory of its own.
    //
    fn init(self: *CacheTest, name: []const u8) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.cacheDir = try helpers.makeTempDir(self.arena.allocator(), std.testing.io, name);
        self.hashCache = try HashCache.init(self.cacheDir, false);
    }

    //
    // Frees the cache and removes its directory.
    //
    fn deinit(self: *CacheTest) void {
        self.hashCache.deinit();
        helpers.removeTempDir(std.testing.io, self.cacheDir);
        self.arena.deinit();
    }
};

test "should initialize with empty cache" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-test");
    defer context.deinit();
    const loaded = try context.hashCache.load(std.testing.io);
    try std.testing.expectEqual(false, loaded);
    try std.testing.expectEqual(@as(u32, 0), context.hashCache.getEntryCount());
}

test "should add and retrieve hash" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.hashCache.load(std.testing.io);

    const filePath = "test/file1.txt";
    const hash = try createHash(allocator, "file content");
    const fileSize = 100;
    const lastModified = std.Io.Clock.real.now(std.testing.io).toMilliseconds();

    try context.hashCache.addHash(filePath, .{
        .hash = hash,
        .length = fileSize,
        .lastModified = lastModified,
    });

    const retrieved = (try context.hashCache.getHash(allocator, filePath)).?;
    try std.testing.expectEqualSlices(u8, hash, retrieved.hash);
    try std.testing.expectEqual(@as(u64, fileSize), retrieved.length);
    try std.testing.expectEqual(lastModified, retrieved.lastModified);
    try std.testing.expectEqual(@as(u32, 1), context.hashCache.getEntryCount());
}

test "should update existing hash" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.hashCache.load(std.testing.io);

    const filePath = "test/file2.txt";
    try context.hashCache.addHash(filePath, .{
        .hash = try createHash(allocator, "original content"),
        .length = 100,
        .lastModified = localDate(2023, 1, 1),
    });

    // Update with new hash
    const hash2 = try createHash(allocator, "updated content");
    try context.hashCache.addHash(filePath, .{
        .hash = hash2,
        .length = 200,
        .lastModified = localDate(2023, 2, 1),
    });

    const retrieved = (try context.hashCache.getHash(allocator, filePath)).?;
    try std.testing.expectEqualSlices(u8, hash2, retrieved.hash);
    try std.testing.expectEqual(@as(u64, 200), retrieved.length);
    try std.testing.expectEqual(localDate(2023, 2, 1), retrieved.lastModified);
    try std.testing.expectEqual(@as(u32, 1), context.hashCache.getEntryCount()); // Count should still be 1
}

test "should save and load cache" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    _ = try context.hashCache.load(io);

    // Add some hashes
    const hash1 = try createHash(allocator, "content 1");
    const hash2 = try createHash(allocator, "content 2");
    try context.hashCache.addHash("test/file1.txt", .{
        .hash = hash1,
        .length = 100,
        .lastModified = localDate(2023, 1, 1),
    });
    try context.hashCache.addHash("test/file2.txt", .{
        .hash = hash2,
        .length = 200,
        .lastModified = localDate(2023, 2, 1),
    });

    // Save the cache
    try context.hashCache.save(io);

    // Create a new cache instance and load
    var newCache = try HashCache.init(context.cacheDir, false);
    defer newCache.deinit();
    const loaded = try newCache.load(io);

    try std.testing.expectEqual(true, loaded);
    try std.testing.expectEqual(@as(u32, 2), newCache.getEntryCount());

    // Check that hashes are retrieved correctly
    const retrieved1 = (try newCache.getHash(allocator, "test/file1.txt")).?;
    try std.testing.expectEqualSlices(u8, hash1, retrieved1.hash);
    try std.testing.expectEqual(@as(u64, 100), retrieved1.length);
    try std.testing.expectEqual(localDate(2023, 1, 1), retrieved1.lastModified);

    const retrieved2 = (try newCache.getHash(allocator, "test/file2.txt")).?;
    try std.testing.expectEqualSlices(u8, hash2, retrieved2.hash);
    try std.testing.expectEqual(@as(u64, 200), retrieved2.length);
    try std.testing.expectEqual(localDate(2023, 2, 1), retrieved2.lastModified);
}

test "should handle non-existent hashes" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-test");
    defer context.deinit();
    _ = try context.hashCache.load(std.testing.io);

    try std.testing.expect(try context.hashCache.getHash(context.arena.allocator(), "non-existent-file.txt") == null);
}

test "should remove hash" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.hashCache.load(std.testing.io);

    const filePath = "test/file3.txt";
    try context.hashCache.addHash(filePath, .{
        .hash = try createHash(allocator, "content"),
        .length = 100,
        .lastModified = 1000,
    });
    try std.testing.expectEqual(@as(u32, 1), context.hashCache.getEntryCount());

    // Remove the hash
    try std.testing.expectEqual(true, try context.hashCache.removeHash(filePath));
    try std.testing.expectEqual(@as(u32, 0), context.hashCache.getEntryCount());

    // Try to get the removed hash
    try std.testing.expect(try context.hashCache.getHash(allocator, filePath) == null);
}

test "should return false when removing non-existent hash" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-test");
    defer context.deinit();
    _ = try context.hashCache.load(std.testing.io);

    try std.testing.expectEqual(false, try context.hashCache.removeHash("non-existent-file.txt"));
}

test "should properly handle paths with different slashes" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.hashCache.load(std.testing.io);

    const hash = try createHash(allocator, "content");
    try context.hashCache.addHash("test\\file4.txt", .{
        .hash = hash,
        .length = 100,
        .lastModified = 1000,
    }); // Windows-style path

    // Should normalize paths internally
    const retrieved = (try context.hashCache.getHash(allocator, "test/file4.txt")).?; // Unix-style path
    try std.testing.expectEqualSlices(u8, hash, retrieved.hash);
}

test "should maintain sorted order when adding hashes" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    _ = try context.hashCache.load(io);

    // Add hashes in non-alphabetical order
    const files = [_][]const u8{
        "z/file.txt",
        "a/file.txt",
        "m/file.txt",
        "c/file.txt",
    };

    for (files) |file| {
        try context.hashCache.addHash(file, .{
            .hash = try createHash(allocator, try std.fmt.allocPrint(allocator, "content of {s}", .{file})),
            .length = 100,
            .lastModified = 1000,
        });
    }

    // Save and reload to verify order
    try context.hashCache.save(io);

    var newCache = try HashCache.init(context.cacheDir, false);
    defer newCache.deinit();
    _ = try newCache.load(io);

    // Verify all hashes can be retrieved
    for (files) |file| {
        const retrieved = (try newCache.getHash(allocator, file)).?;
        try std.testing.expectEqualSlices(u8, try createHash(allocator, try std.fmt.allocPrint(allocator, "content of {s}", .{file})), retrieved.hash);
    }
}

test "should handle buffer resizing for large entries" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.hashCache.load(std.testing.io);

    // Add a large number of entries to force buffer resizing
    const largeEntryCount = 1000;

    var index: u64 = 0;
    while (index < largeEntryCount) : (index += 1) {
        try context.hashCache.addHash(try std.fmt.allocPrint(allocator, "file{d:0>4}.txt", .{index}), .{
            .hash = try createHash(allocator, try std.fmt.allocPrint(allocator, "content {d}", .{index})),
            .length = index,
            .lastModified = 1000,
        });
    }

    try std.testing.expectEqual(@as(u32, largeEntryCount), context.hashCache.getEntryCount());

    // Verify a random entry
    var randomBytes: [4]u8 = undefined;
    std.testing.io.random(&randomBytes);
    const randomIndex = std.mem.readInt(u32, &randomBytes, .little) % largeEntryCount;
    const retrieved = (try context.hashCache.getHash(allocator, try std.fmt.allocPrint(allocator, "file{d:0>4}.txt", .{randomIndex}))).?;

    try std.testing.expectEqualSlices(u8, try createHash(allocator, try std.fmt.allocPrint(allocator, "content {d}", .{randomIndex})), retrieved.hash);
    try std.testing.expectEqual(@as(u64, randomIndex), retrieved.length);
}

test "should correctly calculate entry size" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    _ = try context.hashCache.load(io);

    // Add entries with different path lengths
    const shortPath = "a.txt";
    const longPath = "very/long/path/with/multiple/directories/and/a/long/filename.extension";

    try context.hashCache.addHash(shortPath, .{
        .hash = try createHash(allocator, "short"),
        .length = 100,
        .lastModified = 1000,
    });
    try context.hashCache.addHash(longPath, .{
        .hash = try createHash(allocator, "long"),
        .length = 200,
        .lastModified = 1000,
    });

    // Save and reload to verify
    try context.hashCache.save(io);

    var newCache = try HashCache.init(context.cacheDir, false);
    defer newCache.deinit();
    _ = try newCache.load(io);

    // Verify both entries
    try std.testing.expectEqualSlices(u8, try createHash(allocator, "short"), (try newCache.getHash(allocator, shortPath)).?.hash);
    try std.testing.expectEqualSlices(u8, try createHash(allocator, "long"), (try newCache.getHash(allocator, longPath)).?.hash);
}

test "should validate hash length" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-test");
    defer context.deinit();
    _ = try context.hashCache.load(std.testing.io);

    try std.testing.expectError(error.Thrown, context.hashCache.addHash("test/file.txt", .{
        .hash = "too-short", // Not 32 bytes
        .length = 100,
        .lastModified = 1000,
    }));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "Invalid hash length") != null);
}

test "addHash refuses a length that does not fit 48 bits with a RangeError" {
    // Node's `buf.writeUIntLE(value, offset, 6)` throws a RangeError for a value of 2 ** 48 or more.
    var context: CacheTest = undefined;
    try context.init("hash-cache-test");
    defer context.deinit();
    _ = try context.hashCache.load(std.testing.io);

    try std.testing.expectError(error.Thrown, context.hashCache.addHash("test/file.txt", .{
        .hash = try createHash(context.arena.allocator(), "content"),
        .length = 300000000000000,
        .lastModified = 1000,
    }));
    try std.testing.expectEqualStrings("RangeError", errors.lastErrorName());
    try std.testing.expectEqualStrings("The value of \"value\" is out of range. It must be >= 0 and < 2 ** 48. Received 300000000000000", errors.lastErrorMessage());
}

test "should handle binary search edge cases" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.hashCache.load(std.testing.io);

    // Add entries to test binary search
    var index: u64 = 0;
    while (index < 10) : (index += 2) { // Add even numbers only
        try context.hashCache.addHash(try std.fmt.allocPrint(allocator, "file{d}.txt", .{index}), .{
            .hash = try createHash(allocator, try std.fmt.allocPrint(allocator, "content {d}", .{index})),
            .length = index,
            .lastModified = 1000,
        });
    }

    // Test getting a hash at the start of the range
    try std.testing.expect(try context.hashCache.getHash(allocator, "file0.txt") != null);

    // Test getting a hash at the end of the range
    try std.testing.expect(try context.hashCache.getHash(allocator, "file8.txt") != null);

    // Test getting a hash in the middle
    try std.testing.expect(try context.hashCache.getHash(allocator, "file4.txt") != null);

    // Test with missing hashes (odd numbers)
    try std.testing.expect(try context.hashCache.getHash(allocator, "file1.txt") == null);
    try std.testing.expect(try context.hashCache.getHash(allocator, "file3.txt") == null);
    try std.testing.expect(try context.hashCache.getHash(allocator, "file5.txt") == null);

    // Test with a path that would be before the first entry
    try std.testing.expect(try context.hashCache.getHash(allocator, "aaa.txt") == null);

    // Test with a path that would be after the last entry
    try std.testing.expect(try context.hashCache.getHash(allocator, "zzz.txt") == null);
}

//
// Builds a cache entry with predictable content for the encode/decode and merge tests.
//
fn makeEntry(allocator: std.mem.Allocator, filePath: []const u8) !IHashCacheEntry {
    return .{
        .key = filePath,
        .hash = (try createHash(allocator, try std.fmt.allocPrint(allocator, "content of {s}", .{filePath})))[0..32].*,
        .length = filePath.len,
        .lastModified = localDate(2024, 0, 1),
        .assetId = null,
        .keyedBySourceId = false,
    };
}

//
// Replaces the checksum at the end of an encoded cache file with the checksum of the rest.
//
fn rechecksum(allocator: std.mem.Allocator, encoded: []u8) ![]u8 {
    const dataWithoutChecksum = encoded[0 .. encoded.len - 32];
    var digest: [32]u8 = undefined;
    Sha256.hash(dataWithoutChecksum, &digest, .{});
    return std.mem.concat(allocator, u8, &.{ dataWithoutChecksum, &digest });
}

test "round-trips a set of entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const entries = [_]IHashCacheEntry{
        try makeEntry(allocator, "a/one.txt"),
        try makeEntry(allocator, "b/two.txt"),
        try makeEntry(allocator, "c/three.txt"),
    };

    const decoded = (try HashCache.decodeEntries(allocator, try HashCache.encodeEntries(allocator, &entries))).?;

    try std.testing.expectEqual(@as(usize, 3), decoded.len);
    for (entries, 0..) |entry, entryIndex| {
        try std.testing.expectEqualStrings(entry.key, decoded[entryIndex].key);
        try std.testing.expectEqualSlices(u8, &entry.hash, &decoded[entryIndex].hash);
        try std.testing.expectEqual(entry.length, decoded[entryIndex].length);
        try std.testing.expectEqual(entry.lastModified, decoded[entryIndex].lastModified);
    }
}

test "round-trips an empty set of entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const decoded = (try HashCache.decodeEntries(allocator, try HashCache.encodeEntries(allocator, &.{}))).?;

    try std.testing.expectEqual(@as(usize, 0), decoded.len);
}

test "returns undefined for an absent file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(try HashCache.decodeEntries(arena.allocator(), null) == null);
}

test "returns undefined for a buffer that is too small" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tooSmall = [_]u8{0} ** 39;
    try std.testing.expect(try HashCache.decodeEntries(arena.allocator(), &tooSmall) == null);
}

test "returns undefined for an unsupported version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const encoded = try HashCache.encodeEntries(allocator, &.{try makeEntry(allocator, "a/one.txt")});

    // Bump the version, then re-checksum so only the version makes it unusable.
    std.mem.writeInt(u32, encoded[0..4], 99, .little);

    try std.testing.expect(try HashCache.decodeEntries(allocator, try rechecksum(allocator, encoded)) == null);
}

test "returns undefined when the checksum does not match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const encoded = try HashCache.encodeEntries(allocator, &.{try makeEntry(allocator, "a/one.txt")});

    // Corrupt a byte in the middle of the entries without touching the checksum.
    encoded[20] = encoded[20] ^ 0xff;

    try std.testing.expect(try HashCache.decodeEntries(allocator, encoded) == null);
}

test "returns undefined when an entry runs past the end of the data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const encoded = try HashCache.encodeEntries(allocator, &.{try makeEntry(allocator, "a/one.txt")});

    // Claim a second entry that is not there, then re-checksum so only the truncation is wrong.
    std.mem.writeInt(u32, encoded[4..8], 2, .little);

    try std.testing.expect(try HashCache.decodeEntries(allocator, try rechecksum(allocator, encoded)) == null);
}

//
// Reads and decodes the cache file written to a directory.
//
fn readCacheFile(allocator: std.mem.Allocator, cacheDir: []const u8) !?[]IHashCacheEntry {
    return HashCache.decodeEntries(allocator, try helpers.readFile(allocator, std.testing.io, try std.fmt.allocPrint(allocator, "{s}/hash-cache-x.dat", .{cacheDir})));
}

//
// Writes a cache file containing the supplied entries, as if another instance had saved it.
//
fn writeCacheFile(allocator: std.mem.Allocator, cacheDir: []const u8, entries: []const IHashCacheEntry) !void {
    try helpers.writeFile(std.testing.io, try std.fmt.allocPrint(allocator, "{s}/hash-cache-x.dat", .{cacheDir}), try HashCache.encodeEntries(allocator, entries));
}

//
// The keys of decoded entries, in order.
//
fn entryKeys(allocator: std.mem.Allocator, entries: []const IHashCacheEntry) ![]const []const u8 {
    const keys = try allocator.alloc([]const u8, entries.len);
    for (entries, 0..) |entry, index| {
        keys[index] = entry.key;
    }
    return keys;
}

//
// Checks a list of strings.
//
fn expectStrings(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expectedString, actualString| {
        try std.testing.expectEqualStrings(expectedString, actualString);
    }
}

//
// Adds an entry built by makeEntry to a cache.
//
fn addEntry(cache: *HashCache, entry: IHashCacheEntry) !void {
    try cache.addHash(entry.key, .{
        .hash = &entry.hash,
        .length = entry.length,
        .lastModified = entry.lastModified,
    });
}

test "merges its own additions onto entries already on disk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cacheDir = try helpers.makeTempDir(allocator, io, "hash-cache-concurrent-test");
    defer helpers.removeTempDir(io, cacheDir);
    try writeCacheFile(allocator, cacheDir, &.{ try makeEntry(allocator, "a/one.txt"), try makeEntry(allocator, "b/two.txt") });

    var hashCache = try HashCache.init(cacheDir, false);
    defer hashCache.deinit();
    _ = try hashCache.load(io);
    try addEntry(&hashCache, try makeEntry(allocator, "c/three.txt"));
    try hashCache.save(io);

    const onDisk = (try readCacheFile(allocator, cacheDir)).?;
    try expectStrings(&.{ "a/one.txt", "b/two.txt", "c/three.txt" }, try entryKeys(allocator, onDisk));
}

test "keeps entries another instance added after this one loaded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cacheDir = try helpers.makeTempDir(allocator, io, "hash-cache-concurrent-test");
    defer helpers.removeTempDir(io, cacheDir);

    // Both instances load the same (empty) cache, so neither knows about the other's entries.
    var firstCache = try HashCache.init(cacheDir, false);
    defer firstCache.deinit();
    var secondCache = try HashCache.init(cacheDir, false);
    defer secondCache.deinit();
    _ = try firstCache.load(io);
    _ = try secondCache.load(io);

    try addEntry(&firstCache, try makeEntry(allocator, "first/file.txt"));
    try firstCache.save(io);

    try addEntry(&secondCache, try makeEntry(allocator, "second/file.txt"));
    try secondCache.save(io);

    // Before merge-on-save the second save overwrote the first instance's entry.
    const onDisk = (try readCacheFile(allocator, cacheDir)).?;
    try expectStrings(&.{ "first/file.txt", "second/file.txt" }, try entryKeys(allocator, onDisk));

    // The saving instance also picks up the entry it merged in.
    try std.testing.expect(try secondCache.getHash(allocator, "first/file.txt") != null);
    try std.testing.expectEqual(@as(u32, 2), secondCache.getEntryCount());
}

test "loses no entries when many instances load together and save one after another" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cacheDir = try helpers.makeTempDir(allocator, io, "hash-cache-concurrent-test");
    defer helpers.removeTempDir(io, cacheDir);
    const writerCount = 10;
    var caches: [writerCount]HashCache = undefined;

    // Every instance loads before any of them saves, the situation that used to lose entries.
    for (&caches) |*cache| {
        cache.* = try HashCache.init(cacheDir, false);
        _ = try cache.load(io);
    }
    defer {
        for (&caches) |*cache| {
            cache.deinit();
        }
    }

    for (&caches, 0..) |*cache, writerIndex| {
        try addEntry(cache, try makeEntry(allocator, try std.fmt.allocPrint(allocator, "writer{d}/file.txt", .{writerIndex})));
        try cache.save(io);
    }

    const onDisk = (try readCacheFile(allocator, cacheDir)).?;
    try std.testing.expectEqual(@as(usize, writerCount), onDisk.len);
    var writerIndex: usize = 0;
    while (writerIndex < writerCount) : (writerIndex += 1) {
        const key = try std.fmt.allocPrint(allocator, "writer{d}/file.txt", .{writerIndex});
        var found = false;
        for (onDisk) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                found = true;
            }
        }
        try std.testing.expect(found);
    }
}

test "applies removals to the on-disk cache instead of resurrecting them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cacheDir = try helpers.makeTempDir(allocator, io, "hash-cache-concurrent-test");
    defer helpers.removeTempDir(io, cacheDir);
    try writeCacheFile(allocator, cacheDir, &.{ try makeEntry(allocator, "a/one.txt"), try makeEntry(allocator, "b/two.txt") });

    var hashCache = try HashCache.init(cacheDir, false);
    defer hashCache.deinit();
    _ = try hashCache.load(io);
    try std.testing.expectEqual(true, try hashCache.removeHash("a/one.txt"));
    try hashCache.save(io);

    const onDisk = (try readCacheFile(allocator, cacheDir)).?;
    try expectStrings(&.{"b/two.txt"}, try entryKeys(allocator, onDisk));
}

//
// One of the overlapping savers of the test below.
//
fn saveOverlapping(cache: *HashCache) void {
    cache.save(std.testing.io) catch |err| {
        std.debug.panic("save failed: {s}", .{@errorName(err)});
    };
}

test "never publishes a corrupt file when saves overlap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cacheDir = try helpers.makeTempDir(allocator, io, "hash-cache-concurrent-test");
    defer helpers.removeTempDir(io, cacheDir);
    // Overlapping saves used to share one temp file path and interleave their bytes into it,
    // so the published file failed its checksum and the whole cache was discarded on load.
    const writerCount = 8;
    var caches: [writerCount]HashCache = undefined;
    for (&caches, 0..) |*cache, writerIndex| {
        cache.* = try HashCache.init(cacheDir, false);
        _ = try cache.load(io);
        try addEntry(cache, try makeEntry(allocator, try std.fmt.allocPrint(allocator, "overlap{d}/file.txt", .{writerIndex})));
    }
    defer {
        for (&caches) |*cache| {
            cache.deinit();
        }
    }

    var threads: [writerCount]std.Thread = undefined;
    for (&threads, &caches) |*thread, *cache| {
        thread.* = try std.Thread.spawn(.{}, saveOverlapping, .{cache});
    }
    for (threads) |thread| {
        thread.join();
    }

    // The file is always a complete, checksum-valid cache, whichever save published last.
    const onDisk = (try readCacheFile(allocator, cacheDir)).?;
    try std.testing.expect(onDisk.len > 0);
}

test "clears the changeset after a save so later saves only apply later changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cacheDir = try helpers.makeTempDir(allocator, io, "hash-cache-concurrent-test");
    defer helpers.removeTempDir(io, cacheDir);
    var hashCache = try HashCache.init(cacheDir, false);
    defer hashCache.deinit();
    _ = try hashCache.load(io);
    try addEntry(&hashCache, try makeEntry(allocator, "first/file.txt"));
    try hashCache.save(io);

    // Another instance replaces the file wholesale, dropping the first entry.
    try writeCacheFile(allocator, cacheDir, &.{try makeEntry(allocator, "other/file.txt")});

    try addEntry(&hashCache, try makeEntry(allocator, "second/file.txt"));
    try hashCache.save(io);

    // Only the change made since the last save is applied, not the whole in-memory snapshot.
    const onDisk = (try readCacheFile(allocator, cacheDir)).?;
    try expectStrings(&.{ "other/file.txt", "second/file.txt" }, try entryKeys(allocator, onDisk));
}

test "clears the changeset on load so pre-load changes are not re-applied" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const cacheDir = try helpers.makeTempDir(allocator, io, "hash-cache-concurrent-test");
    defer helpers.removeTempDir(io, cacheDir);
    var hashCache = try HashCache.init(cacheDir, false);
    defer hashCache.deinit();
    _ = try hashCache.load(io);
    try addEntry(&hashCache, try makeEntry(allocator, "discarded/file.txt"));

    // Reloading throws away everything that was not saved.
    _ = try hashCache.load(io);

    try addEntry(&hashCache, try makeEntry(allocator, "kept/file.txt"));
    try hashCache.save(io);

    const onDisk = (try readCacheFile(allocator, cacheDir)).?;
    try expectStrings(&.{"kept/file.txt"}, try entryKeys(allocator, onDisk));
}

test "gives two databases two different cache directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // An entry records the id its file has in the database, and the same photo imported into two
    // databases has two ids, so one cache cannot serve both.
    try std.testing.expect(!std.mem.eql(u8, try getHashCacheDir(allocator, "/photos/one"), try getHashCacheDir(allocator, "/photos/two")));
}

test "gives the same database the same cache directory every time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings(try getHashCacheDir(allocator, "/photos/one"), try getHashCacheDir(allocator, "/photos/one"));
}

test "names the hash cache apart from anything else kept about the database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // The database's cache directory is shared with whatever else this machine works out about
    // it, so the hash cache has a name of its own inside rather than being the directory itself.
    try std.testing.expectEqualStrings("hash-cache", path.basename(try getHashCacheDir(allocator, "/photos/one")));
}

test "makes a directory name out of a database path that could never be one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // An S3 database path has colons and slashes in it, which cannot be pasted into a directory
    // name on any platform.
    const name = path.basename(try getDatabaseCacheDir(allocator, "s3:my-bucket:/photos/db"));
    try std.testing.expect(name.len > 0);
    for (name) |character| {
        try std.testing.expect(std.ascii.isDigit(character) or (character >= 'a' and character <= 'f'));
    }
}

test "sits under the platform cache directory, not the process temp directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);
    // Everything the cache knows can be recomputed, but recomputing it for a photo library means
    // copying and hashing every photo already imported. Under the process temp directory that
    // happened at every reboot on Linux, and after a few untouched days on macOS, with nothing
    // to say it had.
    const runRoot = try helpers.makeTempDir(allocator, io, "hash-cache-home-check");
    defer helpers.removeTempDir(io, runRoot);
    try helpers.setEnv("PHOTOSPHERE_CACHE_DIR", try path.join(allocator, &.{ runRoot, "cache" }));
    defer helpers.setEnv("PHOTOSPHERE_CACHE_DIR", null) catch {};
    try helpers.setEnv("PHOTOSPHERE_TMP_DIR", try path.join(allocator, &.{ runRoot, "scratch" }));
    defer helpers.setEnv("PHOTOSPHERE_TMP_DIR", null) catch {};

    const cacheDir = try getHashCacheDir(allocator, "/photos/one");

    try std.testing.expect(std.mem.startsWith(u8, cacheDir, try getCacheDir(allocator)));
    try std.testing.expect(!std.mem.startsWith(u8, cacheDir, try getProcessTmpDir(allocator, io)));
}

test "sits inside the database cache directory, which is where anything else about a database goes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings(try getDatabaseCacheDir(allocator, "/photos/one"), path.dirname(try getHashCacheDir(allocator, "/photos/one")));
}

test "is still found once the process temp directory has been taken away" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);
    // This is the restart, as far as a test can stage one: the scratch directory is gone and the
    // cache is read back anyway. Every platform gets this, because every platform's temp
    // directory is swept by something the app never hears about.
    const runRoot = try helpers.makeTempDir(allocator, io, "hash-cache-survives-temp");
    defer helpers.removeTempDir(io, runRoot);
    try helpers.setEnv("PHOTOSPHERE_CACHE_DIR", try path.join(allocator, &.{ runRoot, "cache" }));
    defer helpers.setEnv("PHOTOSPHERE_CACHE_DIR", null) catch {};
    try helpers.setEnv("PHOTOSPHERE_TMP_DIR", try path.join(allocator, &.{ runRoot, "scratch" }));
    defer helpers.setEnv("PHOTOSPHERE_TMP_DIR", null) catch {};
    try std.Io.Dir.cwd().createDirPath(io, try getProcessTmpDir(allocator, io));

    var writer = try HashCache.init(try getHashCacheDir(allocator, "/photos/one"), false);
    defer writer.deinit();
    _ = try writer.load(io);
    try writer.addSourceHash("device-item-1", .{
        .hash = try createHash(allocator, "photo"),
        .length = 4096,
        .lastModified = 1700000000000,
    });
    try writer.save(io);

    // The process temp directory itself goes, exactly as a boot-time sweep of /tmp takes it.
    // Nothing put anything in it, so removing the directory alone is the whole of it.
    try std.Io.Dir.cwd().deleteDir(io, try getProcessTmpDir(allocator, io));

    var reader = try HashCache.init(try getHashCacheDir(allocator, "/photos/one"), false);
    defer reader.deinit();
    _ = try reader.load(io);

    try std.testing.expectEqual(@as(u64, 4096), (try reader.getHash(allocator, "device-item-1")).?.length);
}

test "a new entry has no asset id until one is recorded" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-asset-id-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.hashCache.load(std.testing.io);

    try context.hashCache.addHash("photos/one.jpg", .{
        .hash = try createHash(allocator, "one"),
        .length = 10,
        .lastModified = 1000,
    });

    try std.testing.expect((try context.hashCache.getHash(allocator, "photos/one.jpg")).?.assetId == null);
}

test "records an asset id against an entry" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-asset-id-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.hashCache.load(std.testing.io);
    try context.hashCache.addHash("photos/one.jpg", .{
        .hash = try createHash(allocator, "one"),
        .length = 10,
        .lastModified = 1000,
    });

    try std.testing.expectEqual(true, try context.hashCache.setAssetId("photos/one.jpg", "2f1c4a2e-0000-4000-8000-00000000abcd"));

    try std.testing.expectEqualStrings("2f1c4a2e-0000-4000-8000-00000000abcd", (try context.hashCache.getHash(allocator, "photos/one.jpg")).?.assetId.?);
}

test "an asset id survives a save and a load, which is the whole point of recording it" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-asset-id-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    _ = try context.hashCache.load(io);
    try context.hashCache.addHash("photos/one.jpg", .{
        .hash = try createHash(allocator, "one"),
        .length = 10,
        .lastModified = 1000,
    });
    _ = try context.hashCache.setAssetId("photos/one.jpg", "2f1c4a2e-0000-4000-8000-00000000abcd");
    try context.hashCache.save(io);

    var reloaded = try HashCache.init(context.cacheDir, false);
    defer reloaded.deinit();
    _ = try reloaded.load(io);

    try std.testing.expectEqualStrings("2f1c4a2e-0000-4000-8000-00000000abcd", (try reloaded.getHash(allocator, "photos/one.jpg")).?.assetId.?);
}

test "reports that nothing was recorded when there is no entry to record it against" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-asset-id-test");
    defer context.deinit();
    _ = try context.hashCache.load(std.testing.io);

    try std.testing.expectEqual(false, try context.hashCache.setAssetId("photos/missing.jpg", "some-asset-id"));
}

test "re-hashing a file clears its asset id, because the id described the old content" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-asset-id-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.hashCache.load(std.testing.io);
    try context.hashCache.addHash("photos/one.jpg", .{
        .hash = try createHash(allocator, "one"),
        .length = 10,
        .lastModified = 1000,
    });
    _ = try context.hashCache.setAssetId("photos/one.jpg", "2f1c4a2e-0000-4000-8000-00000000abcd");

    try context.hashCache.addHash("photos/one.jpg", .{
        .hash = try createHash(allocator, "one changed"),
        .length = 20,
        .lastModified = 2000,
    });

    try std.testing.expect((try context.hashCache.getHash(allocator, "photos/one.jpg")).?.assetId == null);
}

test "refuses an asset id too long to fit the space the format reserves" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-asset-id-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.hashCache.load(std.testing.io);
    try context.hashCache.addHash("photos/one.jpg", .{
        .hash = try createHash(allocator, "one"),
        .length = 10,
        .lastModified = 1000,
    });

    try std.testing.expectError(error.Thrown, context.hashCache.setAssetId("photos/one.jpg", "x" ** 37));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "does not fit") != null);
}

test "files an item under its source id, and finds it there" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-asset-id-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.hashCache.load(std.testing.io);

    // A MediaStore id, which is what a source id looks like on Android. There is no path here at
    // all: the photo has not been copied out of the library and never will be.
    try context.hashCache.addSourceHash("1000000042", .{
        .hash = try createHash(allocator, "library photo"),
        .length = 4096,
        .lastModified = 1700000000000,
    });

    const found = (try context.hashCache.getHash(allocator, "1000000042")).?;
    try std.testing.expectEqualSlices(u8, try createHash(allocator, "library photo"), found.hash);
}

test "remembers which entries are keyed by a source id and which by a path" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-asset-id-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    _ = try context.hashCache.load(io);
    try context.hashCache.addSourceHash("1000000042", .{
        .hash = try createHash(allocator, "library photo"),
        .length = 4096,
        .lastModified = 1700000000000,
    });
    try context.hashCache.addHash("photos/one.jpg", .{
        .hash = try createHash(allocator, "one"),
        .length = 10,
        .lastModified = 1000,
    });
    try context.hashCache.save(io);

    const onDisk = (try readCacheFile(allocator, context.cacheDir)).?;
    for (onDisk) |entry| {
        if (std.mem.eql(u8, entry.key, "1000000042")) {
            try std.testing.expectEqual(true, entry.keyedBySourceId);
        }
        else if (std.mem.eql(u8, entry.key, "photos/one.jpg")) {
            try std.testing.expectEqual(false, entry.keyedBySourceId);
        }
        else {
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), onDisk.len);
}

test "drops source-keyed entries the library no longer holds" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-asset-id-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.hashCache.load(std.testing.io);
    try context.hashCache.addSourceHash("still-here", .{
        .hash = try createHash(allocator, "a"),
        .length = 1,
        .lastModified = 1000,
    });
    try context.hashCache.addSourceHash("deleted-from-device", .{
        .hash = try createHash(allocator, "b"),
        .length = 2,
        .lastModified = 2000,
    });

    const removed = try context.hashCache.removeSourceEntriesNotIn(&.{"still-here"});

    try std.testing.expectEqual(@as(usize, 1), removed);
    try std.testing.expect(try context.hashCache.getHash(allocator, "deleted-from-device") == null);
    try std.testing.expect(try context.hashCache.getHash(allocator, "still-here") != null);
}

test "never drops a path-keyed entry, however absent it is from the library" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-asset-id-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    // This is the case that would throw away the desktop's whole cache the first time automatic
    // import walked a folder: a manual import's entries are not photo library items and cannot be
    // judged by whether the library still lists them.
    _ = try context.hashCache.load(std.testing.io);
    try context.hashCache.addHash("photos/manual-import.jpg", .{
        .hash = try createHash(allocator, "a"),
        .length = 1,
        .lastModified = 1000,
    });

    const removed = try context.hashCache.removeSourceEntriesNotIn(&.{"nothing-matching"});

    try std.testing.expectEqual(@as(usize, 0), removed);
    try std.testing.expect(try context.hashCache.getHash(allocator, "photos/manual-import.jpg") != null);
}

test "keeps an entry the walk saw at an absolute path" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-asset-id-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    // A watched folder's source ids are absolute paths, and an entry is stored with its leading
    // slash taken off. Compared raw, the stored "photos/one.jpg" never matched the live
    // "/photos/one.jpg", so on Linux and macOS every entry automatic import wrote was swept at
    // the end of the very run that wrote it and the whole folder was hashed again on the next.
    _ = try context.hashCache.load(std.testing.io);
    try context.hashCache.addSourceHash("/photos/one.jpg", .{
        .hash = try createHash(allocator, "a"),
        .length = 1,
        .lastModified = 1000,
    });

    const removed = try context.hashCache.removeSourceEntriesNotIn(&.{"/photos/one.jpg"});

    try std.testing.expectEqual(@as(usize, 0), removed);
    try std.testing.expect(try context.hashCache.getHash(allocator, "/photos/one.jpg") != null);
}

test "keeps an entry the walk saw at a Windows path" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-asset-id-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    // The same failure on the other separator: stored as "C:/photos/one.jpg", walked as
    // "C:\photos\one.jpg".
    _ = try context.hashCache.load(std.testing.io);
    try context.hashCache.addSourceHash("C:\\photos\\one.jpg", .{
        .hash = try createHash(allocator, "a"),
        .length = 1,
        .lastModified = 1000,
    });

    const removed = try context.hashCache.removeSourceEntriesNotIn(&.{"C:\\photos\\one.jpg"});

    try std.testing.expectEqual(@as(usize, 0), removed);
    try std.testing.expect(try context.hashCache.getHash(allocator, "C:\\photos\\one.jpg") != null);
}

test "still drops an absolute path the walk did not see" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-asset-id-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.hashCache.load(std.testing.io);
    try context.hashCache.addSourceHash("/photos/gone.jpg", .{
        .hash = try createHash(allocator, "a"),
        .length = 1,
        .lastModified = 1000,
    });

    try std.testing.expectEqual(@as(usize, 1), try context.hashCache.removeSourceEntriesNotIn(&.{"/photos/one.jpg"}));
    try std.testing.expect(try context.hashCache.getHash(allocator, "/photos/gone.jpg") == null);
}

test "a sweep survives a save, so the dropped entries are gone for the next run too" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-asset-id-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    _ = try context.hashCache.load(io);
    try context.hashCache.addSourceHash("still-here", .{
        .hash = try createHash(allocator, "a"),
        .length = 1,
        .lastModified = 1000,
    });
    try context.hashCache.addSourceHash("deleted-from-device", .{
        .hash = try createHash(allocator, "b"),
        .length = 2,
        .lastModified = 2000,
    });
    try context.hashCache.save(io);

    _ = try context.hashCache.removeSourceEntriesNotIn(&.{"still-here"});
    try context.hashCache.save(io);

    const onDisk = (try readCacheFile(allocator, context.cacheDir)).?;
    try expectStrings(&.{"still-here"}, try entryKeys(allocator, onDisk));
}

test "is discarded rather than read, whatever its version number says" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-version-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    // The cache is throwaway: everything in it can be recomputed, so a file written by any other
    // version of the format is thrown away and rebuilt rather than migrated. This is written as a
    // higher version deliberately: the rule is "not equal", not "older than".
    const fileBytes = try HashCache.encodeEntries(allocator, &.{try makeEntry(allocator, "a/one.txt")});
    std.mem.writeInt(u32, fileBytes[0..4], 999, .little);
    // The checksum covers the version, so it has to be recomputed or the file is rejected for
    // being corrupt instead, which would prove nothing about the version check.
    try helpers.writeFile(io, try std.fmt.allocPrint(allocator, "{s}/hash-cache-x.dat", .{context.cacheDir}), try rechecksum(allocator, fileBytes));

    const loaded = try context.hashCache.load(io);

    try std.testing.expectEqual(false, loaded);
    try std.testing.expectEqual(@as(u32, 0), context.hashCache.getEntryCount());
}

test "HashCache.save returns quietly when the update lock is held by somebody else" {
    var context: CacheTest = undefined;
    try context.init("hash-cache-save-test");
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    _ = try context.hashCache.load(io);
    try context.hashCache.addHash("a/one.txt", .{
        .hash = &([_]u8{7} ** 32),
        .length = 11,
        .lastModified = localDate(2024, 0, 1),
    });

    // Hold the lock the way another writer would, and leave it held. It stays well inside the
    // staleness threshold for the duration of this test, so it is never broken.
    const cachePath = try std.fmt.allocPrint(allocator, "{s}/hash-cache-x.dat", .{context.cacheDir});
    const lockPath = try std.fmt.allocPrint(allocator, "{s}.lock", .{cachePath});
    try helpers.writeFile(io, lockPath, "");

    try context.hashCache.save(io);

    // Nothing was published, because the save never got in.
    try std.testing.expect(!helpers.fileExists(io, cachePath));

    // The changeset was kept, so the entry lands as soon as the lock is free.
    try std.Io.Dir.cwd().deleteFile(io, lockPath);
    try context.hashCache.save(io);
    try std.testing.expect(helpers.fileExists(io, cachePath));
}

// Not ported: "rethrows when the update fails for a reason that is not contention" (hash-cache-save.test.ts), which
// makes the fault by mocking the fs/promises module; the Zig port has no module to mock.
