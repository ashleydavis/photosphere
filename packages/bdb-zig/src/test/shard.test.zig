const std = @import("std");
const bdb = @import("bdb-zig");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const helpers = @import("test-helpers.zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const bson = serialization_zig.bson;
const BsonShard = bdb.shard.BsonShard;
const IInternalRecord = bdb.shard.IInternalRecord;
const getRecordKey = bdb.shard.getRecordKey;
const errors = utils.errors;

const io = std.testing.io;

//
// The database root used by the tests.
//
const testBsonDbPath = "";

//
// The collection used by the tests.
//
const testCollectionName = "test";

//
// Generates ids for the shard merkle trees.
//
var test_uuid_generator: utils.test_uuid_generator.TestUuidGenerator = .{};

//
// Creates a shard over a storage.
//
fn newTestShard(allocator: std.mem.Allocator, shardId: []const u8, storage: *MemoryStorage) BsonShard {
    return BsonShard.init(allocator, shardId, storage.asStorage(), testBsonDbPath, testCollectionName, test_uuid_generator.uuidGenerator());
}

//
// Creates a record with a name field.
//
fn makeRecord(allocator: std.mem.Allocator, id: []const u8, name: []const u8) !IInternalRecord {
    return .{
        ._id = id,
        .fields = try bson.BsonDocument.fromFields(allocator, &.{.{ .key = "name", .value = .{ .string = name } }}),
        .metadata = .empty,
    };
}

//
// Asserts two records are equal (TypeScript: `toEqual`).
//
fn expectRecordEqual(expected: IInternalRecord, actual: ?IInternalRecord) !void {
    try std.testing.expect(actual != null);
    try std.testing.expectEqualStrings(expected._id, actual.?._id);
    try std.testing.expect(expected.fields.eql(actual.?.fields));
    try std.testing.expect(expected.metadata.eql(actual.?.metadata));
}

//
// Record ids used by the tests.
//
const recordId1 = "123e4567-e89b-12d3-a456-426614174000";

//
// A second record id.
//
const recordId2 = "aabbccdd-1122-3344-5566-778899aabbcc";

//
// A third record id (sorts first).
//
const recordId3 = "00000000-0000-0000-0000-000000000001";

test "normalizeShardRecordId strips dashes and returns 32-char hex" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try getRecordKey(arena.allocator(), recordId1);
    try std.testing.expectEqualStrings("123e4567e89b12d3a456426614174000", result);
    try std.testing.expectEqual(@as(usize, 32), result.len);
}

test "normalizeShardRecordId accepts already-normalized id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try getRecordKey(arena.allocator(), "123e4567e89b12d3a456426614174000");
    try std.testing.expectEqualStrings("123e4567e89b12d3a456426614174000", result);
}

test "normalizeShardRecordId throws for an invalid id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Thrown, getRecordKey(arena.allocator(), "not-a-uuid"));
    try std.testing.expectEqualStrings("Invalid record ID not-a-uuid with length 0", errors.lastErrorMessage());
}

test "getRecordKey lowercases and truncates at invalid hex like Buffer.from" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("123e4567e89b12d3a456426614174000", try getRecordKey(arena.allocator(), "123E4567-E89B-12D3-A456-426614174000"));
    try std.testing.expectError(error.Thrown, getRecordKey(arena.allocator(), "123e4567-e89b-12d3-a456-4266141740zz"));
    try std.testing.expectEqualStrings("Invalid record ID 123e4567-e89b-12d3-a456-4266141740zz with length 15", errors.lastErrorMessage());
}

test "BsonShard markDirty sets dirty flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    var shard = newTestShard(arena.allocator(), "s1", &storage);
    try std.testing.expect(!shard.dirty());
    shard.markDirty();
    try std.testing.expect(shard.dirty());
}

test "BsonShard markClean clears dirty flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    var shard = newTestShard(arena.allocator(), "s1", &storage);
    shard.markDirty();
    shard.markClean();
    try std.testing.expect(!shard.dirty());
}

test "BsonShard load with missing file leaves empty records map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    var shard = newTestShard(arena.allocator(), "s1", &storage);
    try shard.load(io);
    try std.testing.expectEqual(@as(usize, 0), (try shard.records(io)).count());
}

test "BsonShard load is idempotent - second call does not reset records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var shard = newTestShard(allocator, "s1", &storage);
    try shard.setRecord(io, recordId1, try makeRecord(allocator, recordId1, "a"));
    try shard.load(io); // should be a no-op because _records is already set
    try std.testing.expectEqual(@as(usize, 1), (try shard.records(io)).count());
}

test "BsonShard setRecord marks shard dirty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var shard = newTestShard(allocator, "s1", &storage);
    try std.testing.expect(!shard.dirty());
    try shard.setRecord(io, recordId1, try makeRecord(allocator, recordId1, "a"));
    try std.testing.expect(shard.dirty());
}

test "BsonShard record returns undefined for unknown id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    var shard = newTestShard(arena.allocator(), "s1", &storage);
    try std.testing.expect((try shard.record(io, recordId1)) == null);
}

test "BsonShard setRecord and record round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var shard = newTestShard(allocator, "s1", &storage);
    const rec = try makeRecord(allocator, recordId1, "a");
    try shard.setRecord(io, recordId1, rec);
    try expectRecordEqual(rec, try shard.record(io, recordId1));
}

test "BsonShard setRecord stores multiple records independently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var shard = newTestShard(allocator, "s1", &storage);
    const rec1 = try makeRecord(allocator, recordId1, "a");
    const rec2 = try makeRecord(allocator, recordId2, "b");
    try shard.setRecord(io, recordId1, rec1);
    try shard.setRecord(io, recordId2, rec2);
    try std.testing.expectEqual(@as(usize, 2), (try shard.records(io)).count());
    try expectRecordEqual(rec1, try shard.record(io, recordId1));
    try expectRecordEqual(rec2, try shard.record(io, recordId2));
}

test "BsonShard deleteRecord removes the record and keeps dirty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var shard = newTestShard(allocator, "s1", &storage);
    try shard.setRecord(io, recordId1, try makeRecord(allocator, recordId1, "a"));
    try shard.deleteRecord(io, recordId1);
    try std.testing.expect(shard.dirty());
    try std.testing.expect((try shard.record(io, recordId1)) == null);
}

test "BsonShard deleteRecord on nonexistent id does not throw" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    var shard = newTestShard(arena.allocator(), "s1", &storage);
    try shard.deleteRecord(io, recordId1);
}

test "BsonShard deleteRecord leaves other records intact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var shard = newTestShard(allocator, "s1", &storage);
    const rec1 = try makeRecord(allocator, recordId1, "a");
    const rec2 = try makeRecord(allocator, recordId2, "b");
    try shard.setRecord(io, recordId1, rec1);
    try shard.setRecord(io, recordId2, rec2);
    try shard.deleteRecord(io, recordId1);
    try std.testing.expect((try shard.record(io, recordId1)) == null);
    try expectRecordEqual(rec2, try shard.record(io, recordId2));
}

test "BsonShard setRecord getRecord deleteRecord use normalized ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var shard = newTestShard(allocator, "s1", &storage);
    const record = try makeRecord(allocator, recordId1, "a");
    try std.testing.expect(!shard.dirty());
    try shard.setRecord(io, recordId1, record);
    try std.testing.expect(shard.dirty());
    try expectRecordEqual(record, try shard.record(io, recordId1));
    try shard.deleteRecord(io, recordId1);
    try std.testing.expect(shard.dirty());
    try std.testing.expect((try shard.record(io, recordId1)) == null);
}

test "BsonShard setRecord builds merkle tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var shard = newTestShard(allocator, "0", &storage);
    try shard.setRecord(io, recordId1, try makeRecord(allocator, recordId1, "a"));
    const tree = try (try shard.merkleTree()).get(io);
    try std.testing.expect(tree != null);
    try std.testing.expect(tree.?.sort != null);
}

test "BsonShard deleteRecord drops merkle tree when the last record is removed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var shard = newTestShard(allocator, "0", &storage);
    try shard.setRecord(io, recordId1, try makeRecord(allocator, recordId1, "a"));
    try shard.deleteRecord(io, recordId1);
    try std.testing.expect((try (try shard.merkleTree()).get(io)) == null);
}

test "BsonShard merkle tree is not undefined when one record remains after delete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var shard = newTestShard(allocator, "0", &storage);
    try shard.setRecord(io, recordId1, try makeRecord(allocator, recordId1, "a"));
    try shard.setRecord(io, recordId2, try makeRecord(allocator, recordId2, "b"));
    try shard.deleteRecord(io, recordId1);
    try std.testing.expect((try (try shard.merkleTree()).get(io)) != null);
}

test "BsonShard commit is a no-op when not dirty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var storage = MemoryStorage.init(arena.allocator());
    var shard = newTestShard(arena.allocator(), "s1", &storage);
    try shard.commit(io); // should not throw or write anything
    try std.testing.expect(!shard.dirty());
    try std.testing.expectEqual(@as(usize, 0), storage.files.count());
}

test "BsonShard commit persists records and clears dirty flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var shard = newTestShard(allocator, "s1", &storage);
    try shard.setRecord(io, recordId1, try makeRecord(allocator, recordId1, "hello"));
    try shard.commit(io);
    try std.testing.expect(!shard.dirty());
    try std.testing.expect(storage.getFile("collections/test/shards/s1") != null);
    try std.testing.expect(storage.getFile("collections/test/shards/s1.dat") != null);
}

test "BsonShard commit round-trips records through storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var shard = newTestShard(allocator, "s1", &storage);
    const rec = try makeRecord(allocator, recordId1, "hello");
    try shard.setRecord(io, recordId1, rec);
    try shard.commit(io);

    // Load a fresh shard from the same storage
    var shard2 = newTestShard(allocator, "s1", &storage);
    try shard2.load(io);
    try std.testing.expectEqual(@as(usize, 1), (try shard2.records(io)).count());
    try expectRecordEqual(rec, try shard2.record(io, recordId1));
}

test "BsonShard commit round-trips multiple records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var shard = newTestShard(allocator, "s1", &storage);
    const rec1 = try makeRecord(allocator, recordId1, "a");
    const rec2 = try makeRecord(allocator, recordId2, "b");
    const rec3 = try makeRecord(allocator, recordId3, "c");
    try shard.setRecord(io, recordId1, rec1);
    try shard.setRecord(io, recordId2, rec2);
    try shard.setRecord(io, recordId3, rec3);
    try shard.commit(io);

    var shard2 = newTestShard(allocator, "s1", &storage);
    try shard2.load(io);
    try std.testing.expectEqual(@as(usize, 3), (try shard2.records(io)).count());
    try expectRecordEqual(rec1, try shard2.record(io, recordId1));
    try expectRecordEqual(rec2, try shard2.record(io, recordId2));
    try expectRecordEqual(rec3, try shard2.record(io, recordId3));

    // Records are written sorted by id (localeCompare), so they load in that order.
    const loadedIds = (try shard2.records(io)).values();
    try std.testing.expectEqualStrings(recordId3, loadedIds[0]._id);
    try std.testing.expectEqualStrings(recordId1, loadedIds[1]._id);
    try std.testing.expectEqualStrings(recordId2, loadedIds[2]._id);
}

test "BsonShard commit deletes file when all records are removed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var shard = newTestShard(allocator, "s1", &storage);
    try shard.setRecord(io, recordId1, try makeRecord(allocator, recordId1, "a"));
    try shard.commit(io);

    try shard.deleteRecord(io, recordId1);
    try shard.commit(io);
    try std.testing.expect(!shard.dirty());
    try std.testing.expect(storage.getFile("collections/test/shards/s1") == null);
    try std.testing.expect(storage.getFile("collections/test/shards/s1.dat") == null);

    // A fresh shard should see no records
    var shard2 = newTestShard(allocator, "s1", &storage);
    try shard2.load(io);
    try std.testing.expectEqual(@as(usize, 0), (try shard2.records(io)).count());
}

test "BsonShard loads a version 1 shard file written by TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try storage.putFile("collections/test/shards/v1", try helpers.readFixture(allocator, io, "shard-v1.bin"));
    var shard = newTestShard(allocator, "v1", &storage);
    const records = try shard.records(io);
    try std.testing.expectEqual(@as(usize, 2), records.count());
    const first = (try shard.record(io, "0f8fad5b-d9cb-469f-a165-70867728950e")).?;
    try std.testing.expectEqualStrings("0f8fad5b-d9cb-469f-a165-70867728950e", first._id);
    try std.testing.expectEqualStrings("abc", first.fields.get("hash").?.string);
    try std.testing.expectEqual(@as(usize, 0), first.metadata.count());
    const second = (try shard.record(io, "123e4567-e89b-12d3-a456-426614174000")).?;
    try std.testing.expectEqual(@as(i64, 1609545600000), second.fields.get("photoDate").?.date);
}

test "BsonShard writes the same shard payload as the test database records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var source = MemoryStorage.init(allocator);
    try source.loadDirectory(io, helpers.TEST_DBS_DIR ++ "/50-assets/.db/bson", "db");
    var destination = MemoryStorage.init(allocator);
    var compared: usize = 0;
    for (source.files.keys()) |filePath| {
        if (!std.mem.startsWith(u8, filePath, "db/collections/metadata/shards/") or std.mem.endsWith(u8, filePath, ".dat")) {
            continue;
        }
        const shardId = filePath["db/collections/metadata/shards/".len..];
        var sourceShard = BsonShard.init(allocator, shardId, source.asStorage(), "db", "metadata", test_uuid_generator.uuidGenerator());
        var destinationShard = BsonShard.init(allocator, shardId, destination.asStorage(), "db", "metadata", test_uuid_generator.uuidGenerator());
        const records = try sourceShard.records(io);
        // Insert in reverse order to prove the file is sorted by id on write.
        var recordIndex = records.count();
        while (recordIndex > 0) {
            recordIndex -= 1;
            const record = records.values()[recordIndex];
            try destinationShard.setRecord(io, record._id, record);
        }
        try destinationShard.commit(io);

        // Some checked in files use the legacy framing [version][payload][checksum]; the current one adds the type
        // code [version]["SHAR"][payload][checksum]. Current files are identical, legacy ones have the same payload.
        const sourceFile = source.getFile(filePath).?;
        const destinationFile = destination.getFile(filePath).?;
        if (std.mem.eql(u8, sourceFile[4..8], "SHAR")) {
            try std.testing.expectEqualSlices(u8, sourceFile, destinationFile);
        }
        else {
            try std.testing.expectEqualStrings("SHAR", destinationFile[4..8]);
            try std.testing.expectEqualSlices(u8, sourceFile[0..4], destinationFile[0..4]);
            try std.testing.expectEqualSlices(u8, sourceFile[4 .. sourceFile.len - 32], destinationFile[8 .. destinationFile.len - 32]);
        }

        // The record hashes equal the hashes TypeScript stored in the shard merkle tree.
        const sourceTree = (try (try sourceShard.merkleTree()).get(io)).?;
        const destinationTree = (try (try destinationShard.merkleTree()).get(io)).?;
        try std.testing.expectEqualSlices(u8, sourceTree.merkle.?.hash, destinationTree.merkle.?.hash);
        compared += 1;
    }
    try std.testing.expect(compared > 10);
}
