const std = @import("std");
const bdb = @import("bdb-zig");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const helpers = @import("test-helpers.zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const bson = serialization_zig.bson;
const BsonValue = bson.BsonValue;
const BsonDocument = bson.BsonDocument;
const BsonCollection = bdb.collection.BsonCollection;
const IInternalRecord = bdb.shard.IInternalRecord;
const SortIndex = bdb.sort_index.SortIndex;
const SortDirection = bdb.sort_index.SortDirection;
const SortDataType = bdb.sort_index.SortDataType;
const DirtyCallback = bdb.collection.DirtyCallback;
const errors = utils.errors;

const io = std.testing.io;

//
// The state shared by one test (TypeScript: the describe block variables set in beforeEach).
//
const Fixture = struct {
    // Allocates everything the test creates.
    allocator: std.mem.Allocator,

    // The storage holding the collection and index files.
    storage: *MemoryStorage,

    // Generates record ids for helpers.
    uuidGenerator: *utils.test_uuid_generator.TestUuidGenerator,

    //
    // Creates the storage and generators of a test.
    //
    fn init(allocator: std.mem.Allocator) !Fixture {
        const storage = try allocator.create(MemoryStorage);
        storage.* = MemoryStorage.init(allocator);
        const uuidGenerator = try allocator.create(utils.test_uuid_generator.TestUuidGenerator);
        uuidGenerator.* = .{};
        return .{ .allocator = allocator, .storage = storage, .uuidGenerator = uuidGenerator };
    }

    //
    // Creates a collection holding the given records (TypeScript: `new MockCollection(records)`).
    //
    fn collection(self: *Fixture, name: []const u8, records: []const IInternalRecord) !*BsonCollection {
        const newCollection = try self.allocator.create(BsonCollection);
        newCollection.* = BsonCollection.init(self.allocator, name, "db", self.storage.asStorage(), "db", self.uuidGenerator.uuidGenerator(), helpers.timestamp_provider.timestampProvider(), .{ .context = self.storage, .function = ignoreDirty });
        for (records) |record| {
            try newCollection.setInternalRecord(io, record);
        }
        return newCollection;
    }

    //
    // Creates a sort index (TypeScript: `new SortIndex(storage, 'db', collectionName, fieldName, direction, ...)`).
    //
    fn sortIndex(self: *Fixture, collectionName: []const u8, fieldName: []const u8, direction: SortDirection, sortDataType: ?SortDataType, onDirty: ?DirtyCallback) !*SortIndex {
        const index = try self.allocator.create(SortIndex);
        index.* = try SortIndex.init(self.allocator, self.storage.asStorage(), "db", collectionName, fieldName, direction, self.uuidGenerator.uuidGenerator(), sortDataType, onDirty);
        return index;
    }
};

//
// An onDirty callback that does nothing (TypeScript: `() => {}`).
//
fn ignoreDirty(context: *anyopaque) void {
    _ = context;
}

//
// Counts onDirty notifications.
//
var dirty_count: u32 = 0;

//
// An onDirty callback that counts notifications (TypeScript: `() => { callCount++; }`).
//
fn countDirty(context: *anyopaque) void {
    _ = context;
    dirty_count += 1;
}

//
// The number of shards the test record ids are spread over. The collection stands in for the TypeScript
// MockCollection, which holds its records in memory, so every record must stay in the collection's shard cache:
// it keeps at most 8 shards and drops a newly created shard straight away when the other 8 are dirty.
//
const RECORD_SHARD_COUNT = 8;

//
// The candidate id with a number (valid 16 byte ids, like the TypeScript tests' ids).
//
fn candidateRecordId(allocator: std.mem.Allocator, candidate: u32) ![]const u8 {
    return std.fmt.allocPrint(allocator, "123e4567-e89b-12d3-a456-4266141{d:0>5}", .{candidate});
}

//
// Returns the shard number of a candidate id (the same hash as BsonCollection.getShardId).
//
fn candidateShard(candidate: u32) !u32 {
    var textBuffer: [64]u8 = undefined;
    const idText = try std.fmt.bufPrint(&textBuffer, "123e4567e89b12d3a4564266141{d:0>5}", .{candidate});
    var idBytes: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&idBytes, idText);
    var hash: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(&idBytes, &hash, .{});
    return std.mem.readInt(u32, hash[0..4], .big) % 100;
}

//
// The candidate numbers of the ids handed out so far, in order.
//
var record_id_candidates: [4096]u32 = undefined;

//
// How many entries of record_id_candidates are filled.
//
var record_id_candidate_count: u32 = 0;

//
// Builds a record id from a small number: the number-th candidate id whose shard is below RECORD_SHARD_COUNT.
//
fn recordId(allocator: std.mem.Allocator, number: u32) ![]const u8 {
    while (record_id_candidate_count <= number) {
        var candidate: u32 = if (record_id_candidate_count == 0) 0 else record_id_candidates[record_id_candidate_count - 1] + 1;
        while (try candidateShard(candidate) >= RECORD_SHARD_COUNT) {
            candidate += 1;
        }
        record_id_candidates[record_id_candidate_count] = candidate;
        record_id_candidate_count += 1;
    }
    return candidateRecordId(allocator, record_id_candidates[number]);
}

//
// Builds a TestRecord { name, score, category } in internal form.
//
fn makeTestRecord(allocator: std.mem.Allocator, number: u32, name: []const u8, score: ?f64, category: []const u8) !IInternalRecord {
    var fields: BsonDocument = .empty;
    try fields.put(allocator, "name", .{ .string = name });
    if (score) |scoreValue| {
        try fields.put(allocator, "score", .{ .number = scoreValue });
    }
    try fields.put(allocator, "category", .{ .string = category });
    return .{ ._id = try recordId(allocator, number), .fields = fields, .metadata = .empty };
}

//
// Builds a record with one field.
//
fn makeValueRecord(allocator: std.mem.Allocator, number: u32, key: []const u8, value: BsonValue) !IInternalRecord {
    return .{
        ._id = try recordId(allocator, number),
        .fields = try BsonDocument.fromFields(allocator, &.{.{ .key = key, .value = value }}),
        .metadata = .empty,
    };
}

//
// The records of the TypeScript sort-index tests.
//
fn testRecords(allocator: std.mem.Allocator) ![5]IInternalRecord {
    return .{
        try makeTestRecord(allocator, 1, "Record 1", 85, "A"),
        try makeTestRecord(allocator, 2, "Record 2", 72, "B"),
        try makeTestRecord(allocator, 3, "Record 3", 90, "A"),
        try makeTestRecord(allocator, 4, "Record 4", 65, "C"),
        try makeTestRecord(allocator, 5, "Record 5", 85, "B"),
    };
}

//
// Returns the scores of a sort index in page order.
//
fn scores(allocator: std.mem.Allocator, index: *SortIndex, fieldName: []const u8) ![]f64 {
    _ = fieldName;
    const values = try helpers.sortIndexValues(allocator, io, index);
    const result = try allocator.alloc(f64, values.len);
    for (values, 0..) |value, valueIndex| {
        result[valueIndex] = value.number;
    }
    return result;
}

test "should initialize the sort index with records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator());
    const collection = try fixture.collection("test_collection", &try testRecords(arena.allocator()));
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try std.testing.expect(fixture.storage.getFile("db/indexes/test_collection/score_asc/tree.dat") != null);
    // The build checkpoint is deleted when the build completes.
    try std.testing.expect(fixture.storage.getFile("db/indexes/test_collection/score_asc/build.checkpoint") == null);
    try index.commit(io);
    const values = try scores(arena.allocator(), index, "score");
    try std.testing.expectEqualSlices(f64, &.{ 65, 72, 85, 85, 90 }, values);
}

test "should find records by exact value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator());
    const collection = try fixture.collection("test_collection", &try testRecords(arena.allocator()));
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);

    const result = try index.findByValue(io, .{ .number = 85 }, null);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    for (result) |record| {
        try std.testing.expectEqual(@as(f64, 85), record.get("score").?.number);
        try std.testing.expectEqualStrings("_id", record.fields.items[0].key);
    }
    const result2 = try index.findByValue(io, .{ .number = 90 }, null);
    try std.testing.expectEqual(@as(usize, 1), result2.len);
    const result3 = try index.findByValue(io, .{ .number = 100 }, null);
    try std.testing.expectEqual(@as(usize, 0), result3.len);
}

test "should update and delete records in the index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const records = try testRecords(allocator);
    const collection = try fixture.collection("test_collection", &records);
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);

    const updatedRecord = try makeTestRecord(allocator, 1, "Record 1 Updated", 95, "A");
    try index.updateRecord(io, updatedRecord, records[0]);

    const result = try index.findByValue(io, .{ .number = 95 }, null);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("Record 1 Updated", result[0].get("name").?.string);
    try std.testing.expectEqual(@as(usize, 1), (try index.findByValue(io, .{ .number = 85 }, null)).len);

    try index.deleteRecord(io, records[4]._id, records[4]);
    try std.testing.expectEqual(@as(usize, 0), (try index.findByValue(io, .{ .number = 85 }, null)).len);
}

test "should add a new record to the index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try testRecords(allocator));
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try index.addRecord(io, try makeTestRecord(allocator, 6, "Record 6", 80, "A"));
    try std.testing.expectEqualSlices(f64, &.{ 65, 72, 80, 85, 85, 90 }, try scores(allocator, index, "score"));
}

test "should return empty array when calling findByValue on non-existent index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator());
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try std.testing.expectEqual(@as(usize, 0), (try index.findByValue(io, .{ .number = 85 }, null)).len);
}

test "should no-op when calling updateRecord without loading" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator());
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    const records = try testRecords(arena.allocator());
    try index.updateRecord(io, records[0], null);
    try std.testing.expect(!index.dirty());
    try std.testing.expectEqual(@as(usize, 0), fixture.storage.files.count());
}

test "should no-op when calling deleteRecord without loading" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator());
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    const records = try testRecords(arena.allocator());
    try index.deleteRecord(io, records[0]._id, records[0]);
    try std.testing.expect(!index.dirty());
}

test "should handle empty collection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator());
    const collection = try fixture.collection("test_collection", &.{});
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try std.testing.expectEqual(@as(u32, 0), index.totalEntries);
    try std.testing.expectEqual(@as(u32, 1), index.totalPages); // Should have one empty leaf page
    // The empty root leaf is not written (it is deleted on commit), only the tree file.
    try std.testing.expectEqual(@as(usize, 1), fixture.storage.files.count());
}

test "should handle single record collection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &.{try makeTestRecord(allocator, 1, "Record 1", 85, "A")});
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try std.testing.expectEqual(@as(u32, 1), index.totalEntries);
    try std.testing.expectEqual(@as(u32, 1), index.totalPages);
    try std.testing.expectEqualSlices(f64, &.{85}, try scores(allocator, index, "score"));
}

test "should handle collection with all same values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &.{
        try makeTestRecord(allocator, 1, "Record 1", 100, "A"),
        try makeTestRecord(allocator, 2, "Record 2", 100, "B"),
        try makeTestRecord(allocator, 3, "Record 3", 100, "C"),
        try makeTestRecord(allocator, 4, "Record 4", 100, "D"),
    });
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try std.testing.expectEqual(@as(usize, 4), (try index.findByValue(io, .{ .number = 100 }, null)).len);
    try std.testing.expectEqual(@as(usize, 4), (try helpers.walkSortIndex(allocator, io, index)).len);
}

test "should handle records with undefined indexed field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &.{
        try makeTestRecord(allocator, 1, "Record 1", 85, "A"),
        try makeTestRecord(allocator, 2, "Record 2", null, "B"), // No score
        try makeTestRecord(allocator, 3, "Record 3", 90, "C"),
    });
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try std.testing.expectEqual(@as(u32, 2), index.totalEntries);
    try std.testing.expectEqualSlices(f64, &.{ 85, 90 }, try scores(allocator, index, "score"));
}

test "should load index from disk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try testRecords(allocator));
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);

    const loadedIndex = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try std.testing.expect(try loadedIndex.load(io));
    try std.testing.expectEqual(@as(u32, 5), loadedIndex.totalEntries);
    // build() was called without a type, so the tree file stores no type.
    try std.testing.expect(loadedIndex.type == null);
    try std.testing.expectEqualSlices(f64, &.{ 65, 72, 85, 85, 90 }, try scores(allocator, loadedIndex, "score"));
}

test "should return false when loading non-existent index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator());
    const index = try fixture.sortIndex("nonexistent", "score", .asc, null, null);
    try std.testing.expect(!try index.load(io));
}

test "should not rebuild if already loaded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try testRecords(allocator));
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    const rootPageId = index.rootPageId.?;
    try index.build(io, collection);
    try std.testing.expectEqualStrings(rootPageId, index.rootPageId.?);
    try std.testing.expectEqual(@as(u32, 5), index.totalEntries);
}

test "addRecord then commit persists the record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const records = try testRecords(allocator);
    const collection = try fixture.collection("test_collection", records[0..3]);
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try index.addRecord(io, try makeTestRecord(allocator, 6, "Record 6", 80, "A"));
    try index.commit(io);

    // A fresh index reads the committed record from storage.
    const reloaded = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    const found = try reloaded.findByValue(io, .{ .number = 80 }, null);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("Record 6", found[0].get("name").?.string);
}

test "updateRecord then commit persists update" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const records = try testRecords(allocator);
    const collection = try fixture.collection("test_collection", records[0..3]);
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try index.updateRecord(io, try makeTestRecord(allocator, 1, "Record 1 Updated", 50, "A"), records[0]);
    try index.commit(io);

    const reloaded = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    const at50 = try reloaded.findByValue(io, .{ .number = 50 }, null);
    try std.testing.expectEqual(@as(usize, 1), at50.len);
    try std.testing.expectEqualStrings("Record 1 Updated", at50[0].get("name").?.string);
    try std.testing.expectEqual(@as(usize, 0), (try reloaded.findByValue(io, .{ .number = 85 }, null)).len);
}

test "deleteRecord then commit persists delete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const records = try testRecords(allocator);
    const collection = try fixture.collection("test_collection", records[0..3]);
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try index.deleteRecord(io, records[1]._id, records[1]);
    try index.commit(io);

    const reloaded = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    _ = try reloaded.load(io);
    const ids = try helpers.walkSortIndex(allocator, io, reloaded);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    for (ids) |id| {
        try std.testing.expect(!std.mem.eql(u8, id, records[1]._id));
    }
}

test "mix of add, update, delete then commit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const records = try testRecords(allocator);
    const collection = try fixture.collection("test_collection", records[0..3]);
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try index.addRecord(io, try makeTestRecord(allocator, 20, "New", 88, "A"));
    try index.updateRecord(io, try makeTestRecord(allocator, 1, "Record 1", 70, "A"), records[0]);
    try index.deleteRecord(io, records[2]._id, records[2]);
    try index.commit(io);
    try std.testing.expectEqualSlices(f64, &.{ 70, 72, 88 }, try scores(allocator, index, "score"));
    try std.testing.expectEqual(@as(usize, 0), (try index.findByValue(io, .{ .number = 90 }, null)).len);
}

test "commit when idle is no-op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const records = try testRecords(allocator);
    const collection = try fixture.collection("test_collection", records[0..3]);
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try index.commit(io);
}

test "commit throws when the index was never built" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator());
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try std.testing.expectError(error.Thrown, index.commit(io));
    try std.testing.expectEqualStrings("Root page ID is not set. Cannot save tree.", errors.lastErrorMessage());
}

test "multiple commit cycles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const records = try testRecords(allocator);
    const collection = try fixture.collection("test_collection", records[0..3]);
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try index.addRecord(io, try makeTestRecord(allocator, 30, "A", 1, "X"));
    try index.commit(io);
    try index.addRecord(io, try makeTestRecord(allocator, 31, "B", 2, "X"));
    try index.commit(io);
    try std.testing.expectEqual(@as(usize, 1), (try index.findByValue(io, .{ .number = 1 }, null)).len);
    try std.testing.expectEqual(@as(usize, 1), (try index.findByValue(io, .{ .number = 2 }, null)).len);
    try std.testing.expectEqual(@as(usize, 5), (try helpers.walkSortIndex(allocator, io, index)).len);
}

test "hasDirtyData() returns false on a fresh index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const records = try testRecords(allocator);
    const collection = try fixture.collection("test_collection", records[0..3]);
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try std.testing.expect(!index.dirty());
}

test "hasDirtyData() returns true after addRecord" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const records = try testRecords(allocator);
    const collection = try fixture.collection("test_collection", records[0..3]);
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try index.addRecord(io, try makeTestRecord(allocator, 99, "New", 55, "Z"));
    try std.testing.expect(index.dirty());
}

test "hasDirtyData() returns false after commit()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const records = try testRecords(allocator);
    const collection = try fixture.collection("test_collection", records[0..3]);
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try index.addRecord(io, try makeTestRecord(allocator, 99, "New", 55, "Z"));
    try index.commit(io);
    try std.testing.expect(!index.dirty());
}

test "onDirty callback fires on first dirty transition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const records = try testRecords(allocator);
    const collection = try fixture.collection("test_collection", records[0..3]);
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, .{ .context = fixture.storage, .function = countDirty });
    try index.build(io, collection);
    dirty_count = 0; // reset: build calls commit internally
    try index.addRecord(io, try makeTestRecord(allocator, 99, "New", 55, "Z"));
    try std.testing.expectEqual(@as(u32, 1), dirty_count);
}

test "onDirty callback does not fire again until commit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const records = try testRecords(allocator);
    const collection = try fixture.collection("test_collection", records[0..3]);
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, .{ .context = fixture.storage, .function = countDirty });
    try index.build(io, collection);
    dirty_count = 0;
    try index.addRecord(io, try makeTestRecord(allocator, 99, "New", 55, "Z"));
    try index.addRecord(io, try makeTestRecord(allocator, 98, "New2", 56, "Z"));
    try std.testing.expectEqual(@as(u32, 1), dirty_count);
}

test "onDirty callback fires again after commit then addRecord" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const records = try testRecords(allocator);
    const collection = try fixture.collection("test_collection", records[0..3]);
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, .{ .context = fixture.storage, .function = countDirty });
    try index.build(io, collection);
    try index.addRecord(io, try makeTestRecord(allocator, 99, "New", 55, "Z"));
    try index.commit(io);
    dirty_count = 0;
    try index.addRecord(io, try makeTestRecord(allocator, 98, "New2", 56, "Z"));
    try std.testing.expectEqual(@as(u32, 1), dirty_count);
}

test "should infer string type when no type is specified" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("fruits", &.{
        try makeValueRecord(allocator, 1, "name", .{ .string = "Cherry" }),
        try makeValueRecord(allocator, 2, "name", .{ .string = "Apple" }),
        try makeValueRecord(allocator, 3, "name", .{ .string = "Banana" }),
    });
    const index = try fixture.sortIndex("fruits", "name", .asc, null, null);
    try index.build(io, collection);
    const values = try helpers.sortIndexValues(allocator, io, index);
    try std.testing.expectEqualStrings("Apple", values[0].string);
    try std.testing.expectEqualStrings("Banana", values[1].string);
    try std.testing.expectEqualStrings("Cherry", values[2].string);
}

test "should infer number type when no type is specified" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("scores", &.{
        try makeValueRecord(allocator, 1, "score", .{ .number = 30 }),
        try makeValueRecord(allocator, 2, "score", .{ .number = 5 }),
        try makeValueRecord(allocator, 3, "score", .{ .number = 100 }),
    });
    const index = try fixture.sortIndex("scores", "score", .asc, null, null);
    try index.build(io, collection);
    try std.testing.expectEqualSlices(f64, &.{ 5, 30, 100 }, try scores(allocator, index, "score"));
}

test "should infer date type when no type is specified" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const date1: i64 = 1704067200000; // 2024-01-01
    const date2: i64 = 1718409600000; // 2024-06-15
    const date3: i64 = 1710028800000; // 2024-03-10
    const collection = try fixture.collection("events", &.{
        try makeValueRecord(allocator, 1, "eventDate", .{ .date = date1 }),
        try makeValueRecord(allocator, 2, "eventDate", .{ .date = date2 }),
        try makeValueRecord(allocator, 3, "eventDate", .{ .date = date3 }),
    });
    const index = try fixture.sortIndex("events", "eventDate", .asc, null, null);
    try index.build(io, collection);
    const values = try helpers.sortIndexValues(allocator, io, index);
    try std.testing.expectEqual(date1, values[0].date);
    try std.testing.expectEqual(date3, values[1].date);
    try std.testing.expectEqual(date2, values[2].date);
}

test "should throw error when comparing incompatible types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("mixed", &.{
        try makeValueRecord(allocator, 1, "value", .{ .string = "string" }),
        try makeValueRecord(allocator, 2, "value", .{ .number = 123 }),
    });
    const index = try fixture.sortIndex("mixed", "value", .asc, null, null);
    try std.testing.expectError(error.Thrown, index.build(io, collection));
    const message = errors.lastErrorMessage();
    try std.testing.expect(std.mem.startsWith(u8, message, "Type mismatch in compareValues: first value is "));
}

test "should work correctly when all values are the same inferred type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("consistent", &.{
        try makeValueRecord(allocator, 1, "value", .{ .string = "first" }),
        try makeValueRecord(allocator, 2, "value", .{ .string = "second" }),
        try makeValueRecord(allocator, 3, "value", .{ .string = "third" }),
    });
    const index = try fixture.sortIndex("consistent", "value", .asc, null, null);
    try index.build(io, collection);
    const values = try helpers.sortIndexValues(allocator, io, index);
    try std.testing.expectEqualStrings("first", values[0].string);
    try std.testing.expectEqualStrings("second", values[1].string);
    try std.testing.expectEqualStrings("third", values[2].string);
}

test "should handle large dataset with multiple pages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    var records: std.ArrayList(IInternalRecord) = .empty;
    var number: u32 = 0;
    while (number < 1700) : (number += 1) {
        try records.append(allocator, try makeTestRecord(allocator, number, "Record", @floatFromInt(number), if (number % 2 == 0) "A" else "B"));
    }
    const collection = try fixture.collection("test_collection", records.items);
    const index = try fixture.sortIndex("test_collection", "score", .asc, .number, null);
    try index.build(io, collection);

    // More than 1500 records in one leaf split it into two pages under a new root.
    try std.testing.expectEqual(@as(u32, 2), index.totalPages);
    try std.testing.expectEqual(@as(u32, 1700), index.totalEntries);
    const values = try scores(allocator, index, "score");
    try std.testing.expectEqual(@as(usize, 1700), values.len);
    for (values, 0..) |value, valueIndex| {
        try std.testing.expectEqual(@as(f64, @floatFromInt(valueIndex)), value);
    }
}

test "should handle records with duplicate values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &.{
        try makeTestRecord(allocator, 1, "Record 1", 10, "A"),
        try makeTestRecord(allocator, 2, "Record 2", 10, "B"),
        try makeTestRecord(allocator, 3, "Record 3", 10, "C"),
        try makeTestRecord(allocator, 4, "Record 4", 20, "A"),
    });
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try std.testing.expectEqualSlices(f64, &.{ 10, 10, 10, 20 }, try scores(allocator, index, "score"));
}

test "should handle descending sort" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    var records: std.ArrayList(IInternalRecord) = .empty;
    var number: u32 = 0;
    while (number < 20) : (number += 1) {
        try records.append(allocator, try makeTestRecord(allocator, number, "Record", @floatFromInt(number * 10), "A"));
    }
    const collection = try fixture.collection("test_collection", records.items);
    const index = try fixture.sortIndex("test_collection", "score", .desc, null, null);
    try index.build(io, collection);
    const values = try scores(allocator, index, "score");
    try std.testing.expectEqual(@as(f64, 190), values[0]); // Highest score first
    try std.testing.expectEqual(@as(f64, 0), values[values.len - 1]);
}

test "should handle date type sorting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    // ISO strings in a 'date' index are compared as dates; a Date value compares with them too.
    const collection = try fixture.collection("test_collection", &.{
        try makeValueRecord(allocator, 1, "createdAt", .{ .string = "2024-01-03T00:00:00.000Z" }),
        try makeValueRecord(allocator, 2, "createdAt", .{ .string = "2024-01-01T00:00:00.000Z" }),
        try makeValueRecord(allocator, 3, "createdAt", .{ .date = 1704153600000 }), // 2024-01-02
    });
    const index = try fixture.sortIndex("test_collection", "createdAt", .asc, .date, null);
    try index.build(io, collection);
    const values = try helpers.sortIndexValues(allocator, io, index);
    try std.testing.expectEqualStrings("2024-01-01T00:00:00.000Z", values[0].string);
    try std.testing.expectEqual(@as(i64, 1704153600000), values[1].date);
    try std.testing.expectEqualStrings("2024-01-03T00:00:00.000Z", values[2].string);
}

test "should handle mixed case string comparisons correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("strings", &.{
        try makeValueRecord(allocator, 1, "name", .{ .string = "banana" }),
        try makeValueRecord(allocator, 2, "name", .{ .string = "Apple" }),
        try makeValueRecord(allocator, 3, "name", .{ .string = "apple" }),
        try makeValueRecord(allocator, 4, "name", .{ .string = "Banana" }),
    });
    const index = try fixture.sortIndex("strings", "name", .asc, .string, null);
    try index.build(io, collection);
    const values = try helpers.sortIndexValues(allocator, io, index);
    // localeCompare: case-insensitive first, then lowercase before uppercase.
    try std.testing.expectEqualStrings("apple", values[0].string);
    try std.testing.expectEqualStrings("Apple", values[1].string);
    try std.testing.expectEqualStrings("banana", values[2].string);
    try std.testing.expectEqualStrings("Banana", values[3].string);
}

test "should handle numeric strings as strings, not numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("strings", &.{
        try makeValueRecord(allocator, 1, "code", .{ .string = "10" }),
        try makeValueRecord(allocator, 2, "code", .{ .string = "9" }),
        try makeValueRecord(allocator, 3, "code", .{ .string = "100" }),
    });
    const index = try fixture.sortIndex("strings", "code", .asc, .string, null);
    try index.build(io, collection);
    const values = try helpers.sortIndexValues(allocator, io, index);
    try std.testing.expectEqualStrings("10", values[0].string);
    try std.testing.expectEqualStrings("100", values[1].string);
    try std.testing.expectEqualStrings("9", values[2].string);
}

test "should handle string numbers correctly when type is number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("numbers", &.{
        try makeValueRecord(allocator, 1, "value", .{ .string = "10" }),
        try makeValueRecord(allocator, 2, "value", .{ .number = 9 }),
        try makeValueRecord(allocator, 3, "value", .{ .string = "100" }),
    });
    const index = try fixture.sortIndex("numbers", "value", .asc, .number, null);
    try index.build(io, collection);
    const values = try helpers.sortIndexValues(allocator, io, index);
    try std.testing.expectEqual(@as(f64, 9), values[0].number);
    try std.testing.expectEqualStrings("10", values[1].string);
    try std.testing.expectEqualStrings("100", values[2].string);
}

test "should handle NaN values correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("numbers", &.{
        try makeValueRecord(allocator, 1, "value", .{ .number = 5 }),
        try makeValueRecord(allocator, 2, "value", .{ .string = "not a number" }),
        try makeValueRecord(allocator, 3, "value", .{ .number = 1 }),
    });
    const index = try fixture.sortIndex("numbers", "value", .asc, .number, null);
    try index.build(io, collection);
    const values = try helpers.sortIndexValues(allocator, io, index);
    // NaN sorts before every number.
    try std.testing.expectEqualStrings("not a number", values[0].string);
    try std.testing.expectEqual(@as(f64, 1), values[1].number);
    try std.testing.expectEqual(@as(f64, 5), values[2].number);
}

test "should handle zero and negative numbers correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("numbers", &.{
        try makeValueRecord(allocator, 1, "value", .{ .number = 0 }),
        try makeValueRecord(allocator, 2, "value", .{ .number = -5.5 }),
        try makeValueRecord(allocator, 3, "value", .{ .number = 3 }),
    });
    const index = try fixture.sortIndex("numbers", "value", .desc, .number, null);
    try index.build(io, collection);
    try std.testing.expectEqualSlices(f64, &.{ 3, 0, -5.5 }, try scores(allocator, index, "value"));
}

test "build resumes from a checkpoint and skips completed shards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try testRecords(allocator));

    // Build once so the index exists, then leave a checkpoint that marks the first non-empty shard as done.
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try std.testing.expectEqual(@as(u32, 5), index.totalEntries);
    try fixture.storage.putFile("db/indexes/test_collection/score_asc/build.checkpoint", "{\"completedShards\":[0],\"currentShard\":null,\"currentShardRecordIndex\":0,\"totalRecordsProcessed\":0,\"lastUpdated\":0}");

    // A new index loads the existing tree and adds the records of the shards that are not completed.
    const resumed = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try resumed.build(io, collection);
    var shards = collection.iterateShards();
    const firstShard = (try shards.next(io)).?;
    try std.testing.expectEqual(@as(u32, @intCast(10 - firstShard.len)), resumed.totalEntries);
    try std.testing.expect(fixture.storage.getFile("db/indexes/test_collection/score_asc/build.checkpoint") == null);
}

test "build deletes a stale checkpoint when the index does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try testRecords(allocator));
    try fixture.storage.putFile("db/indexes/test_collection/score_asc/build.checkpoint", "{\"completedShards\":[0,1,2,3,4,5],\"currentShard\":null,\"currentShardRecordIndex\":0,\"totalRecordsProcessed\":0,\"lastUpdated\":0}");
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try std.testing.expectEqual(@as(u32, 5), index.totalEntries);
    try std.testing.expect(fixture.storage.getFile("db/indexes/test_collection/score_asc/build.checkpoint") == null);
}

test "ensure builds a missing index once and loads an existing one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try testRecords(allocator));
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.ensure(io, collection, .number);
    try std.testing.expectEqual(SortDataType.number, index.type.?);
    try std.testing.expectEqual(@as(u32, 5), index.totalEntries);

    const loaded = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try loaded.ensure(io, collection, .string);
    // The type stored in the tree file wins over the type passed to ensure.
    try std.testing.expectEqual(SortDataType.number, loaded.type.?);
    try std.testing.expectEqualStrings(index.rootPageId.?, loaded.rootPageId.?);
}
