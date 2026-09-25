const std = @import("std");
const bdb = @import("bdb-zig");
const serialization_zig = @import("serialization-zig");
const utils = @import("utils-zig");
const helpers = @import("test-helpers.zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const json_stable_stringify = bdb.json_stable_stringify;
const bson = serialization_zig.bson;

test "stringify matches json-stable-stringify for the synthetic records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const fixture = try helpers.readJsonFixture(allocator, io, "hash-records.json");
    const decoder = std.base64.standard.Decoder;
    for (fixture.object.get("synthetic").?.array.items) |item| {
        const encoded = item.object.get("bson").?.string;
        const bsonBytes = try allocator.alloc(u8, try decoder.calcSizeForSlice(encoded));
        try decoder.decode(bsonBytes, encoded);
        const fields = try bson.deserialize(allocator, bsonBytes);
        const actual = try json_stable_stringify.stringifyDocument(allocator, fields);
        std.testing.expectEqualStrings(item.object.get("stable").?.string, actual) catch |err| {
            std.debug.print("synthetic record: {s}\n", .{item.object.get("name").?.string});
            return err;
        };
    }
}

test "stringify matches json-stable-stringify for every record in the test databases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const fixture = try helpers.readJsonFixture(allocator, io, "hash-records.json");
    var testUuidGenerator: utils.test_uuid_generator.TestUuidGenerator = .{};
    var currentDatabase: []const u8 = "";
    var records: std.StringHashMapUnmanaged(bdb.shard.IInternalRecord) = .empty;
    var checked: usize = 0;
    for (fixture.object.get("real").?.array.items) |item| {
        const databaseName = item.object.get("database").?.string;
        if (!std.mem.eql(u8, databaseName, currentDatabase)) {
            currentDatabase = databaseName;
            records = .empty;
            var storage = try allocator.create(MemoryStorage);
            storage.* = MemoryStorage.init(allocator);
            const databaseDir = try std.fmt.allocPrint(allocator, "{s}/{s}/.db/bson", .{ helpers.TEST_DBS_DIR, databaseName });
            try storage.loadDirectory(io, databaseDir, ".db/bson");
            const database = try bdb.database.BsonDatabase.init(allocator, storage.asStorage(), ".db/bson", testUuidGenerator.uuidGenerator(), helpers.timestamp_provider.timestampProvider());
            const collection = try database.collection("metadata");
            var iterator = collection.iterateRecords();
            while (try iterator.next(io)) |record| {
                try records.put(allocator, record._id, record);
            }
        }
        const record = records.get(item.object.get("id").?.string).?;
        const actual = try json_stable_stringify.stringifyDocument(allocator, record.fields);
        try std.testing.expectEqualStrings(item.object.get("stable").?.string, actual);
        checked += 1;
    }
    try std.testing.expect(checked > 100);
}

test "stringify returns null for undefined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), try json_stable_stringify.stringify(arena.allocator(), .undefined));
}

test "stringify sorts keys and leaves out undefined fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const document = try bson.BsonDocument.fromFields(allocator, &.{
        .{ .key = "b", .value = .{ .number = 1 } },
        .{ .key = "a", .value = .{ .string = "x\ny" } },
        .{ .key = "u", .value = .undefined },
    });
    try std.testing.expectEqualStrings("{\"a\":\"x\\ny\",\"b\":1}", try json_stable_stringify.stringifyDocument(allocator, document));
}
