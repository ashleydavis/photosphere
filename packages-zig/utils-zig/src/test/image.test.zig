const std = @import("std");
const utils = @import("utils-zig");
const image = utils.image;

//
// A stand-in for a JavaScript value (serialization-zig's BsonValue, which utils reads by duck typing).
//
const TestValue = union(enum) {
    // A number.
    number: f64,

    // An int32.
    int32: i32,

    // A double.
    double: f64,

    // A string.
    string: []const u8,

    // An array.
    array: []const TestValue,

    // An object.
    document: TestDocument,

    // A boolean.
    boolean: bool,

    // null.
    null,

    // undefined.
    undefined,

    // A date (a value the orientation code has no JavaScript rendering for).
    date: i64,
};

//
// A stand-in for a JavaScript object.
//
const TestDocument = struct {
    // The keys.
    keys: []const []const u8,

    // The values, by the index of their key.
    values: []const TestValue,

    //
    // Gets a property.
    //
    pub fn get(self: TestDocument, key: []const u8) ?TestValue {
        for (self.keys, self.values) |candidate, value| {
            if (std.mem.eql(u8, candidate, key)) {
                return value;
            }
        }
        return null;
    }
};

//
// EXIF tags with only an orientation.
//
fn withOrientation(comptime value: TestValue) ?TestDocument {
    return TestDocument{ .keys = &.{"Orientation"}, .values = &.{value} };
}

test "getImageTransformation needs no transformation without EXIF or orientation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expect((try image.getImageTransformation(allocator, @as(?TestDocument, null))) == null);
    try std.testing.expect((try image.getImageTransformation(allocator, @as(?TestDocument, TestDocument{ .keys = &.{}, .values = &.{} }))) == null);
    try std.testing.expect((try image.getImageTransformation(allocator, withOrientation(.{ .array = &.{.{ .number = 1 }} }))) == null);
    try std.testing.expect((try image.getImageTransformation(allocator, withOrientation(.{ .number = 0 }))) == null);
}

test "getImageTransformation reads the orientation from an array or a number" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const six = (try image.getImageTransformation(allocator, withOrientation(.{ .array = &.{.{ .number = 6 }} }))).?;
    try std.testing.expectEqual(@as(?f64, 90), six.rotate);
    try std.testing.expectEqual(@as(?bool, true), six.changeOrientation);
    try std.testing.expectEqual(@as(?bool, null), six.flipX);

    const two = (try image.getImageTransformation(allocator, withOrientation(.{ .number = 2 }))).?;
    try std.testing.expectEqual(@as(?bool, true), two.flipX);
    try std.testing.expectEqual(@as(?f64, null), two.rotate);

    const expected = [_]image.IImageTransformation{
        .{ .rotate = 180 },
        .{ .flipX = true, .rotate = 180 },
        .{ .flipX = true, .rotate = 270, .changeOrientation = true },
        .{ .rotate = 90, .changeOrientation = true },
        .{ .flipX = true, .rotate = 90, .changeOrientation = true },
        .{ .rotate = 270, .changeOrientation = true },
    };
    inline for (expected, 3..) |transformation, orientation| {
        const actual = (try image.getImageTransformation(allocator, withOrientation(.{ .array = &.{.{ .number = @floatFromInt(orientation) }} }))).?;
        try std.testing.expectEqual(transformation, actual);
    }
}

test "getImageTransformation rejects an orientation it does not know" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.Thrown, image.getImageTransformation(allocator, withOrientation(.{ .number = 9 })));
    try std.testing.expectEqualStrings("Unsupported orientation: 9", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, image.getImageTransformation(allocator, withOrientation(.{ .string = "6" })));
    try std.testing.expectEqualStrings("Unsupported orientation: 6", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, image.getImageTransformation(allocator, withOrientation(.{ .array = &.{} })));
    try std.testing.expectEqualStrings("Unsupported orientation: undefined", utils.errors.lastErrorMessage());
}

test "getVideoTransformation needs no transformation without streams" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expect((try image.getVideoTransformation(allocator, @as(?TestDocument, null))) == null);
    try std.testing.expect((try image.getVideoTransformation(allocator, @as(?TestDocument, TestDocument{ .keys = &.{"videoCodec"}, .values = &.{.{ .string = "h264" }} }))) == null);
}

test "getVideoTransformation reads the rotation of the first stream that has one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = TestDocument{
        .keys = &.{"streams"},
        .values = &.{.{ .array = &.{
            .{ .document = .{ .keys = &.{"codec_type"}, .values = &.{.{ .string = "audio" }} } },
            .{ .document = .{ .keys = &.{"rotation"}, .values = &.{.{ .number = -90 }} } },
            .{ .document = .{ .keys = &.{"rotation"}, .values = &.{.{ .number = 180 }} } },
        } }},
    };
    const transformation = (try image.getVideoTransformation(allocator, @as(?TestDocument, metadata))).?;
    try std.testing.expectEqual(@as(?f64, -90), transformation.rotate);
    try std.testing.expectEqual(@as(?bool, true), transformation.changeOrientation);
}

test "getImageTransformation reads an int32 orientation and needs no transformation for an orientation of 0" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 0 is falsy as a number, but an array holding 0 is truthy, so the orientation read is 0.
    try std.testing.expect((try image.getImageTransformation(allocator, withOrientation(.{ .array = &.{.{ .number = 0 }} }))) == null);
    const eight = (try image.getImageTransformation(allocator, withOrientation(.{ .int32 = 8 }))).?;
    try std.testing.expectEqual(@as(?f64, 270), eight.rotate);
}

//
// An orientation getImageTransformation does not know, and the message it throws for it.
//
const IUnknownOrientation = struct {
    // The orientation.
    value: TestValue,

    // The message thrown.
    message: []const u8,
};

test "getImageTransformation renders an orientation it does not know like JavaScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = [_]IUnknownOrientation{
        .{ .value = .{ .boolean = true }, .message = "Unsupported orientation: true" },
        .{ .value = .{ .array = &.{.{ .boolean = false }} }, .message = "Unsupported orientation: false" },
        .{ .value = .{ .array = &.{.{ .number = std.math.nan(f64) }} }, .message = "Unsupported orientation: NaN" },
        .{ .value = .{ .array = &.{.{ .number = -std.math.inf(f64) }} }, .message = "Unsupported orientation: -Infinity" },
        .{ .value = .{ .array = &.{.{ .double = 2.5 }} }, .message = "Unsupported orientation: 2.5" },
        .{ .value = .{ .array = &.{.{ .string = "" }} }, .message = "Unsupported orientation: " },
        .{ .value = .{ .array = &.{.null} }, .message = "Unsupported orientation: null" },
        .{ .value = .{ .array = &.{.{ .array = &.{ .{ .number = 6 }, .null, .{ .string = "x" } } }} }, .message = "Unsupported orientation: 6,,x" },
        .{ .value = .{ .document = .{ .keys = &.{}, .values = &.{} } }, .message = "Unsupported orientation: [object Object]" },
        .{ .value = .{ .date = 0 }, .message = "Unsupported orientation: date" },
    };
    inline for (cases) |case| {
        try std.testing.expectError(error.Thrown, image.getImageTransformation(allocator, withOrientation(case.value)));
        try std.testing.expectEqualStrings(case.message, utils.errors.lastErrorMessage());
    }
}

test "getVideoTransformation needs no transformation for falsy streams or rotations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expect((try image.getVideoTransformation(allocator, @as(?TestDocument, TestDocument{ .keys = &.{"streams"}, .values = &.{.null} }))) == null);
    try std.testing.expect((try image.getVideoTransformation(allocator, @as(?TestDocument, TestDocument{ .keys = &.{"streams"}, .values = &.{.{ .string = "streams" }} }))) == null);

    // A stream that is not an object, and a rotation of an empty array, whose `toString()` is empty and so falsy.
    const metadata = TestDocument{
        .keys = &.{"streams"},
        .values = &.{.{ .array = &.{
            .{ .number = 1 },
            .{ .document = .{ .keys = &.{"rotation"}, .values = &.{.{ .array = &.{} }} } },
        } }},
    };
    try std.testing.expect((try image.getVideoTransformation(allocator, @as(?TestDocument, metadata))) == null);
}

test "getVideoTransformation reads a rotation held as a string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const metadata = TestDocument{
        .keys = &.{"streams"},
        .values = &.{.{ .array = &.{
            .{ .document = .{ .keys = &.{"rotation"}, .values = &.{.{ .string = "270" }} } },
        } }},
    };
    const transformation = (try image.getVideoTransformation(allocator, @as(?TestDocument, metadata))).?;
    try std.testing.expectEqual(@as(?f64, 270), transformation.rotate);
    try std.testing.expectEqual(@as(?bool, true), transformation.changeOrientation);
}
