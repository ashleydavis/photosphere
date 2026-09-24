//
// Tests for binary serialization and deserialization with versioning support.
//

const std = @import("std");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const memory_storage = @import("memory-storage.zig");
const serialization = serialization_zig.serialization;
const bson = serialization_zig.bson;
const errors = utils.errors;
const MemoryStorage = memory_storage.MemoryStorage;
const BinarySerializer = serialization.BinarySerializer;
const BinaryDeserializer = serialization.BinaryDeserializer;
const ISerializer = serialization.ISerializer;
const IDeserializer = serialization.IDeserializer;
const BsonDocument = bson.BsonDocument;
const BsonValue = bson.BsonValue;
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// The Io used by the tests.
//
const io = std.testing.io;

//
// Test data types and serializers
//
const TestDataV1 = struct {
    // A name.
    name: []const u8,

    // A number.
    value: i64,
};

//
// Version 2 test data (adds a description).
//
const TestDataV2 = struct {
    // A name.
    name: []const u8,

    // A number.
    value: i64,

    // A description.
    description: []const u8,
};

//
// Version 3 test data (adds tags).
//
const TestDataV3 = struct {
    // A name.
    name: []const u8,

    // A number.
    value: i64,

    // A description.
    description: []const u8,

    // Tags.
    tags: []const []const u8,
};

//
// What the deserializers return for any version (TypeScript: TestDataV1 | TestDataV2 | TestDataV3).
//
const TestData = struct {
    // A name.
    name: []const u8,

    // A number.
    value: i64,

    // A description (v2 and later).
    description: ?[]const u8 = null,

    // Tags (v3 and later).
    tags: ?[]const []const u8 = null,
};

//
// Serializer and deserializer functions that write data as a JSON string (like JSON.stringify/JSON.parse in the TS tests).
//
fn Json(comptime T: type) type {
    return struct {
        //
        // Writes data as a JSON string.
        //
        fn serialize(allocator: std.mem.Allocator, data: T, serializer: ISerializer) anyerror!void {
            const json = try std.json.Stringify.valueAlloc(allocator, data, .{});
            try serializer.writeString(json);
        }

        //
        // Reads data from a JSON string.
        //
        fn deserialize(allocator: std.mem.Allocator, context: void, deserializer: IDeserializer) anyerror!TestData {
            _ = context;
            const json_string = try deserializer.readString();
            return std.json.parseFromSliceLeaky(TestData, allocator, json_string, .{});
        }
    };
}

//
// Serializer functions for different versions
//
const serializeV1 = Json(TestDataV1).serialize;
const serializeV2 = Json(TestDataV2).serialize;
const serializeV3 = Json(TestDataV3).serialize;

//
// Deserializer functions for different versions
//
const deserializeV1 = Json(TestDataV1).deserialize;
const deserializeV2 = Json(TestDataV2).deserialize;
const deserializeV3 = Json(TestDataV3).deserialize;

//
// A deserializer map entry for the test data.
//
const Entry = serialization.DeserializerEntry(TestData, void);

//
// Checks that two strings are equal.
//
fn expectString(expected: []const u8, actual: []const u8) !void {
    try std.testing.expectEqualStrings(expected, actual);
}

//
// Checks that the loaded data equals the expected data.
//
fn expectTestData(expected: TestData, actual: ?TestData) !void {
    const loaded = actual orelse {
        return error.TestExpectedData;
    };
    try expectString(expected.name, loaded.name);
    try std.testing.expectEqual(expected.value, loaded.value);
    if (expected.description) |description| {
        try expectString(description, loaded.description.?);
    }
    else {
        try std.testing.expect(loaded.description == null);
    }
    if (expected.tags) |tags| {
        try std.testing.expectEqual(tags.len, loaded.tags.?.len);
        for (tags, loaded.tags.?) |tag, loaded_tag| {
            try expectString(tag, loaded_tag);
        }
    }
    else {
        try std.testing.expect(loaded.tags == null);
    }
}

//
// Checks that a call failed with error.Thrown and a message containing the given text.
//
fn expectThrownContaining(result: anytype, text: []const u8) !void {
    if (result) |_| {
        return error.TestExpectedError;
    }
    else |err| {
        try std.testing.expectEqual(error.Thrown, err);
        if (std.mem.indexOf(u8, errors.lastErrorMessage(), text) == null) {
            std.debug.print("message '{s}' does not contain '{s}'\n", .{ errors.lastErrorMessage(), text });
            return error.TestUnexpectedMessage;
        }
    }
}

//
// Reads a fixture file.
//
fn readFixture(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const fixture_path = try std.fmt.allocPrint(allocator, "src/test/fixtures/{s}", .{name});
    return std.Io.Dir.cwd().readFileAlloc(io, fixture_path, allocator, .unlimited);
}

// ---------------------------------------------------------------------------------------------------------------
// save function
// ---------------------------------------------------------------------------------------------------------------

test "should save data with version header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const data: TestDataV1 = .{ .name = "test", .value = 42 };
    const filePath = "test.bin";
    const version = 1;

    try serialization.save(allocator, io, &storage, filePath, data, version, "TEST", serializeV1);

    const savedBuffer = (try storage.read(allocator, io, filePath)).?;
    try std.testing.expect(savedBuffer.len > 40); // Version (4) + type (4) + data + checksum (32)

    // Check version header
    try std.testing.expectEqual(@as(u32, version), std.mem.readInt(u32, savedBuffer[0..4], .little));
    try expectString("TEST", savedBuffer[4..8]);

    // Check checksum footer exists (32 bytes for SHA-256)
    const savedChecksum = savedBuffer[savedBuffer.len - 32 ..];
    try std.testing.expectEqual(@as(usize, 32), savedChecksum.len);

    // Check payload (after version and type)
    var deserializer = BinaryDeserializer.init(allocator, savedBuffer[8 .. savedBuffer.len - 32]);
    const deserializedData = try std.json.parseFromSliceLeaky(TestData, allocator, try deserializer.readString(), .{});
    try expectTestData(.{ .name = "test", .value = 42 }, deserializedData);
}

test "should handle different data types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const Serializers = struct {
        fn stringSerializer(_: std.mem.Allocator, data: []const u8, serializer: ISerializer) anyerror!void {
            try serializer.writeString(data);
        }
        fn numberSerializer(_: std.mem.Allocator, data: i32, serializer: ISerializer) anyerror!void {
            try serializer.writeInt32(data);
        }
    };
    const objectData = try BsonDocument.fromFields(allocator, &.{.{ .key = "foo", .value = .{ .string = "bar" } }});
    const ObjectSerializer = struct {
        fn objectSerializer(_: std.mem.Allocator, data: BsonDocument, serializer: ISerializer) anyerror!void {
            try serializer.writeBSON(data);
        }
    };

    try serialization.save(allocator, io, &storage, "string.bin", @as([]const u8, "hello world"), 1, "TEST", Serializers.stringSerializer);
    try serialization.save(allocator, io, &storage, "number.bin", @as(i32, 12345), 2, "TEST", Serializers.numberSerializer);
    try serialization.save(allocator, io, &storage, "object.bin", objectData, 3, "TEST", ObjectSerializer.objectSerializer);

    try std.testing.expect(storage.fileExists("string.bin"));
    try std.testing.expect(storage.fileExists("number.bin"));
    try std.testing.expect(storage.fileExists("object.bin"));
}

test "should handle large version numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const data: TestDataV1 = .{ .name = "test", .value = 42 };
    const largeVersion: u32 = 0xFFFFFFFF; // Maximum 32-bit unsigned integer

    try serialization.save(allocator, io, &storage, "large-version.bin", data, largeVersion, "TEST", serializeV1);

    const savedBuffer = (try storage.read(allocator, io, "large-version.bin")).?;
    try std.testing.expectEqual(largeVersion, std.mem.readInt(u32, savedBuffer[0..4], .little));
}

test "save throws when the type code is not 4 characters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const data: TestDataV1 = .{ .name = "test", .value = 42 };
    try expectThrownContaining(serialization.save(allocator, io, &storage, "bad.bin", data, 1, "TOOLONG", serializeV1), "Type code must be exactly 4 ASCII characters, got \"TOOLONG\" (length 7)");
}

test "save output matches TypeScript save (golden fixture)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const data: TestDataV1 = .{ .name = "test", .value = 42 };
    try serialization.save(allocator, io, &storage, "save.bin", data, 1, "TEST", serializeV1);

    const expected = try readFixture(allocator, "save-v6.bin");
    const actual = (try storage.read(allocator, io, "save.bin")).?;
    try std.testing.expectEqualSlices(u8, expected, actual);
}

// ---------------------------------------------------------------------------------------------------------------
// load function
// ---------------------------------------------------------------------------------------------------------------

test "should load data using correct deserializer based on version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const dataV1: TestDataV1 = .{ .name = "test", .value = 42 };
    const dataV2: TestDataV2 = .{ .name = "test", .value = 42, .description = "a test object" };

    const deserializers = [_]Entry{
        .{ .version = 1, .deserializer = deserializeV1 },
        .{ .version = 2, .deserializer = deserializeV2 },
    };

    // Save v1 data
    try serialization.save(allocator, io, &storage, "data-v1.bin", dataV1, 1, "TEST", serializeV1);
    // Save v2 data
    try serialization.save(allocator, io, &storage, "data-v2.bin", dataV2, 2, "TEST", serializeV2);

    // Load and verify v1 data
    const loadedV1 = try serialization.load(TestData, allocator, io, &storage, "data-v1.bin", "TEST", {}, &deserializers);
    try expectTestData(.{ .name = "test", .value = 42 }, loadedV1);

    // Load and verify v2 data
    const loadedV2 = try serialization.load(TestData, allocator, io, &storage, "data-v2.bin", "TEST", {}, &deserializers);
    try expectTestData(.{ .name = "test", .value = 42, .description = "a test object" }, loadedV2);
}

test "should throw UnsupportedVersionError for unknown version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const data: TestDataV3 = .{
        .name = "test",
        .value = 42,
        .description = "a test object",
        .tags = &.{ "tag1", "tag2" },
    };

    // Save with version 3
    try serialization.save(allocator, io, &storage, "data-v3.bin", data, 3, "TEST", serializeV3);

    // Try to load with deserializers that only support v1 and v2
    const deserializers = [_]Entry{
        .{ .version = 1, .deserializer = deserializeV1 },
        .{ .version = 2, .deserializer = deserializeV2 },
    };

    const result = serialization.load(TestData, allocator, io, &storage, "data-v3.bin", "TEST", {}, &deserializers);
    try expectThrownContaining(result, "No deserializer found for version 3");
    try expectString("UnsupportedVersionError", errors.lastErrorName());
    try expectString("No deserializer found for version 3 from file data-v3.bin. Available versions: 2, 1", errors.lastErrorMessage());
}

test "should throw error for empty or too small files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const deserializers = [_]Entry{
        .{ .version = 1, .deserializer = deserializeV1 },
    };

    // Test with completely empty file (hits minimum 4-byte check)
    try storage.write(allocator, io, "empty.bin", null, "");
    try expectThrownContaining(serialization.load(TestData, allocator, io, &storage, "empty.bin", "TEST", {}, &deserializers), "too small");
    try expectString("File 'empty.bin' is too small. File has 0 bytes, minimum 4.", errors.lastErrorMessage());

    // Test with file smaller than v6 minimum (40 bytes); treated as legacy and fails checksum
    try storage.write(allocator, io, "small.bin", null, &([_]u8{0} ** 39));
    try expectThrownContaining(serialization.load(TestData, allocator, io, &storage, "small.bin", "TEST", {}, &deserializers), "Checksum mismatch");
}

test "should return undefined for non-existent files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const deserializers = [_]Entry{
        .{ .version = 1, .deserializer = deserializeV1 },
    };

    const result = try serialization.load(TestData, allocator, io, &storage, "non-existent.bin", "TEST", {}, &deserializers);
    try std.testing.expect(result == null);
}

test "should handle files with minimal data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const Deserializers = struct {
        fn readString(_: std.mem.Allocator, _: void, deserializer: IDeserializer) anyerror![]const u8 {
            return deserializer.readString();
        }
    };
    const deserializers = [_]serialization.DeserializerEntry([]const u8, void){
        .{ .version = 1, .deserializer = Deserializers.readString },
    };

    // Create a file with v6 layout: version (4) + type (4) + payload + checksum (32)
    const dataWithVersionAndType = [_]u8{ 1, 0, 0, 0, 'T', 'E', 'S', 'T', 0, 0, 0, 0 };
    var checksum: [32]u8 = undefined;
    Sha256.hash(&dataWithVersionAndType, &checksum, .{});
    const fileBuffer = try std.mem.concat(allocator, u8, &.{ &dataWithVersionAndType, &checksum });

    try storage.write(allocator, io, "minimal.bin", null, fileBuffer);

    const result = try serialization.load([]const u8, allocator, io, &storage, "minimal.bin", "TEST", {}, &deserializers);
    try expectString("", result.?);
}

test "load passes the context to the deserializer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const Deserializers = struct {
        fn readWithOffset(_: std.mem.Allocator, offset: *const u32, deserializer: IDeserializer) anyerror!u32 {
            return offset.* + try deserializer.readUInt32();
        }
        fn writeValue(_: std.mem.Allocator, data: u32, serializer: ISerializer) anyerror!void {
            try serializer.writeUInt32(data);
        }
    };
    try serialization.save(allocator, io, &storage, "value.bin", @as(u32, 5), 1, "TEST", Deserializers.writeValue);

    const offset: u32 = 100;
    const deserializers = [_]serialization.DeserializerEntry(u32, *const u32){
        .{ .version = 1, .deserializer = Deserializers.readWithOffset },
    };
    const result = try serialization.load(u32, allocator, io, &storage, "value.bin", "TEST", &offset, &deserializers);
    try std.testing.expectEqual(@as(?u32, 105), result);
}

test "load reads legacy files with and without checksum (golden fixtures)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const deserializers = [_]Entry{
        .{ .version = 1, .deserializer = deserializeV1 },
    };

    try storage.write(allocator, io, "legacy-checksum.bin", null, try readFixture(allocator, "legacy-checksum.bin"));
    try storage.write(allocator, io, "legacy-no-checksum.bin", null, try readFixture(allocator, "legacy-no-checksum.bin"));
    try storage.write(allocator, io, "legacy-short.bin", null, try readFixture(allocator, "legacy-short.bin"));
    try storage.write(allocator, io, "save-v6.bin", null, try readFixture(allocator, "save-v6.bin"));

    try expectTestData(.{ .name = "legacy with checksum", .value = 1 }, try serialization.load(TestData, allocator, io, &storage, "legacy-checksum.bin", "TEST", {}, &deserializers));
    try expectTestData(.{ .name = "legacy without checksum", .value = 2 }, try serialization.load(TestData, allocator, io, &storage, "legacy-no-checksum.bin", "TEST", {}, &deserializers));
    try expectTestData(.{ .name = "test", .value = 42 }, try serialization.load(TestData, allocator, io, &storage, "save-v6.bin", "TEST", {}, &deserializers));

    const ShortDeserializer = struct {
        fn readShort(_: std.mem.Allocator, _: void, deserializer: IDeserializer) anyerror![]const u8 {
            return deserializer.readString();
        }
    };
    const shortDeserializers = [_]serialization.DeserializerEntry([]const u8, void){
        .{ .version = 1, .deserializer = ShortDeserializer.readShort },
    };
    const short = try serialization.load([]const u8, allocator, io, &storage, "legacy-short.bin", "TEST", {}, &shortDeserializers);
    try expectString("{\"a\":1}", short.?);
}

test "load of a v6 file with a different type code falls back to the legacy layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const data: TestDataV1 = .{ .name = "test", .value = 42 };
    try serialization.save(allocator, io, &storage, "other.bin", data, 1, "OTHR", serializeV1);

    // The checksum matches, so the legacy path reads [version][payload] where the payload starts with "OTHR".
    const deserializers = [_]Entry{
        .{ .version = 1, .deserializer = deserializeV1 },
    };
    try expectThrownContaining(serialization.load(TestData, allocator, io, &storage, "other.bin", "TEST", {}, &deserializers), "Cannot read");
}

// ---------------------------------------------------------------------------------------------------------------
// round-trip compatibility
// ---------------------------------------------------------------------------------------------------------------

test "should maintain data integrity across save/load cycles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const deserializers = [_]Entry{
        .{ .version = 1, .deserializer = deserializeV1 },
        .{ .version = 2, .deserializer = deserializeV2 },
        .{ .version = 3, .deserializer = deserializeV3 },
    };

    try serialization.save(allocator, io, &storage, "roundtrip-v1.bin", TestDataV1{ .name = "simple", .value = 123 }, 1, "TEST", serializeV1);
    try serialization.save(allocator, io, &storage, "roundtrip-v2.bin", TestDataV2{ .name = "complex", .value = 456, .description = "test description" }, 2, "TEST", serializeV2);
    try serialization.save(allocator, io, &storage, "roundtrip-v3.bin", TestDataV3{ .name = "full", .value = 789, .description = "full test", .tags = &.{ "a", "b", "c" } }, 3, "TEST", serializeV3);

    try expectTestData(.{ .name = "simple", .value = 123 }, try serialization.load(TestData, allocator, io, &storage, "roundtrip-v1.bin", "TEST", {}, &deserializers));
    try expectTestData(.{ .name = "complex", .value = 456, .description = "test description" }, try serialization.load(TestData, allocator, io, &storage, "roundtrip-v2.bin", "TEST", {}, &deserializers));
    try expectTestData(.{ .name = "full", .value = 789, .description = "full test", .tags = &.{ "a", "b", "c" } }, try serialization.load(TestData, allocator, io, &storage, "roundtrip-v3.bin", "TEST", {}, &deserializers));
}

test "should handle special characters and binary data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const specialName = "🚀 Unicode test with émojis and spëcial chars; This contains null bytes: \x00\x01\x02\xc3\xbf";
    const data: TestDataV3 = .{ .name = specialName, .value = 9007199254740991, .description = "", .tags = &.{ "many levels", "" } };

    const deserializers = [_]Entry{
        .{ .version = 1, .deserializer = deserializeV3 },
    };

    try serialization.save(allocator, io, &storage, "special.bin", data, 1, "TEST", serializeV3);
    const loadedData = try serialization.load(TestData, allocator, io, &storage, "special.bin", "TEST", {}, &deserializers);

    try expectTestData(.{ .name = specialName, .value = 9007199254740991, .description = "", .tags = &.{ "many levels", "" } }, loadedData);
}

// ---------------------------------------------------------------------------------------------------------------
// checksum verification
// ---------------------------------------------------------------------------------------------------------------

test "should detect corrupted data with checksum mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const deserializers = [_]Entry{
        .{ .version = 1, .deserializer = deserializeV1 },
    };

    // Save valid data
    try serialization.save(allocator, io, &storage, "valid.bin", TestDataV1{ .name = "test", .value = 42 }, 1, "TEST", serializeV1);

    const corruptedBuffer = (try storage.read(allocator, io, "valid.bin")).?;
    if (corruptedBuffer.len > 12) {
        corruptedBuffer[8] = corruptedBuffer[8] ^ 0xFF;
    }

    try storage.write(allocator, io, "corrupted.bin", null, corruptedBuffer);

    try expectThrownContaining(serialization.load(TestData, allocator, io, &storage, "corrupted.bin", "TEST", {}, &deserializers), "Checksum mismatch");
}

test "should detect corrupted checksum header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const deserializers = [_]Entry{
        .{ .version = 1, .deserializer = deserializeV1 },
    };

    try serialization.save(allocator, io, &storage, "valid.bin", TestDataV1{ .name = "test", .value = 42 }, 1, "TEST", serializeV1);

    const corruptedBuffer = (try storage.read(allocator, io, "valid.bin")).?;
    var badChecksum: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&badChecksum, "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef");
    @memcpy(corruptedBuffer[corruptedBuffer.len - 32 ..], &badChecksum);

    try storage.write(allocator, io, "bad-checksum.bin", null, corruptedBuffer);

    try expectThrownContaining(serialization.load(TestData, allocator, io, &storage, "bad-checksum.bin", "TEST", {}, &deserializers), "Checksum mismatch");
}

test "should show exact checksum values in error message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const deserializers = [_]Entry{
        .{ .version = 1, .deserializer = deserializeV1 },
    };

    try serialization.save(allocator, io, &storage, "valid.bin", TestDataV1{ .name = "test", .value = 42 }, 1, "TEST", serializeV1);

    const corruptedBuffer = (try storage.read(allocator, io, "valid.bin")).?;
    var badChecksum: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&badChecksum, "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef");
    @memcpy(corruptedBuffer[corruptedBuffer.len - 32 ..], &badChecksum);

    try storage.write(allocator, io, "bad-checksum.bin", null, corruptedBuffer);

    try expectThrownContaining(serialization.load(TestData, allocator, io, &storage, "bad-checksum.bin", "TEST", {}, &deserializers), "Checksum mismatch");

    // Verify it contains the expected and actual checksums in hex (32-byte format)
    var calculated: [32]u8 = undefined;
    Sha256.hash(corruptedBuffer[0 .. corruptedBuffer.len - 32], &calculated, .{});
    const expectedMessage = try std.fmt.allocPrint(allocator, "Checksum mismatch: expected 1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef, got {x}", .{&calculated});
    try expectString(expectedMessage, errors.lastErrorMessage());
}

// ---------------------------------------------------------------------------------------------------------------
// error handling
// ---------------------------------------------------------------------------------------------------------------

test "should handle serializer errors gracefully" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const Serializers = struct {
        fn badSerializer(_: std.mem.Allocator, _: TestDataV1, _: ISerializer) anyerror!void {
            return errors.throwError("Serializer error", .{});
        }
    };

    try expectThrownContaining(serialization.save(allocator, io, &storage, "bad.bin", TestDataV1{ .name = "data", .value = 1 }, 1, "TEST", Serializers.badSerializer), "Serializer error");
    try std.testing.expect(!storage.fileExists("bad.bin"));
}

test "should handle deserializer errors gracefully" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const Functions = struct {
        fn goodSerializer(_: std.mem.Allocator, data: []const u8, serializer: ISerializer) anyerror!void {
            try serializer.writeString(data);
        }
        fn badDeserializer(_: std.mem.Allocator, _: void, _: IDeserializer) anyerror![]const u8 {
            return errors.throwError("Deserializer error", .{});
        }
    };

    // Save valid data
    try serialization.save(allocator, io, &storage, "good-data.bin", @as([]const u8, "test"), 1, "TEST", Functions.goodSerializer);

    const deserializers = [_]serialization.DeserializerEntry([]const u8, void){
        .{ .version = 1, .deserializer = Functions.badDeserializer },
    };

    try expectThrownContaining(serialization.load([]const u8, allocator, io, &storage, "good-data.bin", "TEST", {}, &deserializers), "Deserializer error");
}

// ---------------------------------------------------------------------------------------------------------------
// BSON serialization
// ---------------------------------------------------------------------------------------------------------------

test "should write and read BSON objects with type safety" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var serializer = try BinarySerializer.init(allocator, 1024);
    var array = [_]BsonValue{ .{ .number = 1 }, .{ .number = 2 }, .{ .number = 3 } };
    const nested = try BsonDocument.fromFields(allocator, &.{
        .{ .key = "array", .value = .{ .array = &array } },
        .{ .key = "bool", .value = .{ .boolean = true } },
    });
    const testObj = try BsonDocument.fromFields(allocator, &.{
        .{ .key = "name", .value = .{ .string = "test" } },
        .{ .key = "value", .value = .{ .number = 42 } },
        .{ .key = "nested", .value = .{ .document = nested } },
    });

    // Write BSON object
    try serializer.writeBSON(testObj);

    // Get buffer and create deserializer
    var deserializer = BinaryDeserializer.init(allocator, serializer.getBuffer());

    // Read BSON object back
    const result = try deserializer.readBSON();

    try std.testing.expect(result.eql(testObj));
    try expectString("test", result.get("name").?.string);
    try std.testing.expectEqual(@as(f64, 42), result.get("value").?.number);
}

test "should handle multiple BSON objects in sequence with different types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var serializer = try BinarySerializer.init(allocator, 1024);
    var data = [_]BsonValue{ .{ .number = 1 }, .{ .number = 2 }, .{ .number = 3 } };
    const obj1 = try BsonDocument.fromFields(allocator, &.{
        .{ .key = "id", .value = .{ .number = 1 } },
        .{ .key = "name", .value = .{ .string = "first" } },
    });
    const obj2 = try BsonDocument.fromFields(allocator, &.{
        .{ .key = "id", .value = .{ .number = 2 } },
        .{ .key = "name", .value = .{ .string = "second" } },
        .{ .key = "data", .value = .{ .array = &data } },
    });
    const deep = try BsonDocument.fromFields(allocator, &.{.{ .key = "deep", .value = .{ .string = "value" } }});
    const nested = try BsonDocument.fromFields(allocator, &.{.{ .key = "nested", .value = .{ .document = deep } }});
    const obj3 = try BsonDocument.fromFields(allocator, &.{
        .{ .key = "id", .value = .{ .number = 3 } },
        .{ .key = "complex", .value = .{ .document = nested } },
    });

    // Write multiple BSON objects
    try serializer.writeBSON(obj1);
    try serializer.writeBSON(obj2);
    try serializer.writeBSON(obj3);

    var deserializer = BinaryDeserializer.init(allocator, serializer.getBuffer());

    // Read objects back in order
    try std.testing.expect((try deserializer.readBSON()).eql(obj1));
    try std.testing.expect((try deserializer.readBSON()).eql(obj2));
    try std.testing.expect((try deserializer.readBSON()).eql(obj3));
}

test "should handle empty BSON objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var serializer = try BinarySerializer.init(allocator, 1024);
    try serializer.writeBSON(BsonDocument.empty);

    var deserializer = BinaryDeserializer.init(allocator, serializer.getBuffer());
    const result = try deserializer.readBSON();
    try std.testing.expectEqual(@as(usize, 0), result.count());
}

test "should handle BSON with special types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var serializer = try BinarySerializer.init(allocator, 1024);
    const specialObj = try BsonDocument.fromFields(allocator, &.{
        .{ .key = "date", .value = .{ .date = 1672531200000 } },
        .{ .key = "buffer", .value = .{ .binary = .{ .subType = 0, .data = "hello" } } },
        .{ .key = "null_value", .value = .null },
        .{ .key = "undefined_value", .value = .undefined },
        .{ .key = "number", .value = .{ .number = 3.14159 } },
        .{ .key = "bigNumber", .value = .{ .number = 9007199254740991 } },
    });

    try serializer.writeBSON(specialObj);

    var deserializer = BinaryDeserializer.init(allocator, serializer.getBuffer());
    const result = try deserializer.readBSON();

    try std.testing.expectEqual(@as(i64, 1672531200000), result.get("date").?.date);
    // BSON wraps Buffer in Binary type, so we need to check the underlying buffer
    try expectString("hello", result.get("buffer").?.binary.data);
    try std.testing.expect(result.get("null_value").? == .null);
    try std.testing.expectEqual(@as(f64, 3.14159), result.get("number").?.number);
    try std.testing.expectEqual(@as(f64, 9007199254740991), result.get("bigNumber").?.number);
    try std.testing.expect(result.get("undefined_value") == null);
}

test "should mix BSON with other data types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var serializer = try BinarySerializer.init(allocator, 1024);
    const bsonObj = try BsonDocument.fromFields(allocator, &.{
        .{ .key = "name", .value = .{ .string = "test" } },
        .{ .key = "value", .value = .{ .number = 42 } },
    });
    const stringData = "hello world";
    const numberData: i32 = 123;

    // Write mixed data
    try serializer.writeString(stringData);
    try serializer.writeBSON(bsonObj);
    try serializer.writeInt32(numberData);

    var deserializer = BinaryDeserializer.init(allocator, serializer.getBuffer());

    // Read back in same order
    try expectString(stringData, try deserializer.readString());
    try std.testing.expect((try deserializer.readBSON()).eql(bsonObj));
    try std.testing.expectEqual(numberData, try deserializer.readInt32());
}

test "should handle BSON serialization errors gracefully" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var serializer = try BinarySerializer.init(allocator, 1024);

    // A circular reference cannot be expressed with BsonDocument, so this uses the other object npm bson rejects: a key with a null byte.
    const badObj = try BsonDocument.fromFields(allocator, &.{.{ .key = "bad\x00key", .value = .{ .string = "test" } }});

    try expectThrownContaining(serializer.writeBSON(badObj), "must not contain null bytes");
}

test "should detect corrupted BSON data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var serializer = try BinarySerializer.init(allocator, 1024);
    const testObj = try BsonDocument.fromFields(allocator, &.{
        .{ .key = "name", .value = .{ .string = "test" } },
        .{ .key = "value", .value = .{ .number = 42 } },
    });

    try serializer.writeBSON(testObj);

    // Corrupt the BSON data (change length to be incorrect)
    const corruptedBuffer = try allocator.dupe(u8, serializer.getBuffer());
    std.mem.writeInt(u32, corruptedBuffer[0..4], 999, .little); // Write incorrect length

    var deserializer = BinaryDeserializer.init(allocator, corruptedBuffer);

    try expectThrownContaining(deserializer.readBSON(), "Cannot read 999 bytes");
}

// ---------------------------------------------------------------------------------------------------------------
// Migration system
// Not ported: the migration tests other than the one below (applyMigrations/findMigrationPath are not ported).
// ---------------------------------------------------------------------------------------------------------------

test "should work without migrations when versions match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    // Save v2 data
    try serialization.save(allocator, io, &storage, "data-v2.bin", TestDataV2{ .name = "test", .value = 42, .description = "v2 data" }, 2, "TEST", serializeV2);

    const deserializers = [_]Entry{
        .{ .version = 2, .deserializer = deserializeV2 },
    };

    const result = try serialization.load(TestData, allocator, io, &storage, "data-v2.bin", "TEST", {}, &deserializers);
    try expectTestData(.{ .name = "test", .value = 42, .description = "v2 data" }, result);
}

// ---------------------------------------------------------------------------------------------------------------
// checksum options
// ---------------------------------------------------------------------------------------------------------------

test "should enable checksum by default when options is undefined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const deserializers = [_]Entry{
        .{ .version = 1, .deserializer = deserializeV1 },
    };

    try serialization.save(allocator, io, &storage, "default.bin", TestDataV1{ .name = "test", .value = 42 }, 1, "TEST", serializeV1);

    const savedBuffer = (try storage.read(allocator, io, "default.bin")).?;
    try std.testing.expect(savedBuffer.len > 40); // Version (4) + type (4) + data + checksum (32)

    try expectTestData(.{ .name = "test", .value = 42 }, try serialization.load(TestData, allocator, io, &storage, "default.bin", "TEST", {}, &deserializers));
}

test "should always write v6 format with type and checksum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const deserializers = [_]Entry{
        .{ .version = 1, .deserializer = deserializeV1 },
    };

    try serialization.save(allocator, io, &storage, "v6-format.bin", TestDataV1{ .name = "test", .value = 42 }, 1, "TEST", serializeV1);

    const savedBuffer = (try storage.read(allocator, io, "v6-format.bin")).?;
    try std.testing.expect(savedBuffer.len >= 40);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, savedBuffer[0..4], .little));
    try expectString("TEST", savedBuffer[4..8]);

    try expectTestData(.{ .name = "test", .value = 42 }, try serialization.load(TestData, allocator, io, &storage, "v6-format.bin", "TEST", {}, &deserializers));
}

test "should maintain data integrity with checksum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const specialName = "🚀 Unicode test with émojis; Binary data: \x00\x01\x02\xc3\xbf";
    const deserializers = [_]Entry{
        .{ .version = 1, .deserializer = deserializeV3 },
    };

    try serialization.save(allocator, io, &storage, "special-checksum.bin", TestDataV3{ .name = specialName, .value = -1, .description = "deeply nested value", .tags = &.{"42"} }, 1, "TEST", serializeV3);
    const result = try serialization.load(TestData, allocator, io, &storage, "special-checksum.bin", "TEST", {}, &deserializers);

    try expectTestData(.{ .name = specialName, .value = -1, .description = "deeply nested value", .tags = &.{"42"} }, result);
}

// ---------------------------------------------------------------------------------------------------------------
// verify
// ---------------------------------------------------------------------------------------------------------------

test "should return valid: false for non-existent file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const result = try serialization.verify(allocator, io, &storage, "nonexistent.bin");
    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(@as(u64, 0), result.size);
    try expectString("File not found or empty", result.@"error".?);
}

test "should verify v6 file successfully" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    try serialization.save(allocator, io, &storage, "verify-checksum.bin", TestDataV1{ .name = "verify test", .value = 99 }, 1, "TEST", serializeV1);
    const result = try serialization.verify(allocator, io, &storage, "verify-checksum.bin");
    try std.testing.expect(result.valid);
    try std.testing.expect(result.size > 40);
    try std.testing.expect(result.@"error" == null);
}

test "should return valid: false when file is too small for v6 format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    try storage.write(allocator, io, "tiny.bin", null, &([_]u8{0} ** 10));
    const result = try serialization.verify(allocator, io, &storage, "tiny.bin");
    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(@as(u64, 10), result.size);
    try expectString("File too small for v6 format (10 bytes, minimum 40)", result.@"error".?);
}

test "should return valid: false on checksum mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    try serialization.save(allocator, io, &storage, "good-checksum.bin", TestDataV1{ .name = "verify test", .value = 99 }, 1, "TEST", serializeV1);
    const buffer = (try storage.read(allocator, io, "good-checksum.bin")).?;
    // Corrupt the last byte (checksum)
    buffer[buffer.len - 1] ^= 0xff;
    try storage.write(allocator, io, "corrupt-checksum.bin", null, buffer);
    const result = try serialization.verify(allocator, io, &storage, "corrupt-checksum.bin");
    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(@as(u64, buffer.len), result.size);
    try std.testing.expect(std.mem.startsWith(u8, result.@"error".?, "Checksum mismatch: expected "));
}

test "should report correct size for valid v6 file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    try serialization.save(allocator, io, &storage, "size-check.bin", TestDataV1{ .name = "verify test", .value = 99 }, 1, "TEST", serializeV1);
    const expectedBuffer = (try storage.read(allocator, io, "size-check.bin")).?;
    const result = try serialization.verify(allocator, io, &storage, "size-check.bin");
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(u64, expectedBuffer.len), result.size);
}

// ---------------------------------------------------------------------------------------------------------------
// loadVersion
// ---------------------------------------------------------------------------------------------------------------

test "loadVersion reads the version header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    try serialization.save(allocator, io, &storage, "versioned.bin", TestDataV1{ .name = "test", .value = 42 }, 6, "TEST", serializeV1);
    try std.testing.expectEqual(@as(?u32, 6), serialization.loadVersion(allocator, io, &storage, "versioned.bin"));
    try std.testing.expectEqual(@as(usize, 0), storage.openStreams);
}

test "loadVersion returns undefined for short or missing files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    try storage.write(allocator, io, "short.bin", null, &.{ 1, 2, 3 });
    try std.testing.expectEqual(@as(?u32, null), serialization.loadVersion(allocator, io, &storage, "short.bin"));
    try std.testing.expectEqual(@as(?u32, null), serialization.loadVersion(allocator, io, &storage, "missing.bin"));
    try std.testing.expectEqual(@as(usize, 0), storage.openStreams);
}

// ---------------------------------------------------------------------------------------------------------------
// BinarySerializer / BinaryDeserializer
// ---------------------------------------------------------------------------------------------------------------

//
// Writes the same values as writeAllTypes in fixtures/generate.ts.
//
fn writeAllTypes(allocator: std.mem.Allocator, serializer: ISerializer) !void {
    try serializer.writeUInt32(0xDEADBEEF);
    try serializer.writeInt32(-12345);
    try serializer.writeUInt64(18446744073709551615);
    try serializer.writeInt64(-9223372036854775808);
    try serializer.writeFloat(3.14159);
    try serializer.writeDouble(std.math.pi);
    try serializer.writeBoolean(true);
    try serializer.writeBoolean(false);
    try serializer.writeUInt8(255);
    try serializer.writeString("Hello 🚀 émojis");
    try serializer.writeBuffer(&.{ 0, 1, 2, 255 });
    try serializer.writeBytes(&.{ 9, 8, 7 });
    try serializer.writeBSON(try allTypesBson(allocator));
}

//
// The BSON document written by writeAllTypes.
//
fn allTypesBson(allocator: std.mem.Allocator) !BsonDocument {
    const array = try allocator.dupe(BsonValue, &.{ .{ .number = 1 }, .{ .number = 2 }, .{ .number = 3 } });
    const nested = try BsonDocument.fromFields(allocator, &.{
        .{ .key = "array", .value = .{ .array = array } },
        .{ .key = "bool", .value = .{ .boolean = true } },
    });
    return BsonDocument.fromFields(allocator, &.{
        .{ .key = "name", .value = .{ .string = "test" } },
        .{ .key = "value", .value = .{ .number = 42 } },
        .{ .key = "nested", .value = .{ .document = nested } },
    });
}

//
// Reads and checks the values written by writeAllTypes.
//
pub fn expectAllTypes(allocator: std.mem.Allocator, deserializer: IDeserializer) !void {
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), try deserializer.readUInt32());
    try std.testing.expectEqual(@as(i32, -12345), try deserializer.readInt32());
    try std.testing.expectEqual(@as(u64, 18446744073709551615), try deserializer.readUInt64());
    try std.testing.expectEqual(@as(i64, -9223372036854775808), try deserializer.readInt64());
    try std.testing.expectEqual(@as(f32, 3.14159), try deserializer.readFloat());
    try std.testing.expectEqual(@as(f64, std.math.pi), try deserializer.readDouble());
    try std.testing.expectEqual(true, try deserializer.readBoolean());
    try std.testing.expectEqual(false, try deserializer.readBoolean());
    try std.testing.expectEqual(@as(u8, 255), try deserializer.readUInt8());
    try expectString("Hello 🚀 émojis", try deserializer.readString());
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 255 }, try deserializer.readBuffer());
    try std.testing.expectEqualSlices(u8, &.{ 9, 8, 7 }, try deserializer.readBytes(3));
    try std.testing.expect((try deserializer.readBSON()).eql(try allTypesBson(allocator)));
}

test "BinarySerializer output matches TypeScript BinarySerializer (golden fixture)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var serializer = try BinarySerializer.init(allocator, 16);
    try writeAllTypes(allocator, serializer.asSerializer());

    const expected = try readFixture(allocator, "binary-serializer.bin");
    try std.testing.expectEqualSlices(u8, expected, serializer.getBuffer());
}

test "BinaryDeserializer reads TypeScript BinarySerializer output (golden fixture)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var deserializer = BinaryDeserializer.init(allocator, try readFixture(allocator, "binary-serializer.bin"));
    try expectAllTypes(allocator, deserializer.asDeserializer());
    try expectThrownContaining(deserializer.readUInt8(), "Cannot read 1 bytes at position");
}

test "BinarySerializer grows its buffer from a small initial capacity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var serializer = try BinarySerializer.init(allocator, 1);
    var index: u32 = 0;
    while (index < 100) : (index += 1) {
        try serializer.writeUInt32(index);
    }
    try std.testing.expectEqual(@as(usize, 400), serializer.getBuffer().len);
    try std.testing.expectEqual(@as(usize, 512), serializer.capacity);
    var deserializer = BinaryDeserializer.init(allocator, serializer.getBuffer());
    index = 0;
    while (index < 100) : (index += 1) {
        try std.testing.expectEqual(index, try deserializer.readUInt32());
    }
}

test "BinaryDeserializer checkBounds error message matches TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var deserializer = BinaryDeserializer.init(allocator, &.{ 1, 2 });
    try expectThrownContaining(deserializer.readUInt32(), "");
    try expectString("Cannot read 4 bytes at position 0. Buffer length: 2", errors.lastErrorMessage());
}

// ---------------------------------------------------------------------------------------------------------------
// Real data from test/dbs/v6
// ---------------------------------------------------------------------------------------------------------------

//
// A record read from a version 1 shard (fields only).
//
const ShardRecord = struct {
    // The 16-byte record id as hex.
    id: []const u8,

    // The record fields.
    fields: BsonDocument,
};

//
// Reads a version 1 shard (TypeScript: BsonShard.deserializeShardV1).
//
fn deserializeShardV1(allocator: std.mem.Allocator, _: void, deserializer: IDeserializer) anyerror![]ShardRecord {
    const recordCount = try deserializer.readUInt32();
    const records = try allocator.alloc(ShardRecord, recordCount);
    for (records) |*record| {
        const recordIdBuffer = try deserializer.readBytes(16);
        record.id = try std.fmt.allocPrint(allocator, "{x}", .{recordIdBuffer});
        record.fields = try deserializer.readBSON();
    }
    return records;
}

//
// Summary of a shard record written by generate.ts.
//
const ShardRecordSummary = struct {
    // The record id as hex.
    id: []const u8,

    // The field names in order.
    keys: []const []const u8,

    // The hash field.
    hash: []const u8,

    // The width field.
    width: f64,
};

//
// Summary of the files tree written by generate.ts.
//
const FilesTreeSummary = struct {
    // The tree UUID as hex.
    id: []const u8,

    // The string table.
    strings: []const []const u8,
};

//
// The summary of the v6 database written by generate.ts.
//
const V6Summary = struct {
    // The records of shard 96.
    shardRecords: []const ShardRecordSummary,

    // The files tree.
    filesTree: FilesTreeSummary,
};

//
// Reads the summary of the v6 database written by generate.ts.
//
fn readV6Summary(allocator: std.mem.Allocator) !V6Summary {
    const json = try readFixture(allocator, "v6-summary.json");
    return std.json.parseFromSliceLeaky(V6Summary, allocator, json, .{ .ignore_unknown_fields = true });
}

test "load reads a real shard from test/dbs/v6 and its BSON re-encodes to the same bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const shardPath = "../../test/dbs/v6/.db/bson/collections/metadata/shards/96";
    const shardBytes = try std.Io.Dir.cwd().readFileAlloc(io, shardPath, allocator, .unlimited);
    try storage.write(allocator, io, "shard", null, shardBytes);

    const deserializers = [_]serialization.DeserializerEntry([]ShardRecord, void){
        .{ .version = 1, .deserializer = deserializeShardV1 },
    };
    const records = (try serialization.load([]ShardRecord, allocator, io, &storage, "shard", "SHAR", {}, &deserializers)).?;

    const summary = try readV6Summary(allocator);
    try std.testing.expectEqual(summary.shardRecords.len, records.len);
    for (summary.shardRecords, records) |expected, record| {
        try expectString(expected.id, record.id);
        try std.testing.expectEqual(expected.keys.len, record.fields.count());
        for (expected.keys, record.fields.fields.items) |key, field| {
            try expectString(key, field.key);
        }
        try expectString(expected.hash, record.fields.get("hash").?.string);
        try std.testing.expectEqual(expected.width, record.fields.get("width").?.number);
    }

    // Re-encoding every record gives the original bytes (the shard is [version][count]([id][bson])*, no checksum).
    var deserializer = BinaryDeserializer.init(allocator, shardBytes[8..]);
    for (records) |record| {
        _ = try deserializer.readBytes(16);
        const length = try deserializer.readUInt32();
        const original = try deserializer.readBytes(length);
        const reencoded = try bson.serialize(allocator, record.fields);
        try std.testing.expectEqualSlices(u8, original, reencoded);
    }
}

test "load reads the real files tree from test/dbs/v6 including its gzip string table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    const treeBytes = try std.Io.Dir.cwd().readFileAlloc(io, "../../test/dbs/v6/.db/files.dat", allocator, .unlimited);
    try storage.write(allocator, io, "files.dat", null, treeBytes);

    const Tree = struct {
        // The files imported count from the database metadata.
        filesImported: f64,

        // The tree UUID as hex.
        id: []const u8,

        // The string table.
        strings: [][]const u8,

        //
        // Reads the start of a v6 merkle tree (TypeScript: deserializeMerkleTreeV6).
        //
        fn deserialize(treeAllocator: std.mem.Allocator, _: void, deserializer: IDeserializer) anyerror!@This() {
            const databaseMetadata = try deserializer.readBSON();
            const id = try std.fmt.allocPrint(treeAllocator, "{x}", .{try deserializer.readBytes(16)});
            var stringTableDeserializer = try serialization.CompressedBinaryDeserializer.init(treeAllocator, deserializer);
            const stringCount = try stringTableDeserializer.readUInt32();
            const strings = try treeAllocator.alloc([]const u8, stringCount);
            for (strings) |*string| {
                string.* = try stringTableDeserializer.readString();
            }
            return .{ .filesImported = databaseMetadata.get("filesImported").?.number, .id = id, .strings = strings };
        }
    };
    const deserializers = [_]serialization.DeserializerEntry(Tree, void){
        .{ .version = 6, .deserializer = Tree.deserialize },
    };
    const tree = (try serialization.load(Tree, allocator, io, &storage, "files.dat", "FTRE", {}, &deserializers)).?;

    const summary = try readV6Summary(allocator);
    try std.testing.expectEqual(@as(f64, 1), tree.filesImported);
    try expectString(summary.filesTree.id, tree.id);
    try std.testing.expectEqual(summary.filesTree.strings.len, tree.strings.len);
    for (summary.filesTree.strings, tree.strings) |expected, actual| {
        try expectString(expected, actual);
    }

    const verifyResult = try serialization.verify(allocator, io, &storage, "files.dat");
    try std.testing.expect(verifyResult.valid);
    try std.testing.expectEqual(@as(?u32, 6), serialization.loadVersion(allocator, io, &storage, "files.dat"));
}
