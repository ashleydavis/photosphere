const std = @import("std");
const bdb = @import("bdb-zig");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const test_clock = @import("test-clock.zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const BsonDocument = serialization_zig.bson.BsonDocument;
const BsonDatabase = bdb.database.BsonDatabase;
const IBsonCollection = bdb.collection.IBsonCollection;
const errors = utils.errors;

const io = std.testing.io;

//
// Generates the ids of records inserted without one.
//
var random_uuid_generator: utils.random_uuid_generator.RandomUuidGenerator = .{};

//
// Creates the collection under test (TypeScript: the beforeEach block; the temporary directory it makes is
// never used, so it is not ported).
//
fn newCollection(allocator: std.mem.Allocator, storage: *MemoryStorage) !*IBsonCollection {
    const db = try BsonDatabase.init(allocator, storage.asStorage(), "", random_uuid_generator.uuidGenerator(), test_clock.timestamp_provider.timestampProvider());
    return db.collection("testCollection");
}

//
// Builds a test document (TypeScript: the object literal).
//
fn makeDocument(allocator: std.mem.Allocator, id: ?[]const u8, name: []const u8, value: f64) !BsonDocument {
    var document: BsonDocument = .empty;
    if (id) |documentId| {
        try document.put(allocator, "_id", .{ .string = documentId });
    }
    try document.put(allocator, "name", .{ .string = name });
    try document.put(allocator, "value", .{ .number = value });
    return document;
}

//
// Gets a record by id through its shard (TypeScript: getOne, which is not ported).
//
fn getRecord(collection: *IBsonCollection, id: []const u8) !?bdb.shard.IInternalRecord {
    const shard = try collection.shard(try collection.getShardId(id));
    return shard.record(io, id);
}

test "should throw error when inserting document with duplicate ID" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);

    // Create a test document with a specific ID
    var testDoc = try makeDocument(allocator, "12345678-1234-1234-1234-123456789012", "Test Document", 42);

    // First insert should succeed
    try collection.insertOne(io, &testDoc, null);

    // Second insert with same ID should throw an error
    try std.testing.expectError(error.Thrown, collection.insertOne(io, &testDoc, null));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "Document with ID 12345678-1234-1234-1234-123456789012 already exists") != null);
}

test "should allow inserting documents with different IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);

    // Create two test documents with different IDs
    var testDoc1 = try makeDocument(allocator, "12345678-1234-1234-1234-123456789012", "Test Document 1", 42);
    var testDoc2 = try makeDocument(allocator, "87654321-4321-4321-4321-210987654321", "Test Document 2", 100);

    // Both inserts should succeed
    try collection.insertOne(io, &testDoc1, null);
    try collection.insertOne(io, &testDoc2, null);

    // Verify both documents exist
    const doc1 = try getRecord(collection, "12345678-1234-1234-1234-123456789012");
    const doc2 = try getRecord(collection, "87654321-4321-4321-4321-210987654321");

    try std.testing.expect(doc1 != null);
    try std.testing.expectEqualStrings("Test Document 1", doc1.?.fields.get("name").?.string);

    try std.testing.expect(doc2 != null);
    try std.testing.expectEqualStrings("Test Document 2", doc2.?.fields.get("name").?.string);
}

test "should generate ID if not provided and not allow duplicate inserts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const collection = try newCollection(allocator, &storage);

    // Create a test document without an ID
    var testDoc = try makeDocument(allocator, null, "Test Document", 42);

    // First insert should succeed and assign an ID
    try collection.insertOne(io, &testDoc, null);

    // Get the inserted document's ID
    const allRecords = try collection.getAll(io, null);
    const insertedDoc = allRecords.records[0];
    const generatedId = insertedDoc.get("_id").?.string;

    // Create a new document with the same generated ID
    var duplicateDoc = try makeDocument(allocator, generatedId, "Duplicate Document", 100);

    // Inserting with the same ID should throw an error
    try std.testing.expectError(error.Thrown, collection.insertOne(io, &duplicateDoc, null));
    const expectedMessage = try std.fmt.allocPrint(allocator, "Document with ID {s} already exists", .{generatedId});
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), expectedMessage) != null);
}
