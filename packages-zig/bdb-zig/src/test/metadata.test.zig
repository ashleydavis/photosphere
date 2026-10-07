//
// Tests for the metadata and timestamps of a collection (port of src/tests/metadata.test.ts).
//

const std = @import("std");
const bdb = @import("bdb-zig");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const bson = serialization_zig.bson;
const BsonValue = bson.BsonValue;
const BsonDocument = bson.BsonDocument;
const BsonCollection = bdb.collection.BsonCollection;
const IInternalRecord = bdb.shard.IInternalRecord;
const ITimestampProvider = utils.timestamp_provider.ITimestampProvider;
const Date = utils.timestamp_provider.Date;

const io = std.testing.io;

//
// Mock timestamp provider for testing - allows manual control of timestamps (the MockTimestampProvider of the
// TypeScript utils package).
//
const MockTimestampProvider = struct {
    // The timestamp it reports.
    currentTimestamp: i64,

    //
    // Creates the provider.
    //
    fn init(initialTimestamp: i64) MockTimestampProvider {
        return .{
            .currentTimestamp = initialTimestamp,
        };
    }

    //
    // Gets the ITimestampProvider interface.
    //
    fn timestampProvider(self: *MockTimestampProvider) ITimestampProvider {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The ITimestampProvider functions of this provider.
    //
    const vtable: ITimestampProvider.VTable = .{
        .now = nowErased,
        .dateNow = dateNowErased,
    };

    //
    // Gets the current timestamp.
    //
    fn now(self: *MockTimestampProvider) i64 {
        return self.currentTimestamp;
    }

    //
    // Sets the current timestamp (for testing).
    //
    fn setTimestamp(self: *MockTimestampProvider, timestamp: i64) void {
        self.currentTimestamp = timestamp;
    }

    //
    // Advances the timestamp by the specified milliseconds (for testing).
    //
    fn advance(self: *MockTimestampProvider, milliseconds: i64) void {
        self.currentTimestamp += milliseconds;
    }

    //
    // Type-erased now for the vtable.
    //
    fn nowErased(ptr: *anyopaque, _: std.Io) i64 {
        const self: *MockTimestampProvider = @ptrCast(@alignCast(ptr));
        return self.now();
    }

    //
    // Type-erased dateNow for the vtable.
    //
    fn dateNowErased(ptr: *anyopaque, _: std.Io) Date {
        const self: *MockTimestampProvider = @ptrCast(@alignCast(ptr));
        return .{
            .epochMilliseconds = self.now(),
        };
    }
};

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
fn newCollection(allocator: std.mem.Allocator, storage: *MemoryStorage, timestampProvider: *MockTimestampProvider) !*BsonCollection {
    const collection = try allocator.create(BsonCollection);
    collection.* = BsonCollection.init(allocator, "test", "", storage.asStorage(), "", random_uuid_generator.uuidGenerator(), timestampProvider.timestampProvider(), .{ .context = storage, .function = onDirty });
    return collection;
}

//
// Gets the internal version of a record, with its metadata (TypeScript: getInternalRecord).
//
fn getInternalRecord(collection: *BsonCollection, id: []const u8) !?IInternalRecord {
    var records = collection.iterateRecords();
    while (try records.next(io)) |record| {
        if (std.mem.eql(u8, record._id, id)) {
            return record;
        }
    }
    return null;
}

//
// Builds a string value.
//
fn string(value: []const u8) BsonValue {
    return .{
        .string = value,
    };
}

//
// Builds a number value.
//
fn number(value: f64) BsonValue {
    return .{
        .number = value,
    };
}

//
// Builds an object value from its fields.
//
fn object(allocator: std.mem.Allocator, fields: []const bson.BsonField) !BsonValue {
    return .{
        .document = try BsonDocument.fromFields(allocator, fields),
    };
}

//
// Builds one field of an object.
//
fn field(key: []const u8, value: BsonValue) bson.BsonField {
    return .{
        .key = key,
        .value = value,
    };
}

//
// Builds the record the first tests insert (name, email and age).
//
fn simpleRecord(allocator: std.mem.Allocator, id: []const u8) !BsonDocument {
    return BsonDocument.fromFields(allocator, &.{
        field("_id", string(id)),
        field("name", string("John Doe")),
        field("email", string("john@example.com")),
        field("age", number(30)),
    });
}

//
// Reads `metadata.fields` (null when it is undefined).
//
fn metadataFields(metadata: BsonDocument) ?BsonDocument {
    const fields = metadata.get("fields") orelse {
        return null;
    };
    if (fields == .undefined) {
        return null;
    }
    return fields.document;
}

//
// Reads `fields[key]` (null when it is undefined).
//
fn entry(fields: BsonDocument, key: []const u8) ?BsonDocument {
    const value = fields.get(key) orelse {
        return null;
    };
    if (value == .undefined) {
        return null;
    }
    return value.document;
}

//
// Reads `metadata.timestamp`.
//
fn timestampOf(metadata: BsonDocument) i64 {
    return @intFromFloat(metadata.get("timestamp").?.number);
}

test "inserting puts a timestamp on the entire record" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var timestampProvider = MockTimestampProvider.init(1000);
    const collection = try newCollection(allocator, &storage, &timestampProvider);
    const id = "123e4567-e89b-12d3-a456-426614174001";
    const timestamp: i64 = 1000;
    timestampProvider.setTimestamp(timestamp);

    var record = try simpleRecord(allocator, id);

    try collection.insertOne(io, &record, timestamp);

    const internal = try getInternalRecord(collection, id);
    try std.testing.expect(internal != null);
    try std.testing.expectEqual(timestamp, timestampOf(internal.?.metadata));
    try std.testing.expect(metadataFields(internal.?.metadata) == null);
}

test "updating a root field sets the timestamp for that field but not others" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var timestampProvider = MockTimestampProvider.init(1000);
    const collection = try newCollection(allocator, &storage, &timestampProvider);
    const id = "123e4567-e89b-12d3-a456-426614174002";
    const insertTimestamp: i64 = 1000;
    timestampProvider.setTimestamp(insertTimestamp);
    timestampProvider.advance(100);
    const updateTimestamp = timestampProvider.now();

    var record = try simpleRecord(allocator, id);

    try collection.insertOne(io, &record, insertTimestamp);
    _ = try collection.updateOne(io, id, try BsonDocument.fromFields(allocator, &.{field("name", string("Jane Doe"))}), .{ .timestamp = updateTimestamp });

    const internal = try getInternalRecord(collection, id);
    try std.testing.expect(internal != null);
    try std.testing.expectEqual(insertTimestamp, timestampOf(internal.?.metadata));
    try std.testing.expect(metadataFields(internal.?.metadata) != null);

    const nameMeta = entry(metadataFields(internal.?.metadata).?, "name");
    try std.testing.expect(nameMeta != null);
    try std.testing.expectEqual(updateTimestamp, timestampOf(nameMeta.?));

    // Other fields should not have individual timestamps (they inherit from parent).
    try std.testing.expect(entry(metadataFields(internal.?.metadata).?, "email") == null);
    try std.testing.expect(entry(metadataFields(internal.?.metadata).?, "age") == null);
}

test "updating a nested field sets the timestamp for the nested field but not others" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var timestampProvider = MockTimestampProvider.init(1000);
    const collection = try newCollection(allocator, &storage, &timestampProvider);
    const id = "123e4567-e89b-12d3-a456-426614174003";
    const insertTimestamp: i64 = 1000;
    timestampProvider.setTimestamp(insertTimestamp);
    timestampProvider.advance(100);
    const updateTimestamp = timestampProvider.now();

    var record = try BsonDocument.fromFields(allocator, &.{
        field("_id", string(id)),
        field("name", string("John Doe")),
        field("email", string("john@example.com")),
        field("age", number(30)),
        field("address", try object(allocator, &.{
            field("street", string("123 Main St")),
            field("city", string("New York")),
            field("zip", string("10001")),
        })),
    });

    try collection.insertOne(io, &record, insertTimestamp);
    _ = try collection.updateOne(io, id, try BsonDocument.fromFields(allocator, &.{
        field("address", try object(allocator, &.{
            field("street", string("456 Oak Ave")),
            field("city", string("New York")), // Unchanged
            // zip not set
        })),
    }), .{ .timestamp = updateTimestamp });

    const internal = try getInternalRecord(collection, id);
    try std.testing.expect(internal != null);
    try std.testing.expectEqual(insertTimestamp, timestampOf(internal.?.metadata));
    try std.testing.expect(metadataFields(internal.?.metadata) != null);
    const addressMeta = entry(metadataFields(internal.?.metadata).?, "address");
    try std.testing.expect(addressMeta != null);
    try std.testing.expect(metadataFields(addressMeta.?) != null);
    const streetMeta = entry(metadataFields(addressMeta.?).?, "street");
    try std.testing.expect(streetMeta != null);
    try std.testing.expectEqual(updateTimestamp, timestampOf(streetMeta.?));

    // City and zip should not have individual timestamp (unchanged, inherits from address).
    try std.testing.expect(entry(metadataFields(addressMeta.?).?, "city") == null);
    try std.testing.expect(entry(metadataFields(addressMeta.?).?, "zip") == null);
}

test "updating multiple fields at once updates their timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var timestampProvider = MockTimestampProvider.init(1000);
    const collection = try newCollection(allocator, &storage, &timestampProvider);
    const id = "123e4567-e89b-12d3-a456-426614174005";
    const insertTimestamp: i64 = 1000;
    timestampProvider.setTimestamp(insertTimestamp);
    timestampProvider.advance(100);
    const updateTimestamp = timestampProvider.now();

    var record = try simpleRecord(allocator, id);

    try collection.insertOne(io, &record, insertTimestamp);
    _ = try collection.updateOne(io, id, try BsonDocument.fromFields(allocator, &.{
        field("name", string("Jane Doe")),
        field("age", number(31)),
    }), .{ .timestamp = updateTimestamp });

    const internal = try getInternalRecord(collection, id);
    try std.testing.expect(internal != null);
    try std.testing.expectEqual(insertTimestamp, timestampOf(internal.?.metadata));
    try std.testing.expect(metadataFields(internal.?.metadata) != null);
    const nameMeta = entry(metadataFields(internal.?.metadata).?, "name");
    try std.testing.expect(nameMeta != null);
    try std.testing.expectEqual(updateTimestamp, timestampOf(nameMeta.?));
    const ageMeta = entry(metadataFields(internal.?.metadata).?, "age");
    try std.testing.expect(ageMeta != null);
    try std.testing.expectEqual(updateTimestamp, timestampOf(ageMeta.?));

    // Email should not have individual timestamp (unchanged).
    try std.testing.expect(entry(metadataFields(internal.?.metadata).?, "email") == null);
}

test "updating a single field multiple times updates its timestamp each time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var timestampProvider = MockTimestampProvider.init(1000);
    const collection = try newCollection(allocator, &storage, &timestampProvider);
    const id = "123e4567-e89b-12d3-a456-426614174006";
    const insertTimestamp: i64 = 1000;
    timestampProvider.setTimestamp(insertTimestamp);
    timestampProvider.advance(100);
    const update1Timestamp = timestampProvider.now();
    timestampProvider.advance(100);
    const update2Timestamp = timestampProvider.now();

    var record = try simpleRecord(allocator, id);

    try collection.insertOne(io, &record, insertTimestamp);
    _ = try collection.updateOne(io, id, try BsonDocument.fromFields(allocator, &.{field("name", string("Jane Doe"))}), .{ .timestamp = update1Timestamp });
    _ = try collection.updateOne(io, id, try BsonDocument.fromFields(allocator, &.{field("name", string("Bob Smith"))}), .{ .timestamp = update2Timestamp });

    const internal = try getInternalRecord(collection, id);
    try std.testing.expect(internal != null);
    try std.testing.expect(metadataFields(internal.?.metadata) != null);
    const nameMeta = entry(metadataFields(internal.?.metadata).?, "name");
    try std.testing.expect(nameMeta != null);
    try std.testing.expectEqual(update2Timestamp, timestampOf(nameMeta.?)); // Latest timestamp
    try std.testing.expect(timestampOf(nameMeta.?) != update1Timestamp);
}

test "deleting a field with newer timestamp preserves metadata entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var timestampProvider = MockTimestampProvider.init(1000);
    const collection = try newCollection(allocator, &storage, &timestampProvider);
    const id = "123e4567-e89b-12d3-a456-426614174008";
    const insertTimestamp: i64 = 1000;
    timestampProvider.setTimestamp(insertTimestamp);

    var record = try simpleRecord(allocator, id);

    try collection.insertOne(io, &record, insertTimestamp);

    timestampProvider.advance(100);
    const updateTimestamp = timestampProvider.now();
    _ = try collection.updateOne(io, id, try BsonDocument.fromFields(allocator, &.{field("name", string("Jane Doe"))}), .{ .timestamp = updateTimestamp });

    // Verify name has metadata
    var internal = try getInternalRecord(collection, id);
    const nameMeta1 = entry(metadataFields(internal.?.metadata).?, "name");
    try std.testing.expect(nameMeta1 != null);
    try std.testing.expectEqual(updateTimestamp, timestampOf(nameMeta1.?));

    // Delete the name field with a newer timestamp
    timestampProvider.advance(100);
    const deletionTimestamp = timestampProvider.now();
    _ = try collection.updateOne(io, id, try BsonDocument.fromFields(allocator, &.{field("name", .undefined)}), .{ .timestamp = deletionTimestamp });

    internal = try getInternalRecord(collection, id);

    // After deletion, the field should have metadata with the deletion timestamp
    try std.testing.expect(metadataFields(internal.?.metadata) != null);
    const nameMeta2 = entry(metadataFields(internal.?.metadata).?, "name");
    try std.testing.expect(nameMeta2 != null);
    try std.testing.expectEqual(deletionTimestamp, timestampOf(nameMeta2.?));
    // The field should be undefined in the fields object
    try std.testing.expect((internal.?.fields.get("name") orelse .undefined) == .undefined);
}

// This used to assert that an update stamped with the record's own timestamp produced no field
// metadata at all. The values were still written, so the record held a change with nothing saying
// when it was made, and a sync merge then read it as the older side and discarded it. The change
// is now stamped above the record.
test "updating nested object with the same timestamp as the record stamps the change above it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var timestampProvider = MockTimestampProvider.init(1000);
    const collection = try newCollection(allocator, &storage, &timestampProvider);
    const id = "123e4567-e89b-12d3-a456-426614174009";
    const insertTimestamp: i64 = 1000;
    timestampProvider.setTimestamp(insertTimestamp);

    var record = try BsonDocument.fromFields(allocator, &.{
        field("_id", string(id)),
        field("name", string("John Doe")),
        field("address", try object(allocator, &.{
            field("street", string("123 Main St")),
            field("city", string("New York")),
        })),
    });

    try collection.insertOne(io, &record, insertTimestamp);

    // Update the entire address with the same timestamp
    _ = try collection.updateOne(io, id, try BsonDocument.fromFields(allocator, &.{
        field("address", try object(allocator, &.{
            field("street", string("456 Oak Ave")),
            field("city", string("Boston")),
        })),
    }), .{ .timestamp = insertTimestamp });

    const internal = try getInternalRecord(collection, id);
    try std.testing.expect(internal != null);
    try std.testing.expectEqual(insertTimestamp, timestampOf(internal.?.metadata));

    // The record's own timestamp stays put and each changed leaf is stamped one above it, so the
    // change cannot be ordered before the values it replaced.
    const address = internal.?.fields.get("address").?.document;
    try std.testing.expectEqualStrings("456 Oak Ave", address.get("street").?.string);
    try std.testing.expectEqualStrings("Boston", address.get("city").?.string);
    const addressMeta = entry(metadataFields(internal.?.metadata).?, "address").?;
    try std.testing.expectEqual(insertTimestamp + 1, timestampOf(entry(metadataFields(addressMeta).?, "street").?));
    try std.testing.expectEqual(insertTimestamp + 1, timestampOf(entry(metadataFields(addressMeta).?, "city").?));
}

test "deeply nested fields track timestamps correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var timestampProvider = MockTimestampProvider.init(1000);
    const collection = try newCollection(allocator, &storage, &timestampProvider);
    const id = "123e4567-e89b-12d3-a456-42661417400a";
    const insertTimestamp: i64 = 1000;
    timestampProvider.setTimestamp(insertTimestamp);
    timestampProvider.advance(100);
    const updateTimestamp = timestampProvider.now();

    var record = try BsonDocument.fromFields(allocator, &.{
        field("_id", string(id)),
        field("name", string("John Doe")),
        field("address", try object(allocator, &.{
            field("street", string("123 Main St")),
            field("city", string("New York")),
            field("country", try object(allocator, &.{
                field("code", string("US")),
                field("name", string("United States")),
            })),
        })),
    });

    try collection.insertOne(io, &record, insertTimestamp);
    _ = try collection.updateOne(io, id, try BsonDocument.fromFields(allocator, &.{
        field("address", try object(allocator, &.{
            field("street", string("123 Main St")),
            field("city", string("New York")),
            field("country", try object(allocator, &.{
                field("code", string("CA")),
                field("name", string("Canada")),
            })),
        })),
    }), .{ .timestamp = updateTimestamp });

    const internal = try getInternalRecord(collection, id);
    try std.testing.expect(internal != null);
    try std.testing.expectEqual(insertTimestamp, timestampOf(internal.?.metadata));

    const addressMeta = entry(metadataFields(internal.?.metadata).?, "address");
    try std.testing.expect(addressMeta != null);
    // address should be ObjectMetadata (nested object)
    const countryMeta = entry(metadataFields(addressMeta.?).?, "country");
    try std.testing.expect(countryMeta != null);
    // country should be ObjectMetadata (nested object)

    // Street and city should not have individual timestamps (unchanged).
    try std.testing.expect(entry(metadataFields(addressMeta.?).?, "street") == null);
    try std.testing.expect(entry(metadataFields(addressMeta.?).?, "city") == null);
}
