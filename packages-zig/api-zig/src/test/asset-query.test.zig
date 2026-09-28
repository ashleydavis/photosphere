const std = @import("std");
const api_zig = @import("api-zig");
const utils = @import("utils-zig");
const bdb = @import("bdb-zig");
const serialization_zig = @import("serialization-zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const BsonDocument = serialization_zig.bson.BsonDocument;
const BsonValue = serialization_zig.bson.BsonValue;
const BsonDatabase = bdb.database.BsonDatabase;
const asset_query = api_zig.asset_query;
const listAssetPage = asset_query.listAssetPage;
const searchAssets = asset_query.searchAssets;
const getAsset = asset_query.getAsset;
const streamAssetToFile = asset_query.streamAssetToFile;
const IAsset = asset_query.IAsset;
const io = std.testing.io;

//
// UUID v4 record IDs used across the tests. The bdb collection layer rejects non-16-byte IDs.
//
const ID_A = "11111111-1111-4111-a111-111111111111";

//
// The second record ID of the tests.
//
const ID_B = "22222222-2222-4222-a222-222222222222";

//
// The third record ID of the tests.
//
const ID_C = "33333333-3333-4333-a333-333333333333";

//
// Generates the IDs the database needs (none of the tests insert a record without one).
//
var uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};

//
// Provides the timestamps of the inserted records.
//
var timestamp_provider: utils.timestamp_provider.TimestampProvider = .{};

//
// A field of a test asset that overrides the default (TypeScript: an entry of `Partial<IAsset>`).
//
const IAssetOverride = struct {
    // The name of the field.
    name: []const u8,

    // Its value.
    value: BsonValue,
};

//
// Builds a minimal IAsset for tests; overrides win.
//
fn makeAsset(allocator: std.mem.Allocator, overrides: []const IAssetOverride) !IAsset {
    var now: std.Io.Writer.Allocating = .init(allocator);
    try serialization_zig.js_date.writeIsoString(&now.writer, timestamp_provider.timestampProvider().now(io));
    const color = try allocator.alloc(BsonValue, 3);
    for (color) |*component| {
        component.* = .{ .number = 0 };
    }
    var asset: BsonDocument = .empty;
    try asset.put(allocator, "_id", .{ .string = "asset-1" });
    try asset.put(allocator, "origFileName", .{ .string = "x.jpg" });
    try asset.put(allocator, "contentType", .{ .string = "image/jpeg" });
    try asset.put(allocator, "width", .{ .number = 1 });
    try asset.put(allocator, "height", .{ .number = 1 });
    try asset.put(allocator, "hash", .{ .string = "ab" });
    try asset.put(allocator, "fileDate", .{ .string = now.written() });
    try asset.put(allocator, "uploadDate", .{ .string = now.written() });
    try asset.put(allocator, "micro", .{ .string = "" });
    try asset.put(allocator, "color", .{ .array = color });
    for (overrides) |override| {
        try asset.put(allocator, override.name, override.value);
    }
    return asset;
}

//
// Builds a fresh BsonDatabase backed by an in-memory MockStorage and inserts the supplied
// assets. Ensures the photoDate sort index so listAssetPage works.
//
fn buildDatabase(allocator: std.mem.Allocator, assets: []const IAsset) !*BsonDatabase {
    const storage = try allocator.create(MemoryStorage);
    storage.* = MemoryStorage.init(allocator);
    const database = try BsonDatabase.init(allocator, storage.asStorage(), "", uuid_generator.uuidGenerator(), timestamp_provider.timestampProvider());
    const collection = try database.collection("metadata");
    try (try collection.sortIndex("photoDate", .desc)).ensure(io, collection, .date);
    for (assets) |asset| {
        var record = asset;
        try collection.insertOne(io, &record, null);
    }
    return database;
}

//
// The IDs of assets, in order.
//
fn assetIds(allocator: std.mem.Allocator, assets: []const IAsset) ![]const []const u8 {
    const ids = try allocator.alloc([]const u8, assets.len);
    for (assets, 0..) |asset, assetIndex| {
        ids[assetIndex] = asset.get("_id").?.string;
    }
    return ids;
}

//
// The IDs of assets, sorted (TypeScript: `.map(asset => asset._id).sort()`).
//
fn sortedAssetIds(allocator: std.mem.Allocator, assets: []const IAsset) ![]const []const u8 {
    const ids = try allocator.dupe([]const u8, try assetIds(allocator, assets));
    std.mem.sort([]const u8, ids, {}, lessThanString);
    return ids;
}

//
// Orders strings like JavaScript's default sort (by UTF-16 code units, the same as bytes for these ASCII IDs).
//
fn lessThanString(context: void, left: []const u8, right: []const u8) bool {
    _ = context;
    return std.mem.lessThan(u8, left, right);
}

//
// Expects a list of IDs.
//
fn expectIds(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expectedId, actualId| {
        try std.testing.expectEqualStrings(expectedId, actualId);
    }
}

test "listAssetPage returns assets sorted by photoDate descending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const assets = [_]IAsset{
        try makeAsset(allocator, &.{ .{ .name = "_id", .value = .{ .string = ID_A } }, .{ .name = "origFileName", .value = .{ .string = "a.jpg" } }, .{ .name = "photoDate", .value = .{ .string = "2023-01-01T00:00:00.000Z" } } }),
        try makeAsset(allocator, &.{ .{ .name = "_id", .value = .{ .string = ID_B } }, .{ .name = "origFileName", .value = .{ .string = "b.jpg" } }, .{ .name = "photoDate", .value = .{ .string = "2024-06-15T00:00:00.000Z" } } }),
        try makeAsset(allocator, &.{ .{ .name = "_id", .value = .{ .string = ID_C } }, .{ .name = "origFileName", .value = .{ .string = "c.jpg" } }, .{ .name = "photoDate", .value = .{ .string = "2022-12-31T00:00:00.000Z" } } }),
    };
    const database = try buildDatabase(allocator, &assets);

    const page = try listAssetPage(io, database, 10, null);

    try expectIds(&.{ ID_B, ID_A, ID_C }, try assetIds(allocator, page.assets));
}

test "listAssetPage limits the page size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const assets = [_]IAsset{
        try makeAsset(allocator, &.{ .{ .name = "_id", .value = .{ .string = ID_A } }, .{ .name = "photoDate", .value = .{ .string = "2023-01-01T00:00:00.000Z" } } }),
        try makeAsset(allocator, &.{ .{ .name = "_id", .value = .{ .string = ID_B } }, .{ .name = "photoDate", .value = .{ .string = "2024-06-15T00:00:00.000Z" } } }),
        try makeAsset(allocator, &.{ .{ .name = "_id", .value = .{ .string = ID_C } }, .{ .name = "photoDate", .value = .{ .string = "2022-12-31T00:00:00.000Z" } } }),
    };
    const database = try buildDatabase(allocator, &assets);

    const page = try listAssetPage(io, database, 2, null);

    try std.testing.expectEqual(@as(usize, 2), page.assets.len);
}

test "searchAssets filters by case-insensitive substring on origFileName" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const assets = [_]IAsset{
        try makeAsset(allocator, &.{ .{ .name = "_id", .value = .{ .string = ID_A } }, .{ .name = "origFileName", .value = .{ .string = "Beach.jpg" } } }),
        try makeAsset(allocator, &.{ .{ .name = "_id", .value = .{ .string = ID_B } }, .{ .name = "origFileName", .value = .{ .string = "mountain.png" } } }),
        try makeAsset(allocator, &.{ .{ .name = "_id", .value = .{ .string = ID_C } }, .{ .name = "origFileName", .value = .{ .string = "BEACH_party.mp4" } } }),
    };
    const database = try buildDatabase(allocator, &assets);

    const matches = try searchAssets(allocator, io, database, "beach", null, null, null, 10);

    try expectIds(&.{ ID_A, ID_C }, try sortedAssetIds(allocator, matches));
}

test "searchAssets filters by content type prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const assets = [_]IAsset{
        try makeAsset(allocator, &.{ .{ .name = "_id", .value = .{ .string = ID_A } }, .{ .name = "contentType", .value = .{ .string = "image/jpeg" } } }),
        try makeAsset(allocator, &.{ .{ .name = "_id", .value = .{ .string = ID_B } }, .{ .name = "contentType", .value = .{ .string = "video/mp4" } } }),
        try makeAsset(allocator, &.{ .{ .name = "_id", .value = .{ .string = ID_C } }, .{ .name = "contentType", .value = .{ .string = "image/png" } } }),
    };
    const database = try buildDatabase(allocator, &assets);

    const matches = try searchAssets(allocator, io, database, "", "image/", null, null, 10);

    try expectIds(&.{ ID_A, ID_C }, try sortedAssetIds(allocator, matches));
}

test "searchAssets filters by date range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const assets = [_]IAsset{
        try makeAsset(allocator, &.{ .{ .name = "_id", .value = .{ .string = ID_A } }, .{ .name = "photoDate", .value = .{ .string = "2020-01-01T00:00:00.000Z" } } }),
        try makeAsset(allocator, &.{ .{ .name = "_id", .value = .{ .string = ID_B } }, .{ .name = "photoDate", .value = .{ .string = "2024-01-01T00:00:00.000Z" } } }),
        try makeAsset(allocator, &.{ .{ .name = "_id", .value = .{ .string = ID_C } }, .{ .name = "photoDate", .value = .{ .string = "2022-06-01T00:00:00.000Z" } } }),
    };
    const database = try buildDatabase(allocator, &assets);

    const matches = try searchAssets(allocator, io, database, "", null, "2021-01-01", "2023-12-31", 10);

    try expectIds(&.{ID_C}, try assetIds(allocator, matches));
}

test "searchAssets stops at the requested limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const assets = [_]IAsset{
        try makeAsset(allocator, &.{ .{ .name = "_id", .value = .{ .string = ID_A } }, .{ .name = "origFileName", .value = .{ .string = "one.jpg" } } }),
        try makeAsset(allocator, &.{ .{ .name = "_id", .value = .{ .string = ID_B } }, .{ .name = "origFileName", .value = .{ .string = "two.jpg" } } }),
        try makeAsset(allocator, &.{ .{ .name = "_id", .value = .{ .string = ID_C } }, .{ .name = "origFileName", .value = .{ .string = "three.jpg" } } }),
    };
    const database = try buildDatabase(allocator, &assets);

    const matches = try searchAssets(allocator, io, database, ".jpg", null, null, null, 2);

    try std.testing.expectEqual(@as(usize, 2), matches.len);
}

test "getAsset returns the asset when present" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const database = try buildDatabase(allocator, &.{try makeAsset(allocator, &.{ .{ .name = "_id", .value = .{ .string = ID_A } }, .{ .name = "origFileName", .value = .{ .string = "found.jpg" } } })});

    const asset = try getAsset(io, database, ID_A);

    try std.testing.expectEqualStrings("found.jpg", asset.?.get("origFileName").?.string);
}

test "getAsset returns undefined when missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const database = try buildDatabase(allocator, &.{});

    const asset = try getAsset(io, database, ID_B);

    try std.testing.expect(asset == null);
}

test "streamAssetToFile streams bytes from storage to disk, creating parent directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tempDir = std.testing.tmpDir(.{});
    defer tempDir.cleanup();
    var storage = MemoryStorage.init(allocator);
    const payload = "hello world";
    try storage.asStorage().write(allocator, io, "asset/original-asset-id", "application/octet-stream", payload);

    const outputPath = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tempDir.sub_path, "out", "nested", "original.bin" });
    const bytes = try streamAssetToFile(allocator, io, storage.asStorage(), "original-asset-id", outputPath, "original");

    try std.testing.expectEqual(@as(u64, payload.len), bytes);
    const written = try std.Io.Dir.cwd().readFileAlloc(io, outputPath, allocator, .unlimited);
    try std.testing.expectEqualStrings(payload, written);
}

test "streamAssetToFile maps type 'display' to the display/ storage prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tempDir = std.testing.tmpDir(.{});
    defer tempDir.cleanup();
    var storage = MemoryStorage.init(allocator);
    const payload = "display-bytes";
    try storage.asStorage().write(allocator, io, "display/display-asset-id", "image/jpeg", payload);

    const outputPath = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tempDir.sub_path, "display.bin" });
    const bytes = try streamAssetToFile(allocator, io, storage.asStorage(), "display-asset-id", outputPath, "display");

    try std.testing.expectEqual(@as(u64, payload.len), bytes);
}
