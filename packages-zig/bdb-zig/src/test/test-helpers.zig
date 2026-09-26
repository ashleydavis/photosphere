const std = @import("std");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const bdb = @import("bdb-zig");
const bson = serialization_zig.bson;
const BsonValue = bson.BsonValue;
const BsonDocument = bson.BsonDocument;
const js_value = bdb.js_value;
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// The directory holding the golden fixtures (tests run with the package directory as cwd).
//
pub const FIXTURES_DIR = "src/test/fixtures";

//
// The directory holding the checked in test databases.
//
pub const TEST_DBS_DIR = "../../test/dbs";

//
// Reads a fixture file.
//
pub fn readFixture(allocator: std.mem.Allocator, io: std.Io, name: []const u8) ![]u8 {
    const fixturePath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ FIXTURES_DIR, name });
    return std.Io.Dir.cwd().readFileAlloc(io, fixturePath, allocator, .unlimited);
}

//
// Reads and parses a JSON fixture file.
//
pub fn readJsonFixture(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !std.json.Value {
    const text = try readFixture(allocator, io, name);
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

//
// Hex SHA-256 of some bytes.
//
pub fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

//
// The time the scenario dates are based on (generate.ts BASE_TIME: Date.UTC(2020, 0, 1)).
//
pub const BASE_TIME: i64 = 1577836800000;

//
// Builds the fields of scenario record `index` exactly like generate.ts makeFields (same keys in the same order).
//
pub fn makeFields(allocator: std.mem.Allocator, index: i64, variant: i64) !BsonDocument {
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
    const tags = try allocator.alloc(BsonValue, 2);
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
pub fn makeMetadata(allocator: std.mem.Allocator, timestamp: i64) !BsonDocument {
    return BsonDocument.fromFields(allocator, &.{.{ .key = "timestamp", .value = .{ .number = @floatFromInt(timestamp) } }});
}

//
// A timestamp provider for tests (the real clock; bdb only passes it through).
//
pub var timestamp_provider: utils.timestamp_provider.TimestampProvider = .{};

//
// Returns the record ids of a sort index in page order (a stand in for walking getPage, which is not ported), reading
// the leaves from the leaf cache or from storage.
//
pub fn walkSortIndex(allocator: std.mem.Allocator, io: std.Io, sortIndex: *bdb.sort_index.SortIndex) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    var currentId = sortIndex.rootPageId orelse {
        return ids.items;
    };
    var node = sortIndex.treeNodes.get(currentId).?;
    while (node.children.items.len > 0) {
        currentId = node.children.items[0];
        node = sortIndex.treeNodes.get(currentId).?;
    }
    while (true) {
        if (sortIndex.leafCache.get(currentId)) |cached| {
            for (cached.records.items) |entry| {
                try ids.append(allocator, entry._id);
            }
        }
        else {
            // Leaf pages are loaded through findByValue, which caches every leaf it reads.
            _ = try sortIndex.findByValue(io, .{ .string = "\x00never-matches" }, null);
            if (sortIndex.leafCache.get(currentId)) |loaded| {
                for (loaded.records.items) |entry| {
                    try ids.append(allocator, entry._id);
                }
            }
        }
        const nextLeaf = node.nextLeaf orelse {
            break;
        };
        currentId = nextLeaf;
        node = sortIndex.treeNodes.get(currentId).?;
    }
    return ids.items;
}

//
// Returns the values of a sort index in page order.
//
pub fn sortIndexValues(allocator: std.mem.Allocator, io: std.Io, sortIndex: *bdb.sort_index.SortIndex) ![]const BsonValue {
    _ = try walkSortIndex(allocator, io, sortIndex);
    var values: std.ArrayList(BsonValue) = .empty;
    var currentId = sortIndex.rootPageId orelse {
        return values.items;
    };
    var node = sortIndex.treeNodes.get(currentId).?;
    while (node.children.items.len > 0) {
        currentId = node.children.items[0];
        node = sortIndex.treeNodes.get(currentId).?;
    }
    while (true) {
        if (sortIndex.leafCache.get(currentId)) |cached| {
            for (cached.records.items) |entry| {
                try values.append(allocator, entry.value);
            }
        }
        const nextLeaf = node.nextLeaf orelse {
            break;
        };
        currentId = nextLeaf;
        node = sortIndex.treeNodes.get(currentId).?;
    }
    return values.items;
}
