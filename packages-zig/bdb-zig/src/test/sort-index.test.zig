const std = @import("std");
const bdb = @import("bdb-zig");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const helpers = @import("test-helpers.zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const bson = serialization_zig.bson;
const js_date = serialization_zig.js_date;
const BsonValue = bson.BsonValue;
const BsonDocument = bson.BsonDocument;
const BsonCollection = bdb.collection.BsonCollection;
const IInternalRecord = bdb.shard.IInternalRecord;
const SortIndex = bdb.sort_index.SortIndex;
const ISortIndexRecord = bdb.sort_index.ISortIndexRecord;
const localeCompare = bdb.locale_compare.localeCompare;
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
        index.* = try SortIndex.init(self.allocator, self.storage.asStorage(), "db", collectionName, fieldName, direction, self.uuidGenerator.uuidGenerator(), sortDataType, onDirty, null);
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

//
// Returns every record of a sort index by following the page chain from the first page (TypeScript: getAllRecords
// in batch-sort-index.test.ts, and the same loop written out in the other sort index tests).
//
fn getAllRecords(allocator: std.mem.Allocator, index: *SortIndex) ![]ISortIndexRecord {
    var allRecords: std.ArrayList(ISortIndexRecord) = .empty;
    var currentPage = try index.getPage(io, "");
    try allRecords.appendSlice(allocator, currentPage.records);
    while (currentPage.nextPageId) |nextPageId| {
        currentPage = try index.getPage(io, nextPageId);
        try allRecords.appendSlice(allocator, currentPage.records);
    }
    return allRecords.items;
}

//
// Returns the index of the record with an id, or null when there is none (TypeScript: `findIndex(r => r._id === id)`).
//
fn findRecordIndexById(records: []const ISortIndexRecord, id: []const u8) ?usize {
    for (records, 0..) |record, recordIndex| {
        if (std.mem.eql(u8, record.get("_id").?.string, id)) {
            return recordIndex;
        }
    }
    return null;
}

//
// Builds a record with the given fields in internal form.
//
fn makeFieldsRecord(allocator: std.mem.Allocator, number: u32, fields: []const bson.BsonField) !IInternalRecord {
    return .{
        ._id = try recordId(allocator, number),
        .fields = try BsonDocument.fromFields(allocator, fields),
        .metadata = .empty,
    };
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

test "should retrieve a page of sorted records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try testRecords(allocator));
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);

    // Initialize the index
    try index.build(io, collection);

    // Get the first page (using empty string to get first page)
    const result = try index.getPage(io, "");

    // Check page contents
    try std.testing.expectEqual(@as(usize, 5), result.records.len);
    try std.testing.expectEqual(@as(i64, 5), result.totalRecords);
    try std.testing.expect(result.currentPageId.len > 0);
    try std.testing.expectEqual(@as(i64, 1), result.totalPages);
    try std.testing.expect(result.nextPageId == null);
    try std.testing.expect(result.previousPageId == null);

    // Check records are sorted by score (ascending)
    if (result.records.len > 0) {
        // The first page should have the lowest score
        try std.testing.expectEqual(@as(f64, 65), result.records[0].get("score").?.number); // Record 4
        if (result.records.len > 1) {
            try std.testing.expectEqual(@as(f64, 72), result.records[1].get("score").?.number); // Record 2
        }
    }

    // Follow the chain of pages to get all records
    var allRecords: std.ArrayList(ISortIndexRecord) = .empty;
    try allRecords.appendSlice(allocator, result.records);
    var nextPageId = result.nextPageId;

    while (nextPageId) |pageId| {
        const nextPage = try index.getPage(io, pageId);
        try allRecords.appendSlice(allocator, nextPage.records);
        nextPageId = nextPage.nextPageId;
    }

    // Should have all 5 records after traversing all pages
    try std.testing.expectEqual(@as(usize, 5), allRecords.items.len);

    // Verify they are in the correct sorted order
    var allScores: [5]f64 = undefined;
    for (allRecords.items, 0..) |record, recordIndex| {
        allScores[recordIndex] = record.get("score").?.number;
    }
    try std.testing.expectEqualSlices(f64, &.{ 65, 72, 85, 85, 90 }, &allScores);
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

test "should delete the entire index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try testRecords(allocator));
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);

    // Initialize the index
    try index.build(io, collection);

    // Delete the index
    _ = try index.drop(io);

    // Check that the index directory no longer exists
    const exists = try fixture.storage.dirExists(allocator, io, "db/indexes/test_collection/score_asc");
    try std.testing.expect(!exists);
}

test "should return empty result when calling getPage on non-existent index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var fixture = try Fixture.init(arena.allocator());
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    const result = try index.getPage(io, null);
    try std.testing.expectEqual(@as(usize, 0), result.records.len);
    try std.testing.expectEqual(@as(i64, 0), result.totalRecords);
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
    try std.testing.expectEqual(@as(i64, 0), index.totalEntries);
    try std.testing.expectEqual(@as(i64, 1), index.totalPages); // Should have one empty leaf page
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
    try std.testing.expectEqual(@as(i64, 1), index.totalEntries);
    try std.testing.expectEqual(@as(i64, 1), index.totalPages);
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
    try std.testing.expectEqual(@as(i64, 2), index.totalEntries);
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
    try std.testing.expectEqual(@as(i64, 5), loadedIndex.totalEntries);
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

test "should clear treeNodes when building after load" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try testRecords(allocator));
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);

    // Build the index first
    try index.build(io, collection);

    // Verify it has data
    const firstResult = try index.getPage(io, null);
    try std.testing.expectEqual(@as(i64, 5), firstResult.totalRecords);

    // Create a new collection with different data
    // (Zig: the ids are valid record ids, because the collection stores the records in its shards.)
    const newCollection = try fixture.collection("test_collection", &.{
        try makeTestRecord(allocator, 6, "New 1", 10, "A"),
        try makeTestRecord(allocator, 7, "New 2", 20, "B"),
    });

    // Delete the index first to allow rebuild
    _ = try index.drop(io);

    // Build again with new data - this should clear treeNodes
    try index.build(io, newCollection);

    // Verify we have the new data, not the old
    const secondResult = try index.getPage(io, null);
    try std.testing.expectEqual(@as(i64, 2), secondResult.totalRecords);
    try std.testing.expectEqual(@as(f64, 10), secondResult.records[0].get("score").?.number);
    try std.testing.expectEqual(@as(f64, 20), secondResult.records[1].get("score").?.number);
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
    try std.testing.expectEqual(@as(i64, 5), index.totalEntries);
}

test "should reset state properly when building" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try testRecords(allocator));
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);

    // Build with initial data
    try index.build(io, collection);

    const firstResult = try index.getPage(io, null);
    const firstRootPageId = firstResult.currentPageId;

    // Delete and rebuild with different data
    _ = try index.drop(io);

    // (Zig: the id is a valid record id, because the collection stores the record in its shards.)
    const newCollection = try fixture.collection("test_collection", &.{
        try makeTestRecord(allocator, 6, "New 1", 10, "A"),
    });
    try index.build(io, newCollection);

    // Verify state was reset
    const secondResult = try index.getPage(io, null);
    try std.testing.expectEqual(@as(i64, 1), secondResult.totalRecords); // New count
    try std.testing.expectEqual(@as(i64, 1), secondResult.totalPages); // New page count
    try std.testing.expect(!std.mem.eql(u8, firstRootPageId, secondResult.currentPageId)); // New root
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

test "should handle collection with records missing the indexed field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &.{
        try makeTestRecord(allocator, 1, "Record 1", 10, "A"),
        try makeTestRecord(allocator, 2, "Record 2", null, "B"), // Missing score
        try makeTestRecord(allocator, 3, "Record 3", 30, "A"),
    });
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);

    try index.build(io, collection);

    // Should only index records with the score field
    const result = try index.getPage(io, null);
    try std.testing.expectEqual(@as(i64, 2), result.totalRecords); // Only 2 records have scores
    try std.testing.expectEqual(@as(usize, 2), result.records.len);
    try std.testing.expectEqual(@as(f64, 10), result.records[0].get("score").?.number);
    try std.testing.expectEqual(@as(f64, 30), result.records[1].get("score").?.number);
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
    try std.testing.expectEqual(@as(i64, 2), index.totalPages);
    try std.testing.expectEqual(@as(i64, 1700), index.totalEntries);
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

test "should handle string type sorting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &.{
        try makeTestRecord(allocator, 1, "Zebra", 10, "A"),
        try makeTestRecord(allocator, 2, "Apple", 20, "B"),
        try makeTestRecord(allocator, 3, "Banana", 30, "C"),
    });
    const index = try fixture.sortIndex("test_collection", "name", .asc, null, null);

    try index.build(io, collection);

    const result = try index.getPage(io, null);
    try std.testing.expectEqual(@as(i64, 3), result.totalRecords);
    try std.testing.expectEqualStrings("Apple", result.records[0].get("name").?.string);
    try std.testing.expectEqualStrings("Banana", result.records[1].get("name").?.string);
    try std.testing.expectEqualStrings("Zebra", result.records[2].get("name").?.string);
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

// Not ported: "should return early on subsequent build calls when already loaded" (it passes a progress callback to
// build, which is not ported).

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
    try std.testing.expectEqual(@as(i64, 5), index.totalEntries);
    try fixture.storage.putFile("db/indexes/test_collection/score_asc/build.checkpoint", "{\"completedShards\":[0],\"currentShard\":null,\"currentShardRecordIndex\":0,\"totalRecordsProcessed\":0,\"lastUpdated\":0}");

    // A new index loads the existing tree and adds the records of the shards that are not completed.
    const resumed = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try resumed.build(io, collection);
    var shards = collection.iterateShards();
    const firstShard = (try shards.next(io)).?;
    try std.testing.expectEqual(@as(i64, @intCast(10 - firstShard.len)), resumed.totalEntries);
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
    try std.testing.expectEqual(@as(i64, 5), index.totalEntries);
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
    try std.testing.expectEqual(@as(i64, 5), index.totalEntries);

    const loaded = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try loaded.ensure(io, collection, .string);
    // The type stored in the tree file wins over the type passed to ensure.
    try std.testing.expectEqual(SortDataType.number, loaded.type.?);
    try std.testing.expectEqualStrings(index.rootPageId.?, loaded.rootPageId.?);
}

test "commit() keeps leafCache populated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const records = try testRecords(allocator);
    const collection = try fixture.collection("test_collection", records[0..3]);
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    // After build+commit, leafCache should be populated so getPage works without re-reading disk
    const page = try index.getPage(io, null);
    try std.testing.expect(page.records.len > 0);
}

test "flush() clears leafCache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const records = try testRecords(allocator);
    const collection = try fixture.collection("test_collection", records[0..3]);
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try index.flush();
    try std.testing.expectEqual(@as(usize, 0), index.leafCache.count());

    // After flush, should still be able to getPage (loads from disk)
    _ = try index.load(io);
    const page = try index.getPage(io, null);
    try std.testing.expect(page.records.len > 0);
}

test "flush() throws when dirtyLeaves is not empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const records = try testRecords(allocator);
    const collection = try fixture.collection("test_collection", records[0..3]);
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try index.addRecord(io, try makeTestRecord(allocator, 99, "New", 55, "Z"));

    try std.testing.expectError(error.Thrown, index.flush());
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "can't flush") != null);
}

test "flush() throws when deletedLeaves is not empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const records = try testRecords(allocator);
    const collection = try fixture.collection("test_collection", records[0..3]);
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try index.deleteRecord(io, records[0]._id, records[0]);

    try std.testing.expectError(error.Thrown, index.flush());
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "can't flush") != null);
}

//
// The fixed time the date tests count back from (TypeScript: `const now = new Date()`): 2024-06-15T12:00:00.000Z.
//
const DATE_TEST_NOW: i64 = 1718452800000;

//
// The length of a day in milliseconds (TypeScript: `24 * 60 * 60 * 1000`).
//
const DAY_MILLISECONDS: i64 = 24 * 60 * 60 * 1000;

//
// Formats a time like `new Date(time).toISOString()`.
//
fn isoString(allocator: std.mem.Allocator, time: i64) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    try js_date.writeIsoString(&output.writer, time);
    return output.written();
}

//
// Builds a date test record { name, createdAt, updatedAt, category } in internal form.
//
fn makeDateRecord(allocator: std.mem.Allocator, number: u32, name: []const u8, createdAt: []const u8, updatedAt: []const u8, category: []const u8) !IInternalRecord {
    return makeFieldsRecord(allocator, number, &.{
        .{
            .key = "name",
            .value = .{ .string = name },
        },
        .{
            .key = "createdAt",
            .value = .{ .string = createdAt },
        },
        .{
            .key = "updatedAt",
            .value = .{ .string = updatedAt },
        },
        .{
            .key = "category",
            .value = .{ .string = category },
        },
    });
}

//
// The records of the TypeScript sort-index-date tests.
//
fn dateTestRecords(allocator: std.mem.Allocator) ![5]IInternalRecord {
    return .{
        try makeDateRecord(allocator, 1, "Record 1", try isoString(allocator, DATE_TEST_NOW - 4 * DAY_MILLISECONDS), try isoString(allocator, DATE_TEST_NOW - 1 * DAY_MILLISECONDS), "A"), // created 4 days ago, updated 1 day ago
        try makeDateRecord(allocator, 2, "Record 2", try isoString(allocator, DATE_TEST_NOW - 2 * DAY_MILLISECONDS), try isoString(allocator, DATE_TEST_NOW - 2 * DAY_MILLISECONDS), "B"), // 2 days ago
        try makeDateRecord(allocator, 3, "Record 3", try isoString(allocator, DATE_TEST_NOW - 1 * DAY_MILLISECONDS), try isoString(allocator, DATE_TEST_NOW - 4 * DAY_MILLISECONDS), "A"), // created 1 day ago, updated 4 days ago
        try makeDateRecord(allocator, 4, "Record 4", try isoString(allocator, DATE_TEST_NOW - 3 * DAY_MILLISECONDS), try isoString(allocator, DATE_TEST_NOW - 3 * DAY_MILLISECONDS), "C"), // 3 days ago
        try makeDateRecord(allocator, 5, "Record 5", try isoString(allocator, DATE_TEST_NOW), try isoString(allocator, DATE_TEST_NOW), "B"), // today
    };
}

test "should retrieve records in ascending date order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try dateTestRecords(allocator));
    const sortIndexAsc = try fixture.sortIndex("test_collection", "createdAt", .asc, .date, null);

    // Initialize the index
    try sortIndexAsc.build(io, collection);

    // Get all records by traversing pages
    const allRecords = try getAllRecords(allocator, sortIndexAsc);

    // Verify records are in ascending date order
    var recordIndex: usize = 1;
    while (recordIndex < allRecords.len) : (recordIndex += 1) {
        const prevDate = js_date.parseDate(allRecords[recordIndex - 1].get("createdAt").?.string);
        const currDate = js_date.parseDate(allRecords[recordIndex].get("createdAt").?.string);
        try std.testing.expect(prevDate <= currDate);
    }

    // First record should be the oldest (earliest date)
    try std.testing.expectEqualStrings(try recordId(allocator, 1), allRecords[0].get("_id").?.string); // Record 1 (4 days ago)

    // Last record should be the newest (latest date)
    try std.testing.expectEqualStrings(try recordId(allocator, 5), allRecords[allRecords.len - 1].get("_id").?.string); // Record 5 (today)
}

test "should retrieve records in descending date order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try dateTestRecords(allocator));
    const sortIndexDesc = try fixture.sortIndex("test_collection", "updatedAt", .desc, .date, null);

    // Initialize the index
    try sortIndexDesc.build(io, collection);

    // Get all records by traversing pages
    const allRecords = try getAllRecords(allocator, sortIndexDesc);

    // Verify records are in descending date order
    var recordIndex: usize = 1;
    while (recordIndex < allRecords.len) : (recordIndex += 1) {
        const prevDate = js_date.parseDate(allRecords[recordIndex - 1].get("updatedAt").?.string);
        const currDate = js_date.parseDate(allRecords[recordIndex].get("updatedAt").?.string);
        try std.testing.expect(prevDate >= currDate);
    }

    // First record should be the newest (latest date)
    try std.testing.expectEqualStrings(try recordId(allocator, 5), allRecords[0].get("_id").?.string); // Record 5 (today)

    // Last record should be the oldest (earliest date)
    try std.testing.expectEqualStrings(try recordId(allocator, 3), allRecords[allRecords.len - 1].get("_id").?.string); // Record 3 (updated 4 days ago)
}

test "should update records with new dates in the index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const records = try dateTestRecords(allocator);
    const collection = try fixture.collection("test_collection", &records);
    const sortIndexAsc = try fixture.sortIndex("test_collection", "createdAt", .asc, .date, null);

    // Initialize the index
    try sortIndexAsc.build(io, collection);

    // Update a record with a new createdAt date
    const newDate = try isoString(allocator, DATE_TEST_NOW - 5 * DAY_MILLISECONDS); // 5 days ago
    // Clone Record 3, changing its date to 5 days ago (was 1 day ago)
    const updatedRecord = try makeDateRecord(allocator, 3, "Record 3", newDate, records[2].fields.get("updatedAt").?.string, "A");

    try sortIndexAsc.updateRecord(io, updatedRecord, records[2]);

    // Find records by the new date
    const result = try sortIndexAsc.findByValue(io, .{ .string = newDate }, null);

    // Should find the updated record with the new date
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings(try recordId(allocator, 3), result[0].get("_id").?.string);
    try std.testing.expectEqualStrings(newDate, result[0].get("createdAt").?.string);

    // Original date should no longer have this record
    const oldDateResult = try sortIndexAsc.findByValue(io, records[2].fields.get("createdAt").?, null);
    try std.testing.expectEqual(@as(usize, 0), oldDateResult.len);

    // Get all records and verify proper sorting
    const allRecords = try getAllRecords(allocator, sortIndexAsc);

    // First record should now be the updated Record 3 (5 days ago)
    try std.testing.expectEqualStrings(try recordId(allocator, 3), allRecords[0].get("_id").?.string);
}

test "should add a new record with a date to the index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try dateTestRecords(allocator));
    const sortIndexAsc = try fixture.sortIndex("test_collection", "createdAt", .asc, .date, null);

    // Initialize the index
    try sortIndexAsc.build(io, collection);

    // Add a new record with a specific date
    const newRecordDate = try isoString(allocator, DATE_TEST_NOW - 6 * DAY_MILLISECONDS); // 6 days ago
    const newRecord = try makeDateRecord(allocator, 6, "Record 6", newRecordDate, try isoString(allocator, DATE_TEST_NOW), "A");

    try sortIndexAsc.addRecord(io, newRecord);

    // Find the record by its date
    const result = try sortIndexAsc.findByValue(io, .{ .string = newRecordDate }, null);

    // Should find the new record
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings(try recordId(allocator, 6), result[0].get("_id").?.string);

    // Get all records and verify the new record is in the correct position
    const allRecords = try getAllRecords(allocator, sortIndexAsc);

    // First record should now be Record 6 (6 days ago)
    try std.testing.expectEqualStrings(try recordId(allocator, 6), allRecords[0].get("_id").?.string);

    // Verify the total record count has increased
    try std.testing.expectEqual(@as(usize, 6), allRecords.len);
}

//
// Builds a number test record { name, score, price, quantity, rating } in internal form.
//
fn makeProductRecord(allocator: std.mem.Allocator, number: u32, name: []const u8, score: f64, price: f64, quantity: f64, rating: f64) !IInternalRecord {
    return makeFieldsRecord(allocator, number, &.{
        .{
            .key = "name",
            .value = .{ .string = name },
        },
        .{
            .key = "score",
            .value = .{ .number = score },
        },
        .{
            .key = "price",
            .value = .{ .number = price },
        },
        .{
            .key = "quantity",
            .value = .{ .number = quantity },
        },
        .{
            .key = "rating",
            .value = .{ .number = rating },
        },
    });
}

//
// The records of the TypeScript sort-index-number tests.
//
fn numberTestRecords(allocator: std.mem.Allocator) ![6]IInternalRecord {
    return .{
        try makeProductRecord(allocator, 1, "Product A", 85.5, 29.99, 100, 4.2),
        try makeProductRecord(allocator, 2, "Product B", 92.1, 15.50, 50, 4.8),
        try makeProductRecord(allocator, 3, "Product C", 78.3, 99.99, 25, 3.5),
        try makeProductRecord(allocator, 4, "Product D", 88.7, 45.00, 75, 4.1),
        try makeProductRecord(allocator, 5, "Product E", 95.2, 12.99, 200, 4.9),
        try makeProductRecord(allocator, 6, "Product F", 82.0, 35.75, 0, 3.8),
    };
}

test "should retrieve records in ascending numeric order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try numberTestRecords(allocator));
    const sortIndexAsc = try fixture.sortIndex("test_collection", "score", .asc, .number, null);

    // Initialize the index
    try sortIndexAsc.build(io, collection);

    // Get all records by traversing pages
    const allRecords = try getAllRecords(allocator, sortIndexAsc);

    // Verify records are in ascending numeric order
    var recordIndex: usize = 1;
    while (recordIndex < allRecords.len) : (recordIndex += 1) {
        const prevScore = allRecords[recordIndex - 1].get("score").?.number;
        const currScore = allRecords[recordIndex].get("score").?.number;
        try std.testing.expect(prevScore <= currScore);
    }

    // Check specific ordering
    // Expected order by score: 78.3, 82.0, 85.5, 88.7, 92.1, 95.2
    try std.testing.expectEqual(@as(f64, 78.3), allRecords[0].get("score").?.number); // Product C
    try std.testing.expectEqual(@as(f64, 82.0), allRecords[1].get("score").?.number); // Product F
    try std.testing.expectEqual(@as(f64, 85.5), allRecords[2].get("score").?.number); // Product A
    try std.testing.expectEqual(@as(f64, 88.7), allRecords[3].get("score").?.number); // Product D
    try std.testing.expectEqual(@as(f64, 92.1), allRecords[4].get("score").?.number); // Product B
    try std.testing.expectEqual(@as(f64, 95.2), allRecords[5].get("score").?.number); // Product E
}

test "should retrieve records in descending numeric order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try numberTestRecords(allocator));
    const sortIndexDesc = try fixture.sortIndex("test_collection", "price", .desc, .number, null);

    // Initialize the index
    try sortIndexDesc.build(io, collection);

    // Get all records by traversing pages
    const allRecords = try getAllRecords(allocator, sortIndexDesc);

    // Verify records are in descending numeric order
    var recordIndex: usize = 1;
    while (recordIndex < allRecords.len) : (recordIndex += 1) {
        const prevPrice = allRecords[recordIndex - 1].get("price").?.number;
        const currPrice = allRecords[recordIndex].get("price").?.number;
        try std.testing.expect(prevPrice >= currPrice);
    }

    // Check specific ordering
    // Expected order by price: 99.99, 45.00, 35.75, 29.99, 15.50, 12.99
    try std.testing.expectEqual(@as(f64, 99.99), allRecords[0].get("price").?.number); // Product C
    try std.testing.expectEqual(@as(f64, 45.00), allRecords[1].get("price").?.number); // Product D
    try std.testing.expectEqual(@as(f64, 35.75), allRecords[2].get("price").?.number); // Product F
    try std.testing.expectEqual(@as(f64, 29.99), allRecords[3].get("price").?.number); // Product A
    try std.testing.expectEqual(@as(f64, 15.50), allRecords[4].get("price").?.number); // Product B
    try std.testing.expectEqual(@as(f64, 12.99), allRecords[5].get("price").?.number); // Product E
}

test "should update records with new numeric values in the index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const records = try numberTestRecords(allocator);
    const collection = try fixture.collection("test_collection", &records);
    const sortIndexAsc = try fixture.sortIndex("test_collection", "score", .asc, .number, null);

    // Initialize the index
    try sortIndexAsc.build(io, collection);

    // Update a record with a new score
    // Clone Product C, changing its score from 78.3 to 90.5
    const updatedRecord = try makeProductRecord(allocator, 3, "Product C", 90.5, 99.99, 25, 3.5);

    try sortIndexAsc.updateRecord(io, updatedRecord, records[2]);

    // Find records by the new score
    const result = try sortIndexAsc.findByValue(io, .{ .number = 90.5 }, null);

    // Should find the updated record with the new score
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings(try recordId(allocator, 3), result[0].get("_id").?.string);
    try std.testing.expectEqual(@as(f64, 90.5), result[0].get("score").?.number);

    // Original score should no longer have this record
    const oldScoreResult = try sortIndexAsc.findByValue(io, .{ .number = 78.3 }, null);
    try std.testing.expectEqual(@as(usize, 0), oldScoreResult.len);

    // Get all records and verify proper sorting
    const allRecords = try getAllRecords(allocator, sortIndexAsc);

    // Verify the updated record is in the correct position
    const updatedRecordIndex = findRecordIndexById(allRecords, try recordId(allocator, 3));
    try std.testing.expect(updatedRecordIndex != null);
    try std.testing.expectEqual(@as(f64, 90.5), allRecords[updatedRecordIndex.?].get("score").?.number);

    // Verify sorting is still correct
    var recordIndex: usize = 1;
    while (recordIndex < allRecords.len) : (recordIndex += 1) {
        const prevScore = allRecords[recordIndex - 1].get("score").?.number;
        const currScore = allRecords[recordIndex].get("score").?.number;
        try std.testing.expect(prevScore <= currScore);
    }
}

test "should add a new record with a numeric value to the index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try numberTestRecords(allocator));
    const sortIndexAsc = try fixture.sortIndex("test_collection", "score", .asc, .number, null);

    // Initialize the index
    try sortIndexAsc.build(io, collection);

    // Add a new record with a specific score
    const newRecord = try makeProductRecord(allocator, 7, "Product G", 89.0, 22.50, 150, 4.3);

    try sortIndexAsc.addRecord(io, newRecord);

    // Find the record by its score
    const result = try sortIndexAsc.findByValue(io, .{ .number = 89.0 }, null);

    // Should find the new record
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings(try recordId(allocator, 7), result[0].get("_id").?.string);

    // Get all records and verify the new record is in the correct position
    const allRecords = try getAllRecords(allocator, sortIndexAsc);

    // Verify the new record is in the correct numeric position
    var newRecordIndex: ?usize = null;
    for (allRecords, 0..) |record, recordIndex| {
        if (newRecordIndex == null and record.get("score").?.number == 89.0) {
            newRecordIndex = recordIndex;
        }
    }
    try std.testing.expect(newRecordIndex != null);

    // Verify the total record count has increased
    try std.testing.expectEqual(@as(usize, 7), allRecords.len);

    // Verify sorting is still correct
    var recordIndex: usize = 1;
    while (recordIndex < allRecords.len) : (recordIndex += 1) {
        const prevScore = allRecords[recordIndex - 1].get("score").?.number;
        const currScore = allRecords[recordIndex].get("score").?.number;
        try std.testing.expect(prevScore <= currScore);
    }
}

test "should handle integer and floating point numbers correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try numberTestRecords(allocator));
    const sortIndexAsc = try fixture.sortIndex("test_collection", "score", .asc, .number, null);

    // Initialize the index
    try sortIndexAsc.build(io, collection);

    // Get all records sorted by score
    const allRecords = try getAllRecords(allocator, sortIndexAsc);

    // Extract scores in order
    const sortedScores = try allocator.alloc(f64, allRecords.len);
    for (allRecords, 0..) |record, recordIndex| {
        sortedScores[recordIndex] = record.get("score").?.number;
    }

    // Verify mixed integer and floating point sorting
    // Expected: [78.3, 82.0, 85.5, 88.7, 92.1, 95.2]
    try std.testing.expectEqualSlices(f64, &.{ 78.3, 82.0, 85.5, 88.7, 92.1, 95.2 }, sortedScores);

    // Verify that integer 82.0 is treated as a number, not string
    var integerRecord: ?ISortIndexRecord = null;
    for (allRecords) |record| {
        const score = record.get("score").?;
        if (integerRecord == null and score == .number and score.number == 82.0) {
            integerRecord = record;
        }
    }
    try std.testing.expect(integerRecord != null);
    try std.testing.expectEqualStrings("number", bdb.js_value.typeOf(integerRecord.?.get("score").?));
}

//
// Builds a string test record { name, category, status, title } in internal form.
//
fn makeStringRecord(allocator: std.mem.Allocator, number: u32, name: []const u8, category: []const u8, status: []const u8, title: []const u8) !IInternalRecord {
    return makeFieldsRecord(allocator, number, &.{
        .{
            .key = "name",
            .value = .{ .string = name },
        },
        .{
            .key = "category",
            .value = .{ .string = category },
        },
        .{
            .key = "status",
            .value = .{ .string = status },
        },
        .{
            .key = "title",
            .value = .{ .string = title },
        },
    });
}

//
// The records of the TypeScript sort-index-string tests.
//
fn stringTestRecords(allocator: std.mem.Allocator) ![7]IInternalRecord {
    return .{
        try makeStringRecord(allocator, 1, "zebra", "animal", "active", "Mr. Zebra"),
        try makeStringRecord(allocator, 2, "apple", "fruit", "pending", "Green Apple"),
        try makeStringRecord(allocator, 3, "banana", "fruit", "completed", "Yellow Banana"),
        try makeStringRecord(allocator, 4, "cat", "animal", "active", "Fluffy Cat"),
        try makeStringRecord(allocator, 5, "orange", "fruit", "inactive", "Orange Fruit"),
        try makeStringRecord(allocator, 6, "Apple", "fruit", "active", "Red Apple"),
        try makeStringRecord(allocator, 7, "Zebra", "animal", "pending", "Big Zebra"),
    };
}

test "should retrieve records in ascending string order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try stringTestRecords(allocator));
    const sortIndexAsc = try fixture.sortIndex("test_collection", "name", .asc, .string, null);

    // Initialize the index
    try sortIndexAsc.build(io, collection);

    // Get all records by traversing pages
    const allRecords = try getAllRecords(allocator, sortIndexAsc);

    // Verify records are in ascending string order using localeCompare
    var recordIndex: usize = 1;
    while (recordIndex < allRecords.len) : (recordIndex += 1) {
        const prevName = allRecords[recordIndex - 1].get("name").?.string;
        const currName = allRecords[recordIndex].get("name").?.string;
        try std.testing.expect(localeCompare(prevName, currName) <= 0);
    }

    // Check specific ordering - locale-aware string comparison
    // With locale comparison, 'apple' and 'Apple' should be grouped together
    // and 'zebra' and 'Zebra' should be grouped together
    var appleIndex: ?usize = null;
    var bananaIndex: ?usize = null;
    var zebraIndex: ?usize = null;
    for (allRecords, 0..) |record, nameIndex| {
        const name = record.get("name").?.string;
        if (appleIndex == null and std.ascii.eqlIgnoreCase(name, "apple")) {
            appleIndex = nameIndex;
        }
        if (bananaIndex == null and std.mem.eql(u8, name, "banana")) {
            bananaIndex = nameIndex;
        }
        if (zebraIndex == null and std.ascii.eqlIgnoreCase(name, "zebra")) {
            zebraIndex = nameIndex;
        }
    }

    try std.testing.expect(appleIndex.? < bananaIndex.?); // apple comes before banana
    try std.testing.expect(bananaIndex.? < zebraIndex.?); // banana comes before zebra
}

test "should retrieve records in descending string order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try stringTestRecords(allocator));
    const sortIndexDesc = try fixture.sortIndex("test_collection", "status", .desc, .string, null);

    // Initialize the index
    try sortIndexDesc.build(io, collection);

    // Get all records by traversing pages
    const allRecords = try getAllRecords(allocator, sortIndexDesc);

    // Verify records are in descending string order
    var recordIndex: usize = 1;
    while (recordIndex < allRecords.len) : (recordIndex += 1) {
        const prevStatus = allRecords[recordIndex - 1].get("status").?.string;
        const currStatus = allRecords[recordIndex].get("status").?.string;
        try std.testing.expect(localeCompare(prevStatus, currStatus) >= 0);
    }

    // Check specific ordering - descending alphabetical
    // Expected order: "pending", "pending", "inactive", "completed", "active", "active", "active"
    try std.testing.expectEqualStrings("pending", allRecords[0].get("status").?.string);
    try std.testing.expectEqualStrings("active", allRecords[allRecords.len - 1].get("status").?.string);
}

test "should update records with new string values in the index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const records = try stringTestRecords(allocator);
    const collection = try fixture.collection("test_collection", &records);
    const sortIndexAsc = try fixture.sortIndex("test_collection", "name", .asc, .string, null);

    // Initialize the index
    try sortIndexAsc.build(io, collection);

    // Update a record with a new name
    // Clone the banana record, changing its name from 'banana' to 'kiwi'
    const updatedRecord = try makeStringRecord(allocator, 3, "kiwi", "fruit", "completed", "Yellow Banana");

    try sortIndexAsc.updateRecord(io, updatedRecord, records[2]);

    // Find records by the new name
    const result = try sortIndexAsc.findByValue(io, .{ .string = "kiwi" }, null);

    // Should find the updated record with the new name
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings(try recordId(allocator, 3), result[0].get("_id").?.string);
    try std.testing.expectEqualStrings("kiwi", result[0].get("name").?.string);

    // Original name should no longer have this record
    const oldNameResult = try sortIndexAsc.findByValue(io, .{ .string = "banana" }, null);
    try std.testing.expectEqual(@as(usize, 0), oldNameResult.len);

    // Get all records and verify proper sorting
    const allRecords = try getAllRecords(allocator, sortIndexAsc);

    // Verify the updated record is in the correct position
    const updatedRecordIndex = findRecordIndexById(allRecords, try recordId(allocator, 3));
    try std.testing.expect(updatedRecordIndex != null);
    try std.testing.expectEqualStrings("kiwi", allRecords[updatedRecordIndex.?].get("name").?.string);

    // Verify sorting is still correct
    var recordIndex: usize = 1;
    while (recordIndex < allRecords.len) : (recordIndex += 1) {
        const prevName = allRecords[recordIndex - 1].get("name").?.string;
        const currName = allRecords[recordIndex].get("name").?.string;
        try std.testing.expect(localeCompare(prevName, currName) <= 0);
    }
}

test "should add a new record with a string value to the index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try stringTestRecords(allocator));
    const sortIndexAsc = try fixture.sortIndex("test_collection", "name", .asc, .string, null);

    // Initialize the index
    try sortIndexAsc.build(io, collection);

    // Add a new record with a specific name
    const newRecord = try makeStringRecord(allocator, 8, "grape", "fruit", "active", "Purple Grape");

    try sortIndexAsc.addRecord(io, newRecord);

    // Find the record by its name
    const result = try sortIndexAsc.findByValue(io, .{ .string = "grape" }, null);

    // Should find the new record
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings(try recordId(allocator, 8), result[0].get("_id").?.string);

    // Get all records and verify the new record is in the correct position
    const allRecords = try getAllRecords(allocator, sortIndexAsc);

    // Verify the new record is in the correct alphabetical position
    var grapeIndex: ?usize = null;
    for (allRecords, 0..) |record, nameIndex| {
        if (grapeIndex == null and std.mem.eql(u8, record.get("name").?.string, "grape")) {
            grapeIndex = nameIndex;
        }
    }
    try std.testing.expect(grapeIndex != null);

    // Verify the total record count has increased
    try std.testing.expectEqual(@as(usize, 8), allRecords.len);

    // Verify sorting is still correct
    var recordIndex: usize = 1;
    while (recordIndex < allRecords.len) : (recordIndex += 1) {
        const prevName = allRecords[recordIndex - 1].get("name").?.string;
        const currName = allRecords[recordIndex].get("name").?.string;
        try std.testing.expect(localeCompare(prevName, currName) <= 0);
    }
}

//
// The records of the TypeScript sort-index-page-split tests (sequential scores to easily verify sort order).
//
fn pageSplitTestRecords(allocator: std.mem.Allocator) ![5]IInternalRecord {
    return .{
        try makeTestRecord(allocator, 1, "Record 1", 10, "A"),
        try makeTestRecord(allocator, 2, "Record 2", 20, "B"),
        try makeTestRecord(allocator, 3, "Record 3", 30, "A"),
        try makeTestRecord(allocator, 4, "Record 4", 40, "C"),
        try makeTestRecord(allocator, 5, "Record 5", 50, "B"),
    };
}

//
// Returns the scores of records sorted in ascending order (TypeScript: `records.map(r => r.score).sort((a, b) => a - b)`).
//
fn sortScores(allocator: std.mem.Allocator, records: []const ISortIndexRecord) ![]f64 {
    const result = try allocator.alloc(f64, records.len);
    for (records, 0..) |record, recordIndex| {
        result[recordIndex] = record.get("score").?.number;
    }
    std.mem.sort(f64, result, {}, std.sort.asc(f64));
    return result;
}

test "should verify logical sort order is maintained after page split" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try pageSplitTestRecords(allocator));
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);

    // Initialize the index with initial records
    try index.build(io, collection);

    // Force metadata save
    try index.commit(io);

    // Add records that will cause a page split
    // These should be inserted in the middle of our sorted values
    const recordToSplit1 = try makeTestRecord(allocator, 6, "Record 6", 25, "D");
    const recordToSplit2 = try makeTestRecord(allocator, 7, "Record 7", 15, "D");

    // Add records that will trigger page splits
    try index.addRecord(io, recordToSplit1); // Add score 25 (should go in middle)
    try index.addRecord(io, recordToSplit2); // Add score 15 (should go near beginning)

    // After adding these records, the tree file should still exist
    try std.testing.expect(fixture.storage.getFile("db/indexes/test_collection/score_asc/tree.dat") != null);

    // Now request records in order and verify they come back sorted
    var allRecords: std.ArrayList(ISortIndexRecord) = .empty;
    var currentPage = try index.getPage(io, "");

    // Check total record count and page count
    try std.testing.expectEqual(@as(i64, 7), currentPage.totalRecords);
    try std.testing.expect(currentPage.totalPages >= 1);

    // Add records from first page
    try allRecords.appendSlice(allocator, currentPage.records);

    // Follow next page links until we've visited all pages
    while (currentPage.nextPageId) |nextPageId| {
        currentPage = try index.getPage(io, nextPageId);
        try allRecords.appendSlice(allocator, currentPage.records);
    }

    // Check records are returned in score order regardless of when they were added
    // Scores should be in correct order (sorted)
    try std.testing.expectEqualSlices(f64, &.{ 10, 15, 20, 25, 30, 40, 50 }, try sortScores(allocator, allRecords.items));

    // Not ported: the range query across the split page (findByRange is not used by the ported commands).
}

test "should maintain correct page ordering when multiple pages are split" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const collection = try fixture.collection("test_collection", &try pageSplitTestRecords(allocator));
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);

    // Initialize the index with initial records
    try index.build(io, collection);

    // Add many records to cause multiple page splits
    const additionalRecords = [_]IInternalRecord{
        try makeTestRecord(allocator, 11, "Record 11", 11, "A"),
        try makeTestRecord(allocator, 12, "Record 12", 21, "B"),
        try makeTestRecord(allocator, 13, "Record 13", 31, "A"),
        try makeTestRecord(allocator, 14, "Record 14", 41, "C"),
        try makeTestRecord(allocator, 15, "Record 15", 51, "B"),
        try makeTestRecord(allocator, 16, "Record 16", 12, "A"),
        try makeTestRecord(allocator, 17, "Record 17", 22, "B"),
        try makeTestRecord(allocator, 18, "Record 18", 32, "A"),
        try makeTestRecord(allocator, 19, "Record 19", 42, "C"),
        try makeTestRecord(allocator, 20, "Record 20", 52, "B"),
    };

    // Add records that will cause multiple page splits
    for (additionalRecords) |record| {
        try index.addRecord(io, record);
    }

    // Now we should have multiple pages
    // Force metadata save
    try index.commit(io);

    // Get all records across all pages
    var allRecords: std.ArrayList(ISortIndexRecord) = .empty;
    var currentPage = try index.getPage(io, "");

    try std.testing.expect(currentPage.totalPages >= 1);

    // Add records from first page
    try allRecords.appendSlice(allocator, currentPage.records);

    // Follow next page links until we've visited all pages
    while (currentPage.nextPageId) |nextPageId| {
        currentPage = try index.getPage(io, nextPageId);
        try allRecords.appendSlice(allocator, currentPage.records);
    }

    // Check records are returned in score order
    // All the scores sorted
    const expectedScores = [_]f64{ 10, 11, 12, 20, 21, 22, 30, 31, 32, 40, 41, 42, 50, 51, 52 };

    // Scores should be in order
    try std.testing.expectEqualSlices(f64, &expectedScores, try sortScores(allocator, allRecords.items));

    // Test a specific binary search to verify we can find records
    // Try several values to find one that works (B-tree traversal might be slightly different)
    var foundScore = false;
    for ([_]f64{ 31, 21, 11, 41, 51 }) |score| {
        const result = try index.findByValue(io, .{ .number = score }, null);
        if (result.len > 0) {
            try std.testing.expectEqual(score, result[0].get("score").?.number);
            foundScore = true;
            break;
        }
    }
    try std.testing.expect(foundScore);

    // Not ported: the range query across the split pages (findByRange is not used by the ported commands).
}

//
// The counts are JavaScript numbers in TypeScript, so a count that goes below zero (an index file whose count is
// short) stays negative until commit, where `writeUInt32` refuses it with the runtime's RangeError.
//
test "a count that goes below zero is refused at commit like writeUInt32 refuses it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const record = try makeTestRecord(allocator, 1, "Record 1", 85, "A");
    const collection = try fixture.collection("test_collection", &.{record});
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    index.totalEntries = 0;

    try index.deleteRecord(io, record._id, record);
    try std.testing.expectEqual(@as(i64, -1), index.totalEntries);
    try std.testing.expectError(error.Thrown, index.commit(io));
    try std.testing.expectEqualStrings("The value of \"value\" is out of range. It must be >= 0 and <= 4294967295. Received -1", errors.lastErrorMessage());
}


//
// The number of records the multi-page tests index: more than a leaf holds (PAGE_SIZE times the split threshold), so
// the index splits into two pages.
//
const MULTI_PAGE_RECORD_COUNT = 1600;

//
// Builds MULTI_PAGE_RECORD_COUNT records with the scores 1 to MULTI_PAGE_RECORD_COUNT, or all with the score 5 when
// sameScore is true.
//
fn multiPageRecords(allocator: std.mem.Allocator, sameScore: bool) ![]IInternalRecord {
    const records = try allocator.alloc(IInternalRecord, MULTI_PAGE_RECORD_COUNT);
    for (records, 0..) |*record, recordIndex| {
        const number: u32 = @intCast(recordIndex + 1);
        const score: f64 = if (sameScore) 5 else @floatFromInt(number);
        record.* = try makeTestRecord(allocator, number, "Record", score, "A");
    }
    return records;
}

//
// Builds a sort index on score over the records, which must come out as two pages.
//
fn multiPageIndex(fixture: *Fixture, records: []const IInternalRecord) !*SortIndex {
    const collection = try fixture.collection("test_collection", records);
    const index = try fixture.sortIndex("test_collection", "score", .asc, null, null);
    try index.build(io, collection);
    try std.testing.expectEqual(@as(u32, 2), (try index.getPage(io, null)).totalPages);
    return index;
}

//
// The records of the first and the second page of a two page index.
//
const ITwoPages = struct {
    // The records of the first page.
    first: []const ISortIndexRecord,

    // The records of the second page.
    second: []const ISortIndexRecord,
};

//
// Reads the two pages of a two page index.
//
fn twoPages(index: *SortIndex) !ITwoPages {
    const first = try index.getPage(io, "");
    const second = try index.getPage(io, first.nextPageId.?);
    try std.testing.expect(second.nextPageId == null);
    return .{ .first = first.records, .second = second.records };
}

//
// Builds the internal record a sort index record was made from (the fields makeTestRecord gives, with its id).
//
fn internalRecordOf(allocator: std.mem.Allocator, record: ISortIndexRecord, score: f64) !IInternalRecord {
    var internal = try makeTestRecord(allocator, 0, "Record", score, "A");
    internal._id = record.get("_id").?.string;
    return internal;
}

test "deleteRecord removes a page whose records are all deleted, from either end of the page chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const records = try multiPageRecords(allocator, false);

    // The last page.
    var fixture = try Fixture.init(allocator);
    const index = try multiPageIndex(&fixture, records);
    const pages = try twoPages(index);
    for (pages.second) |record| {
        try index.deleteRecord(io, record.get("_id").?.string, try internalRecordOf(allocator, record, record.get("score").?.number));
    }
    const firstPage = try index.getPage(io, null);
    try std.testing.expectEqual(@as(u32, 1), firstPage.totalPages);
    try std.testing.expectEqual(@as(u32, @intCast(pages.first.len)), firstPage.totalRecords);
    try std.testing.expect(firstPage.nextPageId == null);
    try std.testing.expectEqual(pages.first.len, (try getAllRecords(allocator, index)).len);

    // The first page, of a second index over the same records. (Known issue, in the TypeScript too: the removed
    // leaf stays a child of its parent, so the listing from the first page, which starts at that child, comes back
    // empty. The page counts and the second page itself are right.)
    var secondFixture = try Fixture.init(allocator);
    const secondIndex = try multiPageIndex(&secondFixture, records);
    const secondPages = try twoPages(secondIndex);
    const secondPageId = (try secondIndex.getPage(io, "")).nextPageId.?;
    for (secondPages.first) |record| {
        try secondIndex.deleteRecord(io, record.get("_id").?.string, try internalRecordOf(allocator, record, record.get("score").?.number));
    }
    const secondPage = try secondIndex.getPage(io, secondPageId);
    try std.testing.expectEqual(@as(u32, 1), secondPage.totalPages);
    try std.testing.expectEqual(@as(u32, @intCast(secondPages.second.len)), secondPage.totalRecords);
    try std.testing.expectEqual(secondPages.second.len, secondPage.records.len);
    try std.testing.expect(secondPage.previousPageId == null or secondPage.previousPageId.?.len == 0);
}

test "updateRecord removes a page whose records all move to another value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const index = try multiPageIndex(&fixture, try multiPageRecords(allocator, false));
    const pages = try twoPages(index);

    // Every record of the last page moves to the value 0, at the start of the first page.
    for (pages.second) |record| {
        try index.updateRecord(io, try internalRecordOf(allocator, record, 0), try internalRecordOf(allocator, record, record.get("score").?.number));
    }
    const all = try getAllRecords(allocator, index);
    try std.testing.expectEqual(@as(usize, MULTI_PAGE_RECORD_COUNT), all.len);
    try std.testing.expectEqual(@as(f64, 0), all[0].get("score").?.number);
    try std.testing.expectEqual(pages.first[pages.first.len - 1].get("score").?.number, all[all.len - 1].get("score").?.number);
    try std.testing.expectEqual(pages.second.len, (try index.findByValue(io, .{ .number = 0 }, null)).len);
}

test "deleteRecord finds the records of a value that spans pages outside the leaf the value leads to" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const index = try multiPageIndex(&fixture, try multiPageRecords(allocator, true));
    const pages = try twoPages(index);

    // Every record has the score 5, so the value leads to the first leaf and the records of the second leaf are
    // found by walking the page chain. Deleting them all removes the second page.
    for (pages.second) |record| {
        try index.deleteRecord(io, record.get("_id").?.string, try internalRecordOf(allocator, record, 5));
    }
    const firstPage = try index.getPage(io, null);
    try std.testing.expectEqual(@as(u32, 1), firstPage.totalPages);
    try std.testing.expect(firstPage.nextPageId == null);
    try std.testing.expectEqual(pages.first.len, (try getAllRecords(allocator, index)).len);
}

test "updateRecord finds the records of a value that spans pages outside the leaf the value leads to" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture = try Fixture.init(allocator);
    const index = try multiPageIndex(&fixture, try multiPageRecords(allocator, true));
    const secondPageId = (try index.getPage(io, "")).nextPageId.?;
    const pages = try twoPages(index);

    // Every record of the second page but the last moves to the value 4, which leaves the page in place.
    const last = pages.second[pages.second.len - 1];
    for (pages.second[0 .. pages.second.len - 1]) |record| {
        try index.updateRecord(io, try internalRecordOf(allocator, record, 4), try internalRecordOf(allocator, record, 5));
    }
    try std.testing.expectEqual(@as(u32, MULTI_PAGE_RECORD_COUNT), (try index.getPage(io, null)).totalRecords);

    // Moving the last one too empties the second page, which is removed.
    try index.updateRecord(io, try internalRecordOf(allocator, last, 4), try internalRecordOf(allocator, last, 5));
    const all = try getAllRecords(allocator, index);
    try std.testing.expectEqual(@as(usize, MULTI_PAGE_RECORD_COUNT), all.len);
    try std.testing.expectEqual(@as(f64, 4), all[0].get("score").?.number);

    // The emptied page is gone (the first page may have split under the records that moved into it).
    try std.testing.expectEqual(@as(usize, 0), (try index.getPage(io, secondPageId)).records.len);
    try std.testing.expectEqual(pages.second.len, (try index.findByValue(io, .{ .number = 4 }, null)).len);
    try std.testing.expectEqual(pages.first.len, (try index.findByValue(io, .{ .number = 5 }, null)).len);
}
