//
// Tests for BsonCollection.iterateShards (port of src/tests/iterate-shards.test.ts).
//

const std = @import("std");
const bdb = @import("bdb-zig");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const test_clock = @import("test-clock.zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const BsonDocument = serialization_zig.bson.BsonDocument;
const BsonCollection = bdb.collection.BsonCollection;

const io = std.testing.io;

//
// Generates the ids of records inserted without one.
//
var random_uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};

//
// The onDirty callback given to the collection under test (TypeScript: `() => {}`).
//
fn onDirty(context: *anyopaque) void {
    _ = context;
}

//
// Creates the collection under test (TypeScript: the beforeEach block).
//
fn newCollection(allocator: std.mem.Allocator, storage: *MemoryStorage) !*BsonCollection {
    const collection = try allocator.create(BsonCollection);
    collection.* = BsonCollection.init(allocator, "users", "", storage.asStorage(), "", random_uuid_generator.uuidGenerator(), test_clock.timestamp_provider.timestampProvider(), .{ .context = storage, .function = onDirty });
    return collection;
}

//
// Builds a TestUser document (TypeScript: the object literal).
//
fn makeUser(allocator: std.mem.Allocator, id: []const u8, name: []const u8, email: []const u8, age: f64, role: []const u8) !BsonDocument {
    return BsonDocument.fromFields(allocator, &.{
        .{ .key = "_id", .value = .{ .string = id } },
        .{ .key = "name", .value = .{ .string = name } },
        .{ .key = "email", .value = .{ .string = email } },
        .{ .key = "age", .value = .{ .number = age } },
        .{ .key = "role", .value = .{ .string = role } },
    });
}

//
// Inserts the three users the tests create, with ids chosen to hash to different shards.
//
fn insertUsers(allocator: std.mem.Allocator, collection: *BsonCollection) !usize {
    var users = [_]BsonDocument{
        try makeUser(allocator, "123e4567-e89b-12d3-a456-426614174001", "User 1", "user1@example.com", 30, "user"),
        try makeUser(allocator, "223e4567-e89b-12d3-a456-426614174002", "User 2", "user2@example.com", 35, "admin"),
        try makeUser(allocator, "323e4567-e89b-12d3-a456-426614174003", "User 3", "user3@example.com", 25, "user"),
    };

    // Insert all users
    for (&users) |*user| {
        try collection.insertOne(io, user, null);
    }
    return users.len;
}

test "should iterate through empty collection shards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);

    var shardCount: usize = 0;
    var shards = collection.iterateShards();
    while (try shards.next(io)) |_| {
        shardCount += 1;
    }

    try std.testing.expectEqual(@as(usize, 0), shardCount);
}

test "should iterate through collection shards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);

    // Create test users - choose IDs that will hash to different shards
    const userCount = try insertUsers(allocator, collection);

    // Collect all shards from the iterator
    var shardCount: usize = 0;
    var totalRecords: usize = 0;
    var shards = collection.iterateShards();
    while (try shards.next(io)) |shardRecords| {
        shardCount += 1;

        // Count total number of records across all shards
        totalRecords += shardRecords.len;
    }

    // Verify we got all records
    try std.testing.expectEqual(userCount, totalRecords);

    // Each shard should contain users
    try std.testing.expect(shardCount > 0);
}

test "should process shards independently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);

    // Create users in different roles to test shard-based processing
    const userCount = try insertUsers(allocator, collection);

    // Process shards to compute shard-level statistics
    var nonEmptyShards: usize = 0;
    var totalRecords: usize = 0;
    var shards = collection.iterateShards();
    while (try shards.next(io)) |shardRecords| {
        // Calculate average age per shard
        var totalAge: f64 = 0;
        for (shardRecords) |record| {
            totalAge += record.fields.get("age").?.number;
        }
        const avgAge = if (shardRecords.len > 0) totalAge / @as(f64, @floatFromInt(shardRecords.len)) else 0;
        try std.testing.expect(avgAge >= 25 and avgAge <= 35);

        // Count roles per shard
        var roleCounts: std.StringHashMapUnmanaged(usize) = .empty;
        for (shardRecords) |record| {
            const role = record.fields.get("role").?.string;
            const previous = roleCounts.get(role) orelse 0;
            try roleCounts.put(allocator, role, previous + 1);
        }

        if (shardRecords.len > 0) {
            nonEmptyShards += 1;
        }
        totalRecords += shardRecords.len;
    }

    // Verify we have statistics for non-empty shards
    try std.testing.expect(nonEmptyShards > 0);

    // Total records across all shards should match our input
    try std.testing.expectEqual(userCount, totalRecords);
}
