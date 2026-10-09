//
// Tests for apply-database-ops.zig (port of src/test/lib/apply-database-ops.test.ts).
//
// The TypeScript tests of applyMetadataDatabaseOps use a MockCollection; these use a real collection over an in-memory store,
// which is the collection the code runs against.
//

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const bdb = @import("bdb-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const virtual_time_io = @import("../../../utils-zig/src/test/virtual-time-io.zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const DatabaseFixture = @import("database-fixture.zig").DatabaseFixture;
const apply_database_ops = node_api.apply_database_ops;
const media_file_database = node_api.media_file_database;
const IDatabaseOp = api.database_op.IDatabaseOp;
const IBsonCollection = bdb.collection.IBsonCollection;

//
// Valid BSON document id (16-byte hex) for tests that hit the real collection implementation.
//
const BSON_RECORD_ID = "a1b2c3d4-e5f6-7890-abcd-ef1234567890";

//
// The fields of a minimal asset, as the JSON the page sends (TypeScript: minimalAsset).
//
fn minimalAssetJson(allocator: std.mem.Allocator, id: []const u8, extra: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"_id\":\"{s}\",\"origFileName\":\"x.jpg\",\"contentType\":\"image/jpeg\",\"width\":1,\"height\":1,\"hash\":\"ab\",\"fileDate\":\"2020-01-01T00:00:00.000Z\",\"uploadDate\":\"2020-01-01T00:00:00.000Z\",\"micro\":\"\",\"color\":[0,0,0]{s}}}", .{ id, extra });
}

//
// Reads a database op from the JSON the page sends.
//
fn opFromJson(allocator: std.mem.Allocator, text: []const u8) !IDatabaseOp {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
    return api.database_op.databaseOpFromJson(value);
}

//
// Minimal database op for grouping tests (payload shape is irrelevant to groupOpsByDatabaseId).
//
fn groupingOp(allocator: std.mem.Allocator, databaseId: []const u8, recordId: []const u8) !IDatabaseOp {
    return opFromJson(allocator, try std.fmt.allocPrint(allocator, "{{\"databaseId\":\"{s}\",\"collectionName\":\"metadata\",\"recordId\":\"{s}\",\"op\":{{\"type\":\"set\",\"fields\":{{}}}}}}", .{ databaseId, recordId }));
}

//
// A collection over an in-memory store (TypeScript: MockCollection).
//
const Fixture = struct {
    // The in-memory store.
    memory: MemoryStorage,

    // Deterministic uuids.
    uuidGenerator: node_utils.test_uuid_generator.TestUuidGenerator,

    // Deterministic time.
    timestampProvider: node_utils.test_timestamp_provider.TestTimestampProvider,

    // The collection under test.
    collection: *IBsonCollection,

    //
    // Fills in the fixture.
    //
    fn init(fixture: *Fixture, allocator: std.mem.Allocator) !void {
        fixture.memory = MemoryStorage.init(allocator);
        fixture.uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);
        fixture.timestampProvider = .{};
        const database = try bdb.database.BsonDatabase.init(allocator, fixture.memory.asStorage(), ".db/bson", fixture.uuidGenerator.uuidGenerator(), fixture.timestampProvider.timestampProvider());
        fixture.collection = try database.collection("metadata");
    }
};

// describe("groupOpsByDatabaseId")

test "groupOpsByDatabaseId returns an empty map for an empty op list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const groups = try apply_database_ops.groupOpsByDatabaseId(arena.allocator(), &.{});
    try std.testing.expectEqual(@as(usize, 0), groups.count());
}

test "groupOpsByDatabaseId places a single op under its databaseId" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const op = try groupingOp(allocator, "/db/a", "r1");
    const groups = try apply_database_ops.groupOpsByDatabaseId(allocator, &.{op});
    try std.testing.expectEqual(@as(usize, 1), groups.count());
    try std.testing.expectEqual(@as(usize, 1), groups.get("/db/a").?.items.len);
    try std.testing.expectEqualStrings("r1", groups.get("/db/a").?.items[0].recordId);
}

test "groupOpsByDatabaseId appends ops for the same databaseId in input order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const first = try groupingOp(allocator, "/db/shared", "first");
    const second = try groupingOp(allocator, "/db/shared", "second");
    const groups = try apply_database_ops.groupOpsByDatabaseId(allocator, &.{ first, second });
    const grouped = groups.get("/db/shared").?.items;
    try std.testing.expectEqual(@as(usize, 2), grouped.len);
    try std.testing.expectEqualStrings("first", grouped[0].recordId);
    try std.testing.expectEqualStrings("second", grouped[1].recordId);
}

test "groupOpsByDatabaseId splits ops with different databaseIds into separate arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const pathA = try groupingOp(allocator, "/db/a", "x");
    const pathB = try groupingOp(allocator, "/db/b", "y");
    const pathA2 = try groupingOp(allocator, "/db/a", "z");
    const groups = try apply_database_ops.groupOpsByDatabaseId(allocator, &.{ pathA, pathB, pathA2 });
    try std.testing.expectEqual(@as(usize, 2), groups.count());
    try std.testing.expectEqual(@as(usize, 2), groups.get("/db/a").?.items.len);
    try std.testing.expectEqualStrings("x", groups.get("/db/a").?.items[0].recordId);
    try std.testing.expectEqualStrings("z", groups.get("/db/a").?.items[1].recordId);
    try std.testing.expectEqual(@as(usize, 1), groups.get("/db/b").?.items.len);
    try std.testing.expectEqualStrings("y", groups.get("/db/b").?.items[0].recordId);
}

test "groupOpsByDatabaseId iterates database keys in first-seen order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const bFirst = try groupingOp(allocator, "/db/b", "1");
    const aSecond = try groupingOp(allocator, "/db/a", "2");
    const bThird = try groupingOp(allocator, "/db/b", "3");
    const groups = try apply_database_ops.groupOpsByDatabaseId(allocator, &.{ bFirst, aSecond, bThird });
    try std.testing.expectEqual(@as(usize, 2), groups.keys().len);
    try std.testing.expectEqualStrings("/db/b", groups.keys()[0]);
    try std.testing.expectEqualStrings("/db/a", groups.keys()[1]);
}

// describe("applyMetadataDatabaseOps")

test "applyMetadataDatabaseOps set with upsert creates a new metadata record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    const fields = try minimalAssetJson(allocator, "wrong-id-should-be-stripped", "");
    const op = try opFromJson(allocator, try std.fmt.allocPrint(allocator, "{{\"databaseId\":\"/ignored-for-this-test\",\"collectionName\":\"metadata\",\"recordId\":\"{s}\",\"op\":{{\"type\":\"set\",\"fields\":{s}}}}}", .{ BSON_RECORD_ID, fields }));

    try apply_database_ops.applyMetadataDatabaseOps(allocator, io, fixture.collection, &.{op});

    const saved = (try fixture.collection.getOne(io, BSON_RECORD_ID)).?;
    try std.testing.expectEqualStrings(BSON_RECORD_ID, saved.get("_id").?.string);
    try std.testing.expectEqualStrings("x.jpg", saved.get("origFileName").?.string);
}

test "applyMetadataDatabaseOps set merges into an existing record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    const existing = try opFromJson(allocator, try std.fmt.allocPrint(allocator, "{{\"databaseId\":\"/x\",\"collectionName\":\"metadata\",\"recordId\":\"{s}\",\"op\":{{\"type\":\"set\",\"fields\":{s}}}}}", .{ BSON_RECORD_ID, try minimalAssetJson(allocator, BSON_RECORD_ID, ",\"description\":\"old\"") }));
    try apply_database_ops.applyMetadataDatabaseOps(allocator, io, fixture.collection, &.{existing});
    const change = try opFromJson(allocator, try std.fmt.allocPrint(allocator, "{{\"databaseId\":\"/x\",\"collectionName\":\"metadata\",\"recordId\":\"{s}\",\"op\":{{\"type\":\"set\",\"fields\":{{\"description\":\"new\"}}}}}}", .{BSON_RECORD_ID}));

    try apply_database_ops.applyMetadataDatabaseOps(allocator, io, fixture.collection, &.{change});

    const saved = (try fixture.collection.getOne(io, BSON_RECORD_ID)).?;
    try std.testing.expectEqualStrings("new", saved.get("description").?.string);
    try std.testing.expectEqualStrings("x.jpg", saved.get("origFileName").?.string);
}

//
// Makes a record with a labels array, then applies an op of the given type and value to it, and returns the labels afterwards.
//
fn labelsAfter(allocator: std.mem.Allocator, startingLabels: []const u8, opType: []const u8, value: []const u8) ![]const []const u8 {
    const io = std.testing.io;
    var fixture: *Fixture = try allocator.create(Fixture);
    try fixture.init(allocator);
    const create = try opFromJson(allocator, try std.fmt.allocPrint(allocator, "{{\"databaseId\":\"/x\",\"collectionName\":\"metadata\",\"recordId\":\"{s}\",\"op\":{{\"type\":\"set\",\"fields\":{s}}}}}", .{ BSON_RECORD_ID, try minimalAssetJson(allocator, BSON_RECORD_ID, startingLabels) }));
    try apply_database_ops.applyMetadataDatabaseOps(allocator, io, fixture.collection, &.{create});
    const change = try opFromJson(allocator, try std.fmt.allocPrint(allocator, "{{\"databaseId\":\"/x\",\"collectionName\":\"metadata\",\"recordId\":\"{s}\",\"op\":{{\"type\":\"{s}\",\"field\":\"labels\",\"value\":\"{s}\"}}}}", .{ BSON_RECORD_ID, opType, value }));
    try apply_database_ops.applyMetadataDatabaseOps(allocator, io, fixture.collection, &.{change});
    const saved = (try fixture.collection.getOne(io, BSON_RECORD_ID)).?;
    var labels: std.ArrayList([]const u8) = .empty;
    for (saved.get("labels").?.array) |label| {
        try labels.append(allocator, label.string);
    }
    return labels.items;
}

test "applyMetadataDatabaseOps push appends a value to an array field when absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const labels = try labelsAfter(arena.allocator(), ",\"labels\":[\"x\"]", "push", "y");
    try std.testing.expectEqual(@as(usize, 2), labels.len);
    try std.testing.expectEqualStrings("x", labels[0]);
    try std.testing.expectEqualStrings("y", labels[1]);
}

test "applyMetadataDatabaseOps push does not duplicate an existing value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const labels = try labelsAfter(arena.allocator(), ",\"labels\":[\"x\"]", "push", "x");
    try std.testing.expectEqual(@as(usize, 1), labels.len);
    try std.testing.expectEqualStrings("x", labels[0]);
}

test "applyMetadataDatabaseOps push creates the array when the field is not an array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const labels = try labelsAfter(arena.allocator(), "", "push", "x");
    try std.testing.expectEqual(@as(usize, 1), labels.len);
    try std.testing.expectEqualStrings("x", labels[0]);
}

test "applyMetadataDatabaseOps pull removes a value from an array field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const labels = try labelsAfter(arena.allocator(), ",\"labels\":[\"x\",\"y\"]", "pull", "x");
    try std.testing.expectEqual(@as(usize, 1), labels.len);
    try std.testing.expectEqualStrings("y", labels[0]);
}

test "applyMetadataDatabaseOps push throws when the record is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    const op = try opFromJson(allocator, "{\"databaseId\":\"/x\",\"collectionName\":\"metadata\",\"recordId\":\"c1c2c3c4-e5f6-7890-abcd-ef1234567890\",\"op\":{\"type\":\"push\",\"field\":\"labels\",\"value\":\"x\"}}");

    try std.testing.expectError(error.Thrown, apply_database_ops.applyMetadataDatabaseOps(allocator, std.testing.io, fixture.collection, &.{op}));
    try std.testing.expectEqualStrings("Cannot push: metadata record \"c1c2c3c4-e5f6-7890-abcd-ef1234567890\" does not exist.", utils.errors.errorMessage(error.Thrown));
}

test "applyMetadataDatabaseOps pull throws when the record is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    const op = try opFromJson(allocator, "{\"databaseId\":\"/x\",\"collectionName\":\"metadata\",\"recordId\":\"c1c2c3c4-e5f6-7890-abcd-ef1234567890\",\"op\":{\"type\":\"pull\",\"field\":\"labels\",\"value\":\"x\"}}");

    try std.testing.expectError(error.Thrown, apply_database_ops.applyMetadataDatabaseOps(allocator, std.testing.io, fixture.collection, &.{op}));
    try std.testing.expectEqualStrings("Cannot pull: metadata record \"c1c2c3c4-e5f6-7890-abcd-ef1234567890\" does not exist.", utils.errors.errorMessage(error.Thrown));
}

test "applyMetadataDatabaseOps rejects unsupported collection names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture: Fixture = undefined;
    try fixture.init(allocator);
    const op = try opFromJson(allocator, "{\"databaseId\":\"/x\",\"collectionName\":\"other\",\"recordId\":\"a1\",\"op\":{\"type\":\"set\",\"fields\":{\"description\":\"x\"}}}");

    try std.testing.expectError(error.Thrown, apply_database_ops.applyMetadataDatabaseOps(allocator, std.testing.io, fixture.collection, &.{op}));
    try std.testing.expectEqualStrings("Unsupported collection \"other\". Only \"metadata\" is supported.", utils.errors.errorMessage(error.Thrown));
}

// describe("applyDatabaseOps")

//
// A set op for a new record in the database at the path.
//
fn setOpFor(allocator: std.mem.Allocator, databasePath: []const u8, recordId: []const u8) !IDatabaseOp {
    const databasePathJson = try utils.json.stringify(allocator, databasePath);
    return opFromJson(allocator, try std.fmt.allocPrint(allocator, "{{\"databaseId\":{s},\"collectionName\":\"metadata\",\"recordId\":\"{s}\",\"op\":{{\"type\":\"set\",\"fields\":{s}}}}}", .{ databasePathJson, recordId, try minimalAssetJson(allocator, recordId, "") }));
}

test "applyDatabaseOps acquires write lock and persists metadata on a real database directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "apply-database-ops-lock");
    defer fixture.deinit(io);
    const op = try setOpFor(allocator, fixture.dir, BSON_RECORD_ID);

    try apply_database_ops.applyDatabaseOps(allocator, io, fixture.uuidGenerator.uuidGenerator(), fixture.timestampProvider.timestampProvider(), "session-1", &.{op});

    const created = try node_api.open_storage.openStorage(allocator, io, fixture.dir, null, null);
    const verifyDb = try media_file_database.createMediaFileDatabase(allocator, created.storage, fixture.uuidGenerator.uuidGenerator(), fixture.timestampProvider.timestampProvider());
    try media_file_database.loadSortIndexes(allocator, created.storage, verifyDb.metadataCollection);
    const loaded = (try verifyDb.metadataCollection.getOne(io, BSON_RECORD_ID)).?;
    try std.testing.expectEqualStrings("x.jpg", loaded.get("origFileName").?.string);
    // The lock is let go once the ops are applied.
    try std.testing.expect((try fixture.rawStorage.checkWriteLock(allocator, io, ".db/write.lock")) == null);
}

test "applyDatabaseOps does nothing for an empty op list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var uuidGenerator = try node_utils.test_uuid_generator.TestUuidGenerator.init(allocator);
    var timestampProvider: utils.timestamp_provider.TimestampProvider = .{};

    try apply_database_ops.applyDatabaseOps(allocator, io, uuidGenerator.uuidGenerator(), timestampProvider.timestampProvider(), "session-1", &.{});
}

test "applyDatabaseOps throws when another session holds the write lock, and changes nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "apply-database-ops-locked");
    defer fixture.deinit(io);
    try std.testing.expect(try fixture.rawStorage.acquireWriteLock(allocator, io, ".db/write.lock", "another-session"));
    const op = try setOpFor(allocator, fixture.dir, BSON_RECORD_ID);

    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(null, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    try std.testing.expectError(error.Thrown, apply_database_ops.applyDatabaseOps(allocator, io, fixture.uuidGenerator.uuidGenerator(), fixture.timestampProvider.timestampProvider(), "session-1", &.{op}));
    try std.testing.expectEqualStrings("Failed to acquire write lock.", utils.errors.errorMessage(error.Thrown));
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.written(), "Lock is currently held by \"another-session\"") != null);

    // The other session still holds its lock.
    const lockInfo = (try fixture.rawStorage.checkWriteLock(allocator, io, ".db/write.lock")).?;
    try std.testing.expectEqualStrings("another-session", lockInfo.owner);
}

test "applyDatabaseOps stamps lastModifiedAt on the database state after applying ops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "apply-database-ops-stamp");
    defer fixture.deinit(io);
    const op = try setOpFor(allocator, fixture.dir, BSON_RECORD_ID);

    try apply_database_ops.applyDatabaseOps(allocator, io, fixture.uuidGenerator.uuidGenerator(), fixture.timestampProvider.timestampProvider(), "session-1", &.{op});

    const state = (try api.database_state.loadDatabaseState(allocator, io, fixture.rawStorage)).?;
    try std.testing.expect(state.lastModifiedAt != null);
    try std.testing.expect(state.lastModifiedAt.?.len > 0);
}

test "applyDatabaseOps writes state separately for each database group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var fixtureA: DatabaseFixture = undefined;
    try fixtureA.init(allocator, io, "apply-database-ops-stamp-a");
    defer fixtureA.deinit(io);
    var fixtureB: DatabaseFixture = undefined;
    try fixtureB.init(allocator, io, "apply-database-ops-stamp-b");
    defer fixtureB.deinit(io);
    const recordIdB = "b1c2d3e4-f506-7890-abcd-ef1234567890";
    const opA = try setOpFor(allocator, fixtureA.dir, BSON_RECORD_ID);
    const opB = try setOpFor(allocator, fixtureB.dir, recordIdB);

    try apply_database_ops.applyDatabaseOps(allocator, io, fixtureA.uuidGenerator.uuidGenerator(), fixtureA.timestampProvider.timestampProvider(), "session-1", &.{ opA, opB });

    const stateA = (try api.database_state.loadDatabaseState(allocator, io, fixtureA.rawStorage)).?;
    const stateB = (try api.database_state.loadDatabaseState(allocator, io, fixtureB.rawStorage)).?;
    try std.testing.expect(stateA.lastModifiedAt != null);
    try std.testing.expect(stateB.lastModifiedAt != null);
}
