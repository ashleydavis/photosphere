//
// Tests for CompressedBinarySerializer and CompressedBinaryDeserializer
//

const std = @import("std");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const serialization = serialization_zig.serialization;
const bson = serialization_zig.bson;
const BinarySerializer = serialization.BinarySerializer;
const BinaryDeserializer = serialization.BinaryDeserializer;
const CompressedBinarySerializer = serialization.CompressedBinarySerializer;
const CompressedBinaryDeserializer = serialization.CompressedBinaryDeserializer;
const ISerializer = serialization.ISerializer;
const IDeserializer = serialization.IDeserializer;
const BsonDocument = bson.BsonDocument;
const BsonValue = bson.BsonValue;

//
// The Io used by the tests.
//
const io = std.testing.io;

//
// Reads a fixture file.
//
fn readFixture(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const fixture_path = try std.fmt.allocPrint(allocator, "src/test/fixtures/{s}", .{name});
    return std.Io.Dir.cwd().readFileAlloc(io, fixture_path, allocator, .unlimited);
}

// ---------------------------------------------------------------------------------------------------------------
// CompressedBinarySerializer
// ---------------------------------------------------------------------------------------------------------------

test "should compress data and write to main serializer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mainSerializer = try BinarySerializer.init(allocator, 1024);
    var compressedSerializer = try CompressedBinarySerializer.init(allocator, mainSerializer.asSerializer(), 1024);

    // Write some data
    try compressedSerializer.writeString("Hello, World!");
    try compressedSerializer.writeUInt32(42);
    try compressedSerializer.writeBoolean(true);

    // Finish compression
    try compressedSerializer.finish();

    // Get the compressed data from main serializer
    const mainBuffer = mainSerializer.getBuffer();
    try std.testing.expect(mainBuffer.len > 0);

    const compressedLength = std.mem.readInt(u32, mainBuffer[0..4], .little);
    try std.testing.expect(compressedLength > 0);
    try std.testing.expect(compressedLength <= mainBuffer.len - 4);
}

test "should handle empty data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mainSerializer = try BinarySerializer.init(allocator, 1024);
    var compressedSerializer = try CompressedBinarySerializer.init(allocator, mainSerializer.asSerializer(), 1024);

    // Write nothing, just finish
    try compressedSerializer.finish();

    try std.testing.expect(mainSerializer.getBuffer().len >= 4); // At least length prefix
}

test "should compress large amounts of data effectively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mainSerializer = try BinarySerializer.init(allocator, 1024);
    var compressedSerializer = try CompressedBinarySerializer.init(allocator, mainSerializer.asSerializer(), 1024);

    // Write a lot of repetitive data (should compress well)
    const repeatedString = "This is a test string that will be repeated many times. ";
    var index: usize = 0;
    while (index < 100) : (index += 1) {
        try compressedSerializer.writeString(try std.fmt.allocPrint(allocator, "{s}{d}", .{ repeatedString, index }));
    }

    try compressedSerializer.finish();

    const mainBuffer = mainSerializer.getBuffer();
    const compressedLength = std.mem.readInt(u32, mainBuffer[0..4], .little);

    // Compressed data should be significantly smaller than uncompressed
    const uncompressedSize = 100 * (repeatedString.len + 20); // Approximate
    try std.testing.expect(compressedLength < uncompressedSize / 2);
}

test "should support all write methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mainSerializer = try BinarySerializer.init(allocator, 1024);
    var compressedSerializer = try CompressedBinarySerializer.init(allocator, mainSerializer.asSerializer(), 1024);

    // Test all write methods
    try compressedSerializer.writeUInt32(12345);
    try compressedSerializer.writeInt32(-12345);
    try compressedSerializer.writeUInt64(9007199254740991);
    try compressedSerializer.writeInt64(-9007199254740991);
    try compressedSerializer.writeFloat(3.14159); // This will be rounded to nearest representable float
    try compressedSerializer.writeDouble(3.141592653589793);
    try compressedSerializer.writeBoolean(true);
    try compressedSerializer.writeBoolean(false);
    try compressedSerializer.writeUInt8(255);
    try compressedSerializer.writeString("test string");
    try compressedSerializer.writeBuffer("test buffer");
    try compressedSerializer.writeBytes(&.{ 1, 2, 3, 4, 5 });
    try compressedSerializer.writeBSON(try BsonDocument.fromFields(allocator, &.{
        .{ .key = "name", .value = .{ .string = "test" } },
        .{ .key = "value", .value = .{ .number = 42 } },
    }));

    try compressedSerializer.finish();

    try std.testing.expect(mainSerializer.getBuffer().len > 0);
}

test "should use custom initial capacity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mainSerializer = try BinarySerializer.init(allocator, 1024);
    var compressedSerializer = try CompressedBinarySerializer.init(allocator, mainSerializer.asSerializer(), 2048);

    try compressedSerializer.writeString("test");
    try compressedSerializer.finish();

    try std.testing.expectEqual(@as(usize, 2048), compressedSerializer.serializer.capacity);
    try std.testing.expect(mainSerializer.getBuffer().len > 0);
}

// ---------------------------------------------------------------------------------------------------------------
// CompressedBinaryDeserializer
// ---------------------------------------------------------------------------------------------------------------

test "should decompress and read data correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Serialize with compression
    var mainSerializer = try BinarySerializer.init(allocator, 1024);
    var compressedSerializer = try CompressedBinarySerializer.init(allocator, mainSerializer.asSerializer(), 1024);

    try compressedSerializer.writeString("Hello, World!");
    try compressedSerializer.writeUInt32(42);
    try compressedSerializer.writeBoolean(true);
    try compressedSerializer.finish();

    // Deserialize
    var mainDeserializer = BinaryDeserializer.init(allocator, mainSerializer.getBuffer());
    var compressedDeserializer = try CompressedBinaryDeserializer.init(allocator, mainDeserializer.asDeserializer());

    // Read back the data
    try std.testing.expectEqualStrings("Hello, World!", try compressedDeserializer.readString());
    try std.testing.expectEqual(@as(u32, 42), try compressedDeserializer.readUInt32());
    try std.testing.expectEqual(true, try compressedDeserializer.readBoolean());
}

test "should handle round-trip for all data types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Serialize
    var mainSerializer = try BinarySerializer.init(allocator, 1024);
    var compressedSerializer = try CompressedBinarySerializer.init(allocator, mainSerializer.asSerializer(), 1024);

    // Use exact float values that can be precisely represented in 32-bit IEEE 754
    const exactFloat: f32 = 123.5; // Exactly representable: 123.5 = 123 + 1/2
    const exactFloat2: f32 = -42.25; // Exactly representable: -42.25 = -42 - 1/4
    const exactDouble: f64 = 3.141592653589793;
    const bsonObject = try BsonDocument.fromFields(allocator, &.{
        .{ .key = "name", .value = .{ .string = "test" } },
        .{ .key = "value", .value = .{ .number = 42 } },
    });

    try compressedSerializer.writeUInt32(12345);
    try compressedSerializer.writeInt32(-12345);
    try compressedSerializer.writeUInt64(9007199254740991);
    try compressedSerializer.writeInt64(-9007199254740991);
    try compressedSerializer.writeFloat(exactFloat);
    try compressedSerializer.writeFloat(exactFloat2);
    try compressedSerializer.writeDouble(exactDouble);
    try compressedSerializer.writeBoolean(true);
    try compressedSerializer.writeBoolean(false);
    try compressedSerializer.writeUInt8(255);
    try compressedSerializer.writeString("test string");
    const testBuffer = "test buffer";
    try compressedSerializer.writeBuffer(testBuffer);
    try compressedSerializer.writeBytes(&.{ 1, 2, 3, 4, 5 });
    try compressedSerializer.writeBSON(bsonObject);
    try compressedSerializer.finish();

    // Deserialize
    var mainDeserializer = BinaryDeserializer.init(allocator, mainSerializer.getBuffer());
    var compressedDeserializer = try CompressedBinaryDeserializer.init(allocator, mainDeserializer.asDeserializer());

    // Verify all values - floats should be exact
    try std.testing.expectEqual(@as(u32, 12345), try compressedDeserializer.readUInt32());
    try std.testing.expectEqual(@as(i32, -12345), try compressedDeserializer.readInt32());
    try std.testing.expectEqual(@as(u64, 9007199254740991), try compressedDeserializer.readUInt64());
    try std.testing.expectEqual(@as(i64, -9007199254740991), try compressedDeserializer.readInt64());
    try std.testing.expectEqual(exactFloat, try compressedDeserializer.readFloat());
    try std.testing.expectEqual(exactFloat2, try compressedDeserializer.readFloat());
    try std.testing.expectEqual(exactDouble, try compressedDeserializer.readDouble());
    try std.testing.expectEqual(true, try compressedDeserializer.readBoolean());
    try std.testing.expectEqual(false, try compressedDeserializer.readBoolean());
    try std.testing.expectEqual(@as(u8, 255), try compressedDeserializer.readUInt8());
    try std.testing.expectEqualStrings("test string", try compressedDeserializer.readString());
    try std.testing.expectEqualSlices(u8, testBuffer, try compressedDeserializer.readBuffer());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, try compressedDeserializer.readBytes(5));
    try std.testing.expect((try compressedDeserializer.readBSON()).eql(bsonObject));
}

test "should handle empty compressed data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mainSerializer = try BinarySerializer.init(allocator, 1024);
    var compressedSerializer = try CompressedBinarySerializer.init(allocator, mainSerializer.asSerializer(), 1024);
    try compressedSerializer.finish();

    var mainDeserializer = BinaryDeserializer.init(allocator, mainSerializer.getBuffer());
    const compressedDeserializer = try CompressedBinaryDeserializer.init(allocator, mainDeserializer.asDeserializer());

    // Should be able to create deserializer even with empty data
    try std.testing.expectEqual(@as(usize, 0), compressedDeserializer.deserializer.buffer.len);
}

test "should handle large amounts of data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mainSerializer = try BinarySerializer.init(allocator, 1024);
    var compressedSerializer = try CompressedBinarySerializer.init(allocator, mainSerializer.asSerializer(), 1024);

    // Write many strings
    var strings: [1000][]const u8 = undefined;
    for (&strings, 0..) |*string, index| {
        string.* = try std.fmt.allocPrint(allocator, "String number {d} with some content", .{index});
        try compressedSerializer.writeString(string.*);
    }
    try compressedSerializer.finish();

    // Deserialize
    var mainDeserializer = BinaryDeserializer.init(allocator, mainSerializer.getBuffer());
    var compressedDeserializer = try CompressedBinaryDeserializer.init(allocator, mainDeserializer.asDeserializer());

    // Read back all strings
    for (strings) |string| {
        try std.testing.expectEqualStrings(string, try compressedDeserializer.readString());
    }
}

test "should handle binary data with null bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mainSerializer = try BinarySerializer.init(allocator, 1024);
    var compressedSerializer = try CompressedBinarySerializer.init(allocator, mainSerializer.asSerializer(), 1024);

    const binaryData = [_]u8{ 0x00, 0x01, 0x02, 0xFF, 0x00, 0xAA };
    try compressedSerializer.writeBuffer(&binaryData);
    try compressedSerializer.finish();

    var mainDeserializer = BinaryDeserializer.init(allocator, mainSerializer.getBuffer());
    var compressedDeserializer = try CompressedBinaryDeserializer.init(allocator, mainDeserializer.asDeserializer());

    try std.testing.expectEqualSlices(u8, &binaryData, try compressedDeserializer.readBuffer());
}

test "should handle Unicode strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mainSerializer = try BinarySerializer.init(allocator, 1024);
    var compressedSerializer = try CompressedBinarySerializer.init(allocator, mainSerializer.asSerializer(), 1024);

    const unicodeStrings = [_][]const u8{
        "Hello, World!",
        "🚀 Unicode test",
        "émojis and spëcial chars",
        "中文测试",
        "日本語テスト",
        "Русский тест",
    };

    for (unicodeStrings) |string| {
        try compressedSerializer.writeString(string);
    }
    try compressedSerializer.finish();

    var mainDeserializer = BinaryDeserializer.init(allocator, mainSerializer.getBuffer());
    var compressedDeserializer = try CompressedBinaryDeserializer.init(allocator, mainDeserializer.asDeserializer());

    for (unicodeStrings) |string| {
        try std.testing.expectEqualStrings(string, try compressedDeserializer.readString());
    }
}

test "should handle BSON objects with complex structures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mainSerializer = try BinarySerializer.init(allocator, 1024);
    var compressedSerializer = try CompressedBinarySerializer.init(allocator, mainSerializer.asSerializer(), 1024);

    var array = [_]BsonValue{ .{ .number = 1 }, .{ .number = 2 }, .{ .number = 3 }, .{ .number = 4 }, .{ .number = 5 } };
    var tags = [_]BsonValue{ .{ .string = "tag1" }, .{ .string = "tag2" }, .{ .string = "tag3" } };
    const deep = try BsonDocument.fromFields(allocator, &.{
        .{ .key = "level", .value = .{ .number = 3 } },
        .{ .key = "data", .value = .{ .string = "deep value" } },
    });
    const nested = try BsonDocument.fromFields(allocator, &.{
        .{ .key = "array", .value = .{ .array = &array } },
        .{ .key = "bool", .value = .{ .boolean = true } },
        .{ .key = "date", .value = .{ .date = 1672531200000 } },
        .{ .key = "deep", .value = .{ .document = deep } },
    });
    const complexObj = try BsonDocument.fromFields(allocator, &.{
        .{ .key = "name", .value = .{ .string = "test" } },
        .{ .key = "value", .value = .{ .number = 42 } },
        .{ .key = "nested", .value = .{ .document = nested } },
        .{ .key = "tags", .value = .{ .array = &tags } },
    });

    try compressedSerializer.writeBSON(complexObj);
    try compressedSerializer.finish();

    var mainDeserializer = BinaryDeserializer.init(allocator, mainSerializer.getBuffer());
    var compressedDeserializer = try CompressedBinaryDeserializer.init(allocator, mainDeserializer.asDeserializer());

    try std.testing.expect((try compressedDeserializer.readBSON()).eql(complexObj));
}

test "should handle multiple compressed blocks in sequence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mainSerializer = try BinarySerializer.init(allocator, 1024);

    // First compressed block
    var compressedSerializer1 = try CompressedBinarySerializer.init(allocator, mainSerializer.asSerializer(), 1024);
    try compressedSerializer1.writeString("First block");
    try compressedSerializer1.writeUInt32(1);
    try compressedSerializer1.finish();

    // Second compressed block
    var compressedSerializer2 = try CompressedBinarySerializer.init(allocator, mainSerializer.asSerializer(), 1024);
    try compressedSerializer2.writeString("Second block");
    try compressedSerializer2.writeUInt32(2);
    try compressedSerializer2.finish();

    // Deserialize both blocks
    var mainDeserializer = BinaryDeserializer.init(allocator, mainSerializer.getBuffer());

    // Read first block
    var compressedDeserializer1 = try CompressedBinaryDeserializer.init(allocator, mainDeserializer.asDeserializer());
    try std.testing.expectEqualStrings("First block", try compressedDeserializer1.readString());
    try std.testing.expectEqual(@as(u32, 1), try compressedDeserializer1.readUInt32());

    // Read second block
    var compressedDeserializer2 = try CompressedBinaryDeserializer.init(allocator, mainDeserializer.asDeserializer());
    try std.testing.expectEqualStrings("Second block", try compressedDeserializer2.readString());
    try std.testing.expectEqual(@as(u32, 2), try compressedDeserializer2.readUInt32());
}

test "should maintain data integrity across compression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mainSerializer = try BinarySerializer.init(allocator, 1024);
    var compressedSerializer = try CompressedBinarySerializer.init(allocator, mainSerializer.asSerializer(), 1024);

    // Use exact float values that can be precisely represented
    const exactFloat: f32 = 1000.0; // Integer values are exactly representable
    const exactFloat2: f32 = 0.5; // Powers of 2 are exactly representable
    const exactFloat3: f32 = -123.125; // -123.125 = -123 - 1/8, exactly representable
    const testDouble: f64 = -9007199254740991; // Number.MIN_SAFE_INTEGER

    try compressedSerializer.writeUInt32(0xFFFFFFFF);
    try compressedSerializer.writeInt32(-0x7FFFFFFF);
    try compressedSerializer.writeUInt64(18446744073709551615);
    try compressedSerializer.writeInt64(-9223372036854775808);
    try compressedSerializer.writeFloat(exactFloat);
    try compressedSerializer.writeFloat(exactFloat2);
    try compressedSerializer.writeFloat(exactFloat3);
    try compressedSerializer.writeDouble(testDouble);
    try compressedSerializer.finish();

    var mainDeserializer = BinaryDeserializer.init(allocator, mainSerializer.getBuffer());
    var compressedDeserializer = try CompressedBinaryDeserializer.init(allocator, mainDeserializer.asDeserializer());

    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), try compressedDeserializer.readUInt32());
    try std.testing.expectEqual(@as(i32, -0x7FFFFFFF), try compressedDeserializer.readInt32());
    try std.testing.expectEqual(@as(u64, 18446744073709551615), try compressedDeserializer.readUInt64());
    try std.testing.expectEqual(@as(i64, -9223372036854775808), try compressedDeserializer.readInt64());
    // Floats should be exact
    try std.testing.expectEqual(exactFloat, try compressedDeserializer.readFloat());
    try std.testing.expectEqual(exactFloat2, try compressedDeserializer.readFloat());
    try std.testing.expectEqual(exactFloat3, try compressedDeserializer.readFloat());
    try std.testing.expectEqual(testDouble, try compressedDeserializer.readDouble());
}

test "should handle edge case values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mainSerializer = try BinarySerializer.init(allocator, 1024);
    var compressedSerializer = try CompressedBinarySerializer.init(allocator, mainSerializer.asSerializer(), 1024);

    try compressedSerializer.writeUInt32(0);
    try compressedSerializer.writeInt32(0);
    try compressedSerializer.writeUInt64(0);
    try compressedSerializer.writeInt64(0);
    try compressedSerializer.writeFloat(0);
    try compressedSerializer.writeDouble(0);
    try compressedSerializer.writeBoolean(false);
    try compressedSerializer.writeUInt8(0);
    try compressedSerializer.writeString("");
    try compressedSerializer.writeBuffer("");
    try compressedSerializer.finish();

    var mainDeserializer = BinaryDeserializer.init(allocator, mainSerializer.getBuffer());
    var compressedDeserializer = try CompressedBinaryDeserializer.init(allocator, mainDeserializer.asDeserializer());

    try std.testing.expectEqual(@as(u32, 0), try compressedDeserializer.readUInt32());
    try std.testing.expectEqual(@as(i32, 0), try compressedDeserializer.readInt32());
    try std.testing.expectEqual(@as(u64, 0), try compressedDeserializer.readUInt64());
    try std.testing.expectEqual(@as(i64, 0), try compressedDeserializer.readInt64());
    try std.testing.expectEqual(@as(f32, 0), try compressedDeserializer.readFloat());
    try std.testing.expectEqual(@as(f64, 0), try compressedDeserializer.readDouble());
    try std.testing.expectEqual(false, try compressedDeserializer.readBoolean());
    try std.testing.expectEqual(@as(u8, 0), try compressedDeserializer.readUInt8());
    try std.testing.expectEqualStrings("", try compressedDeserializer.readString());
    try std.testing.expectEqualSlices(u8, "", try compressedDeserializer.readBuffer());
}

// ---------------------------------------------------------------------------------------------------------------
// Integration with BinarySerializer/BinaryDeserializer
// ---------------------------------------------------------------------------------------------------------------

test "should work with nested compression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create outer serializer
    var outerSerializer = try BinarySerializer.init(allocator, 1024);
    var outerCompressed = try CompressedBinarySerializer.init(allocator, outerSerializer.asSerializer(), 1024);

    // Create inner serializer within compressed block
    var innerSerializer = try BinarySerializer.init(allocator, 1024);
    var innerCompressed = try CompressedBinarySerializer.init(allocator, innerSerializer.asSerializer(), 1024);

    // Write to inner compressed serializer
    try innerCompressed.writeString("Inner data");
    try innerCompressed.writeUInt32(100);
    try innerCompressed.finish();

    // Write inner compressed data to outer compressed serializer
    try outerCompressed.writeBuffer(innerSerializer.getBuffer());
    try outerCompressed.writeString("Outer data");
    try outerCompressed.finish();

    // Deserialize outer
    var outerDeserializer = BinaryDeserializer.init(allocator, outerSerializer.getBuffer());
    var outerCompressedDeserializer = try CompressedBinaryDeserializer.init(allocator, outerDeserializer.asDeserializer());

    // Read inner buffer
    const innerBufferRead = try outerCompressedDeserializer.readBuffer();
    try std.testing.expectEqualStrings("Outer data", try outerCompressedDeserializer.readString());

    // Deserialize inner
    var innerDeserializer = BinaryDeserializer.init(allocator, innerBufferRead);
    var innerCompressedDeserializer = try CompressedBinaryDeserializer.init(allocator, innerDeserializer.asDeserializer());

    try std.testing.expectEqualStrings("Inner data", try innerCompressedDeserializer.readString());
    try std.testing.expectEqual(@as(u32, 100), try innerCompressedDeserializer.readUInt32());
}

// ---------------------------------------------------------------------------------------------------------------
// Interoperability with Node's gzip (golden fixtures)
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
    const array = try allocator.dupe(BsonValue, &.{ .{ .number = 1 }, .{ .number = 2 }, .{ .number = 3 } });
    const nested = try BsonDocument.fromFields(allocator, &.{
        .{ .key = "array", .value = .{ .array = array } },
        .{ .key = "bool", .value = .{ .boolean = true } },
    });
    try serializer.writeBSON(try BsonDocument.fromFields(allocator, &.{
        .{ .key = "name", .value = .{ .string = "test" } },
        .{ .key = "value", .value = .{ .number = 42 } },
        .{ .key = "nested", .value = .{ .document = nested } },
    }));
}

//
// Builds the uncompressed bytes written by writeAllTypes.
//
fn allTypesBytes(allocator: std.mem.Allocator) ![]u8 {
    var serializer = try BinarySerializer.init(allocator, 1024);
    try writeAllTypes(allocator, serializer.asSerializer());
    return serializer.getBuffer();
}

//
// Builds the Zig equivalent of compressed-node.bin: [u32 7][compressed writeAllTypes][u32 8].
//
fn buildZigCompressed(allocator: std.mem.Allocator) ![]u8 {
    var mainSerializer = try BinarySerializer.init(allocator, 1024);
    try mainSerializer.writeUInt32(7);
    var compressedSerializer = try CompressedBinarySerializer.init(allocator, mainSerializer.asSerializer(), 1024);
    try writeAllTypes(allocator, compressedSerializer.asSerializer());
    try compressedSerializer.finish();
    try mainSerializer.writeUInt32(8);
    return mainSerializer.getBuffer();
}

test "CompressedBinaryDeserializer reads Node's gzip output (golden fixture)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mainDeserializer = BinaryDeserializer.init(allocator, try readFixture(allocator, "compressed-node.bin"));
    try std.testing.expectEqual(@as(u32, 7), try mainDeserializer.readUInt32());
    const compressedDeserializer = try CompressedBinaryDeserializer.init(allocator, mainDeserializer.asDeserializer());
    try std.testing.expectEqualSlices(u8, try allTypesBytes(allocator), compressedDeserializer.deserializer.buffer);
    try std.testing.expectEqual(@as(u32, 8), try mainDeserializer.readUInt32());
}

test "CompressedBinaryDeserializer reads Node's gzip output of empty and large data (golden fixtures)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var emptyDeserializer = BinaryDeserializer.init(allocator, try readFixture(allocator, "compressed-empty-node.bin"));
    const emptyCompressed = try CompressedBinaryDeserializer.init(allocator, emptyDeserializer.asDeserializer());
    try std.testing.expectEqual(@as(usize, 0), emptyCompressed.deserializer.buffer.len);

    var largeDeserializer = BinaryDeserializer.init(allocator, try readFixture(allocator, "compressed-large-node.bin"));
    var largeCompressed = try CompressedBinaryDeserializer.init(allocator, largeDeserializer.asDeserializer());
    var index: usize = 0;
    while (index < 1000) : (index += 1) {
        const expected = try std.fmt.allocPrint(allocator, "String number {d} with some content", .{index});
        try std.testing.expectEqualStrings(expected, try largeCompressed.readString());
    }
}

test "CompressedBinarySerializer output is byte-identical to Bun's gzip output (compressed-node.bin)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const actual = try buildZigCompressed(allocator);
    const expected = try readFixture(allocator, "compressed-node.bin");
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "CompressedBinarySerializer output of empty and large data is byte-identical to Bun's gzip output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var emptyMain = try BinarySerializer.init(allocator, 1024);
    var emptySerializer = try CompressedBinarySerializer.init(allocator, emptyMain.asSerializer(), 1024);
    try emptySerializer.finish();
    try std.testing.expectEqualSlices(u8, try readFixture(allocator, "compressed-empty-node.bin"), emptyMain.getBuffer());

    var largeMain = try BinarySerializer.init(allocator, 1024);
    var largeSerializer = try CompressedBinarySerializer.init(allocator, largeMain.asSerializer(), 1024);
    var index: usize = 0;
    while (index < 1000) : (index += 1) {
        try largeSerializer.writeString(try std.fmt.allocPrint(allocator, "String number {d} with some content", .{index}));
    }
    try largeSerializer.finish();
    try std.testing.expectEqualSlices(u8, try readFixture(allocator, "compressed-large-node.bin"), largeMain.getBuffer());
}

test "CompressedBinaryDeserializer throws on data that is not gzip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mainDeserializer = BinaryDeserializer.init(allocator, &.{ 4, 0, 0, 0, 1, 2, 3, 4 });
    const result = CompressedBinaryDeserializer.init(allocator, mainDeserializer.asDeserializer());
    try std.testing.expectError(error.Thrown, result);
    try std.testing.expectEqualStrings("incorrect header check", utils.errors.lastErrorMessage());
}

test "CompressedBinaryDeserializer throws zlib's messages for truncated and corrupted gzip data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var main = try BinarySerializer.init(allocator, 1024);
    var compressedSerializer = try CompressedBinarySerializer.init(allocator, main.asSerializer(), 1024);
    try compressedSerializer.writeString("hello world hello world");
    try compressedSerializer.finish();
    const block = main.getBuffer();
    const compressed = block[4..];

    // Truncated: drop the last 6 bytes of the gzip data.
    var truncated = try BinarySerializer.init(allocator, 1024);
    try truncated.writeBuffer(compressed[0 .. compressed.len - 6]);
    var truncatedDeserializer = BinaryDeserializer.init(allocator, truncated.getBuffer());
    try std.testing.expectError(error.Thrown, CompressedBinaryDeserializer.init(allocator, truncatedDeserializer.asDeserializer()));
    try std.testing.expectEqualStrings("unexpected end of file", utils.errors.lastErrorMessage());

    // Corrupted CRC: zero the 4 checksum bytes before the size.
    const corrupted = try allocator.dupe(u8, compressed);
    @memset(corrupted[corrupted.len - 8 .. corrupted.len - 4], 0);
    var corruptedSerializer = try BinarySerializer.init(allocator, 1024);
    try corruptedSerializer.writeBuffer(corrupted);
    var corruptedDeserializer = BinaryDeserializer.init(allocator, corruptedSerializer.getBuffer());
    try std.testing.expectError(error.Thrown, CompressedBinaryDeserializer.init(allocator, corruptedDeserializer.asDeserializer()));
    try std.testing.expectEqualStrings("incorrect data check", utils.errors.lastErrorMessage());
}
