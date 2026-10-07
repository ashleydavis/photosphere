const std = @import("std");
const bdb = @import("bdb-zig");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const fixtures = @import("fixtures.zig");
const test_clock = @import("test-clock.zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const bson = serialization_zig.bson;
const BsonDocument = bson.BsonDocument;
const BsonDatabase = bdb.database.BsonDatabase;
const IInternalRecord = bdb.shard.IInternalRecord;
const TestUuidGenerator = utils.test_uuid_generator.TestUuidGenerator;
const SortNode = merkle_tree_zig.merkle_tree.SortNode;
const js_value = bdb.js_value;

//
// Golden scenario tests: each test replays one scenario of generate.ts in Zig and checks that the database files are
// the files TypeScript wrote (plain files byte for byte by SHA-256, gzip merkle tree files by their loaded content)
// and that the database root hash is the same.
//

const io = std.testing.io;

//
// Hex SHA-256 of some bytes.
//
fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

//
// The time the scenario dates are based on (generate.ts BASE_TIME: Date.UTC(2020, 0, 1)).
//
const BASE_TIME: i64 = 1577836800000;

//
// Builds the fields of scenario record `index` exactly like generate.ts makeFields (same keys in the same order).
//
fn makeFields(allocator: std.mem.Allocator, index: i64, variant: i64) !BsonDocument {
    var fields: BsonDocument = .empty;
    if (@mod(index, 7) == 0) {
        try fields.put(allocator, "hash", .{ .string = try std.fmt.allocPrint(allocator, "dup-{d}", .{variant}) });
    }
    else {
        try fields.put(allocator, "hash", .{ .string = try sha256Hex(allocator, try std.fmt.allocPrint(allocator, "record-{d}-{d}", .{ index, variant })) });
    }
    try fields.put(allocator, "name", .{ .string = try std.fmt.allocPrint(allocator, "file-{d}.jpg", .{index}) });
    const dateKind = @mod(index, 5);
    const photoTime = BASE_TIME + index * 3600000 * (variant + 1);
    if (dateKind == 1) {
        var output: std.Io.Writer.Allocating = .init(allocator);
        try js_value.writeIsoString(&output.writer, photoTime);
        try fields.put(allocator, "photoDate", .{ .string = output.written() });
    }
    else if (dateKind != 0) {
        try fields.put(allocator, "photoDate", .{ .date = photoTime });
    }
    try fields.put(allocator, "size", .{ .number = @floatFromInt(index * 1000 + variant) });
    try fields.put(allocator, "ratio", .{ .number = @as(f64, @floatFromInt(index)) / 7.0 });
    const tags = try allocator.alloc(bson.BsonValue, 2);
    tags[0] = .{ .string = "a" };
    tags[1] = .{ .number = @floatFromInt(index) };
    try fields.put(allocator, "tags", .{ .array = tags });
    if (@mod(index, 3) == 0) {
        try fields.put(allocator, "location", .null);
    }
    else {
        const location = try BsonDocument.fromFields(allocator, &.{
            .{ .key = "lat", .value = .{ .number = @as(f64, @floatFromInt(index)) * 0.5 } },
            .{ .key = "lng", .value = .{ .number = -@as(f64, @floatFromInt(index)) } },
        });
        try fields.put(allocator, "location", .{ .document = location });
    }
    return fields;
}

//
// Builds a metadata document `{ timestamp }` like the scenarios in generate.ts.
//
fn makeMetadata(allocator: std.mem.Allocator, timestamp: i64) !BsonDocument {
    return BsonDocument.fromFields(allocator, &.{.{ .key = "timestamp", .value = .{ .number = @floatFromInt(timestamp) } }});
}

//
// Number of records in the create, update and build scenarios (generate.ts SCENARIO_RECORD_COUNT).
//
const SCENARIO_RECORD_COUNT = 2000;

//
// Number of records in the large scenario (generate.ts LARGE_RECORD_COUNT).
//
const LARGE_RECORD_COUNT = 93000;

//
// Creates a new database over a storage.
//
fn openDatabase(allocator: std.mem.Allocator, storage: *MemoryStorage, uuidGenerator: *TestUuidGenerator) !*BsonDatabase {
    return BsonDatabase.init(allocator, storage.asStorage(), ".db/bson", uuidGenerator.uuidGenerator(), test_clock.timestamp_provider.timestampProvider());
}

//
// Builds a scenario record.
//
fn makeRecord(allocator: std.mem.Allocator, id: []const u8, index: i64, variant: i64, timestamp: i64) !IInternalRecord {
    return .{
        ._id = id,
        .fields = try makeFields(allocator, index, variant),
        .metadata = try makeMetadata(allocator, timestamp),
    };
}

//
// Builds a record whose only fields are an increasing hash (and optionally n), like the leaves and large scenarios.
//
fn makeHashRecord(allocator: std.mem.Allocator, id: []const u8, index: i64, withNumber: bool) !IInternalRecord {
    var fields: BsonDocument = .empty;
    try fields.put(allocator, "hash", .{ .string = try std.fmt.allocPrint(allocator, "h{d:0>8}", .{@as(u64, @intCast(index))}) });
    if (withNumber) {
        try fields.put(allocator, "n", .{ .number = @floatFromInt(index) });
    }
    return .{ ._id = id, .fields = fields, .metadata = .empty };
}

//
// Appends the leaves of a sort tree in order.
//
fn collectLeaves(allocator: std.mem.Allocator, node: ?*SortNode, leaves: *std.ArrayList(*SortNode)) !void {
    const current = node orelse {
        return;
    };
    if (current.nodeCount == 1) {
        try leaves.append(allocator, current);
        return;
    }
    try collectLeaves(allocator, current.left, leaves);
    try collectLeaves(allocator, current.right, leaves);
}

//
// Converts a JSON number to an integer.
//
fn jsonInteger(value: std.json.Value) i64 {
    return switch (value) {
        .integer => |integer| integer,
        .float => |float| @intFromFloat(float),
        else => unreachable,
    };
}

//
// Checks a merkle tree file against the summary generate.ts recorded when it loaded the TypeScript file.
//
fn expectTreeMatches(allocator: std.mem.Allocator, storage: *MemoryStorage, filePath: []const u8, typeCode: []const u8, expected: std.json.Value) !void {
    const tree = (try merkle_tree_zig.merkle_tree.loadTree(allocator, io, filePath, storage.asStorage(), typeCode)).?;
    try std.testing.expectEqualStrings(expected.object.get("id").?.string, tree.id);
    try std.testing.expectEqual(jsonInteger(expected.object.get("version").?), @as(i64, tree.version));

    var leaves: std.ArrayList(*SortNode) = .empty;
    try collectLeaves(allocator, tree.sort, &leaves);
    var json: std.Io.Writer.Allocating = .init(allocator);
    try json.writer.writeAll("[");
    for (leaves.items, 0..) |leaf, leafIndex| {
        if (leafIndex > 0) {
            try json.writer.writeAll(",");
        }
        try json.writer.writeAll("[");
        try js_value.writeJsonString(&json.writer, leaf.name.?);
        try json.writer.print(",\"{x}\",{d}]", .{ leaf.contentHash.?, leaf.size });
    }
    try json.writer.writeAll("]");
    try std.testing.expectEqual(jsonInteger(expected.object.get("leafCount").?), @as(i64, @intCast(leaves.items.len)));
    std.testing.expectEqualStrings(expected.object.get("leavesSha256").?.string, try sha256Hex(allocator, json.written())) catch |err| {
        std.debug.print("merkle tree leaves differ: {s}\n{s}\n", .{ filePath, json.written() });
        return err;
    };

    const expectedMerkleHash = expected.object.get("merkleHash").?;
    if (expectedMerkleHash == .null) {
        try std.testing.expect(tree.merkle == null);
    }
    else {
        const actualHash = try std.fmt.allocPrint(allocator, "{x}", .{tree.merkle.?.hash});
        try std.testing.expectEqualStrings(expectedMerkleHash.string, actualHash);
        try std.testing.expectEqual(jsonInteger(expected.object.get("merkleNodeCount").?), @as(i64, tree.merkle.?.nodeCount));
    }
}

//
// Sort predicate for paths.
//
fn pathLessThan(context: void, left: []const u8, right: []const u8) bool {
    _ = context;
    return std.mem.lessThan(u8, left, right);
}

//
// Checks every file of the storage against the scenario fixture and returns the parsed fixture.
//
fn expectMatchesSnapshot(allocator: std.mem.Allocator, storage: *MemoryStorage, fixtureName: []const u8) !std.json.Value {
    const fixture = try fixtures.readJsonFixture(allocator, io, fixtureName);
    const expectedFiles = fixture.object.get("files").?.array.items;
    const trees = fixture.object.get("trees").?.object;

    const actualPaths = try allocator.dupe([]const u8, storage.files.keys());
    std.mem.sort([]const u8, actualPaths, {}, pathLessThan);
    for (expectedFiles, 0..) |expectedFile, fileIndex| {
        const expectedPath = expectedFile.object.get("path").?.string;
        if (fileIndex >= actualPaths.len or !std.mem.eql(u8, expectedPath, actualPaths[fileIndex])) {
            std.debug.print("{s}: expected file {s}, found {s}\n", .{ fixtureName, expectedPath, if (fileIndex < actualPaths.len) actualPaths[fileIndex] else "(none)" });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(expectedFiles.len, actualPaths.len);

    var mismatches: usize = 0;
    for (expectedFiles) |expectedFile| {
        const filePath = expectedFile.object.get("path").?.string;
        const data = storage.getFile(filePath).?;
        if (trees.get(filePath)) |expectedTree| {
            expectTreeMatches(allocator, storage, filePath, data[4..8], expectedTree) catch |err| {
                std.debug.print("{s}: merkle tree {s} differs\n", .{ fixtureName, filePath });
                return err;
            };
            continue;
        }
        const actualSha = try sha256Hex(allocator, data);
        if (!std.mem.eql(u8, expectedFile.object.get("sha256").?.string, actualSha) or jsonInteger(expectedFile.object.get("size").?) != @as(i64, @intCast(data.len))) {
            if (mismatches < 10) {
                std.debug.print("{s}: file {s} differs (size {d}, expected {d})\n", .{ fixtureName, filePath, data.len, jsonInteger(expectedFile.object.get("size").?) });
            }
            mismatches += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);

    const rootHash = fixture.object.get("rootHash").?;
    const databaseTree = try bdb.merkle_tree.loadDatabaseMerkleTree(allocator, io, storage.asStorage(), ".db/bson");
    if (rootHash == .null) {
        try std.testing.expect(databaseTree == null or databaseTree.?.merkle == null);
    }
    else {
        try std.testing.expectEqualStrings(rootHash.string, try std.fmt.allocPrint(allocator, "{x}", .{databaseTree.?.merkle.?.hash}));
    }
    return fixture;
}

//
// Ensures the media file database sort indexes (node-api's ensureSortIndex).
//
fn ensureMediaSortIndexes(collection: *bdb.collection.BsonCollection) !void {
    try (try collection.sortIndex("hash", .asc)).ensure(io, collection, .string);
    try (try collection.sortIndex("photoDate", .desc)).ensure(io, collection, .date);
}

test "scenario create: sort indexes ensured on an empty collection, then records set and committed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var uuidGenerator: TestUuidGenerator = .{};
    var recordIdGenerator: TestUuidGenerator = .{};
    var ids: std.ArrayList([]const u8) = .empty;

    const database = try openDatabase(allocator, &storage, &uuidGenerator);
    const collection = try database.collection("metadata");
    try ensureMediaSortIndexes(collection);
    var index: i64 = 0;
    while (index < SCENARIO_RECORD_COUNT) : (index += 1) {
        try ids.append(allocator, try recordIdGenerator.generate(allocator));
        try collection.setInternalRecord(io, try makeRecord(allocator, ids.items[@intCast(index)], index, 0, 1700000000000 + index));
    }
    try database.commit(io);
    _ = try expectMatchesSnapshot(allocator, &storage, "scenario-create.json");

    // Scenario update: a new database instance over the same storage, continuing the same uuid generators.
    const updateDatabase = try openDatabase(allocator, &storage, &uuidGenerator);
    const updateCollection = try updateDatabase.collection("metadata");
    index = 0;
    while (index < SCENARIO_RECORD_COUNT) : (index += 1) {
        if (@mod(index, 3) == 0) {
            try updateCollection.setInternalRecord(io, try makeRecord(allocator, ids.items[@intCast(index)], index, 1, 1800000000000 + index));
        }
    }
    index = 0;
    while (index < SCENARIO_RECORD_COUNT) : (index += 1) {
        if (index < 1000 or (@mod(index, 3) != 0 and index < 1400)) {
            _ = try updateCollection.deleteOne(io, ids.items[@intCast(index)]);
        }
    }
    index = SCENARIO_RECORD_COUNT;
    while (index < SCENARIO_RECORD_COUNT + 300) : (index += 1) {
        try ids.append(allocator, try recordIdGenerator.generate(allocator));
        try updateCollection.setInternalRecord(io, try makeRecord(allocator, ids.items[@intCast(index)], index, 0, 1700000000000 + index));
    }
    try updateDatabase.commit(io);
    _ = try expectMatchesSnapshot(allocator, &storage, "scenario-update.json");
}

test "scenario build: sort indexes built from existing shards" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var uuidGenerator: TestUuidGenerator = .{};
    var recordIdGenerator: TestUuidGenerator = .{};

    const database = try openDatabase(allocator, &storage, &uuidGenerator);
    const collection = try database.collection("metadata");
    var index: i64 = 0;
    while (index < SCENARIO_RECORD_COUNT) : (index += 1) {
        try collection.setInternalRecord(io, try makeRecord(allocator, try recordIdGenerator.generate(allocator), index, 0, 1700000000000 + index));
    }
    try database.commit(io);

    const buildDatabase = try openDatabase(allocator, &storage, &uuidGenerator);
    const buildCollection = try buildDatabase.collection("metadata");
    try ensureMediaSortIndexes(buildCollection);
    try buildDatabase.commit(io);
    _ = try expectMatchesSnapshot(allocator, &storage, "scenario-build.json");
}

test "scenario existing: records updated, deleted and added in the 50-assets test database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try storage.loadDirectory(io, fixtures.TEST_DBS_DIR ++ "/50-assets/.db/bson", ".db/bson");
    var uuidGenerator: TestUuidGenerator = .{};
    var recordIdGenerator: TestUuidGenerator = .{};
    const database = try openDatabase(allocator, &storage, &uuidGenerator);
    const collection = try database.collection("metadata");

    var records: std.ArrayList(IInternalRecord) = .empty;
    var iterator = collection.iterateRecords();
    while (try iterator.next(io)) |record| {
        try records.append(allocator, record);
    }
    for (records.items, 0..) |record, recordIndex| {
        const index: i64 = @intCast(recordIndex);
        if (@mod(index, 4) == 0) {
            // { ...record.fields, hash }: a copy of the fields with the hash replaced in place.
            var fields: BsonDocument = .empty;
            try fields.fields.appendSlice(allocator, record.fields.fields.items);
            try fields.put(allocator, "hash", .{ .string = try sha256Hex(allocator, try std.fmt.allocPrint(allocator, "changed-{d}", .{index})) });
            try collection.setInternalRecord(io, .{ ._id = record._id, .fields = fields, .metadata = record.metadata });
        }
        else if (@mod(index, 4) == 1) {
            var fields: BsonDocument = .empty;
            try fields.fields.appendSlice(allocator, record.fields.fields.items);
            try fields.put(allocator, "photoDate", .{ .date = BASE_TIME + index * 86400000 });
            try collection.setInternalRecord(io, .{ ._id = record._id, .fields = fields, .metadata = record.metadata });
        }
        else if (@mod(index, 4) == 2 and index < 20) {
            _ = try collection.deleteOne(io, record._id);
        }
    }
    var newIndex: i64 = 0;
    while (newIndex < 5) : (newIndex += 1) {
        try collection.setInternalRecord(io, try makeRecord(allocator, try recordIdGenerator.generate(allocator), newIndex, 0, 1700000000000 + newIndex));
    }
    try database.commit(io);
    _ = try expectMatchesSnapshot(allocator, &storage, "scenario-existing.json");
}

test "scenario leaves: deleting the first leaf of a sort index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var uuidGenerator: TestUuidGenerator = .{};
    var recordIdGenerator: TestUuidGenerator = .{};
    var ids: std.ArrayList([]const u8) = .empty;

    const database = try openDatabase(allocator, &storage, &uuidGenerator);
    const collection = try database.collection("metadata");
    try (try collection.sortIndex("hash", .asc)).ensure(io, collection, .string);
    var index: i64 = 0;
    while (index < 1600) : (index += 1) {
        try ids.append(allocator, try recordIdGenerator.generate(allocator));
        try collection.setInternalRecord(io, try makeHashRecord(allocator, ids.items[@intCast(index)], index, true));
    }
    try database.commit(io);

    const updateDatabase = try openDatabase(allocator, &storage, &uuidGenerator);
    const updateCollection = try updateDatabase.collection("metadata");
    index = 0;
    while (index < 800) : (index += 1) {
        _ = try updateCollection.deleteOne(io, ids.items[@intCast(index)]);
    }
    index = 1600;
    while (index < 1650) : (index += 1) {
        try ids.append(allocator, try recordIdGenerator.generate(allocator));
        try updateCollection.setInternalRecord(io, try makeHashRecord(allocator, ids.items[@intCast(index)], index, true));
    }
    try updateDatabase.commit(io);
    _ = try expectMatchesSnapshot(allocator, &storage, "scenario-leaves.json");
}

test "scenario large: enough leaf splits to split the root internal node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var uuidGenerator: TestUuidGenerator = .{};
    var recordIdGenerator: TestUuidGenerator = .{};

    const database = try openDatabase(allocator, &storage, &uuidGenerator);
    const collection = try database.collection("metadata");
    const sortIndex = try collection.sortIndex("hash", .asc);
    try sortIndex.ensure(io, collection, .string);
    var records: std.ArrayList(IInternalRecord) = .empty;
    var index: i64 = 0;
    while (index < LARGE_RECORD_COUNT) : (index += 1) {
        try records.append(allocator, try makeHashRecord(allocator, try recordIdGenerator.generate(allocator), index, false));
        try sortIndex.addRecord(io, records.items[@intCast(index)]);
    }
    index = 0;
    while (index < 2100) : (index += 7) {
        var fields: BsonDocument = .empty;
        try fields.put(allocator, "hash", .{ .string = try std.fmt.allocPrint(allocator, "g{d:0>8}", .{@as(u64, @intCast(index))}) });
        const updated: IInternalRecord = .{ ._id = records.items[@intCast(index)]._id, .fields = fields, .metadata = .empty };
        try sortIndex.updateRecord(io, updated, records.items[@intCast(index)]);
        records.items[@intCast(index)] = updated;
    }
    index = 5000;
    while (index < 6000) : (index += 1) {
        const record = records.items[@intCast(index)];
        try sortIndex.deleteRecord(io, record._id, record);
    }
    try sortIndex.commit(io);
    const rootNode = sortIndex.treeNodes.get(sortIndex.rootPageId.?).?;
    try std.testing.expectEqual(@as(usize, 2), rootNode.children.items.len);
    _ = try expectMatchesSnapshot(allocator, &storage, "scenario-large.json");
}
