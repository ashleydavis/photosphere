const std = @import("std");
const node_api = @import("node-api-zig");
const exif_parser = node_api.exif_parser;
const exif = node_api.exif_parser_exif;
const jpeg = node_api.exif_parser_jpeg;
const BufferStream = node_api.exif_parser_bufferstream.BufferStream;
const BsonValue = @import("serialization-zig").bson.BsonValue;

//
// Tests ported from exif-parser 0.1.12's own test suite (test/test-exif.js and test/test-jpeg.js), with its test
// images and expected tags copied into fixtures/exif-parser. test/test-date.js and test/test-simplify.js are not
// ported: Photosphere turns simple values off, so the date and simplify modules are not ported.
//

//
// The directory holding exif-parser's test files.
//
const FIXTURES_DIR = "src/test/fixtures/exif-parser";

//
// Reads a file of exif-parser's test directory.
//
fn readFixture(allocator: std.mem.Allocator, fileName: []const u8) ![]u8 {
    const filePath = try std.fs.path.join(allocator, &.{ FIXTURES_DIR, fileName });
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, filePath, allocator, .unlimited);
}

//
// Converts a JSON number to a float.
//
fn jsonNumber(value: std.json.Value) f64 {
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => std.debug.panic("expected a number in expected-exif-tags.json", .{}),
    };
}

//
// Checks a JavaScript value against a JSON value (`test.deepEqual`).
//
fn expectDeepEqual(expected: std.json.Value, actual: BsonValue) !void {
    switch (expected) {
        .string => |text| {
            try std.testing.expect(actual == .string);
            try std.testing.expectEqualStrings(text, actual.string);
        },
        .integer, .float => {
            try std.testing.expect(actual == .number);
            try std.testing.expectEqual(jsonNumber(expected), actual.number);
        },
        .array => |items| {
            try std.testing.expect(actual == .array);
            try std.testing.expectEqual(items.items.len, actual.array.len);
            for (items.items, actual.array) |expectedItem, actualItem| {
                try expectDeepEqual(expectedItem, actualItem);
            }
        },
        else => {
            std.debug.print("unexpected value in expected-exif-tags.json\n", .{});
            return error.TestUnexpectedResult;
        },
    }
}

//
// The state of the parseTags iterator of "test parseTags".
//
const IParseTagsState = struct {
    // The expected tags, in order.
    expectedTags: []const std.json.Value,

    // The index of the next expected tag.
    index: usize = 0,
};

//
// The parseTags iterator of "test parseTags": checks each tag against the next expected tag.
//
fn checkTag(state: *IParseTagsState, ifdSection: u8, tagType: u16, value: exif.ITagValue, format: u16) anyerror!void {
    const expectedTag = state.expectedTags[state.index].object;
    try std.testing.expectEqual(@as(i64, expectedTag.get("ifdSection").?.integer), @as(i64, ifdSection));
    try std.testing.expectEqual(@as(i64, expectedTag.get("tagType").?.integer), @as(i64, tagType));
    try std.testing.expectEqual(@as(i64, expectedTag.get("format").?.integer), @as(i64, format));
    const expectedValue = expectedTag.get("value").?;
    if (expectedValue == .string and std.mem.startsWith(u8, expectedValue.string, "b:")) {
        try std.testing.expect(value == .buffer);
        try std.testing.expectEqual(try std.fmt.parseInt(usize, expectedValue.string[2..], 10), value.buffer.len);
    }
    else {
        try std.testing.expect(value == .value);
        try expectDeepEqual(expectedValue, value.value);
    }
    state.index += 1;
}

test "test parseTags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const buffer = try readFixture(allocator, "starfish.jpg");
    const expectedTags = try std.json.parseFromSliceLeaky(std.json.Value, allocator, try readFixture(allocator, "expected-exif-tags.json"), .{});
    var state: IParseTagsState = .{
        .expectedTags = expectedTags.array.items,
    };
    var stream = BufferStream.init(buffer, 24, 23960, false);
    _ = try exif.parseTags(allocator, &stream, &state, checkTag);
    try std.testing.expectEqual(expectedTags.array.items.len, state.index);
}

//
// A section parseSections is expected to pass to its iterator.
//
const IExpectedSection = struct {
    // The marker type.
    type: u8,

    // The offset of the section data from the start of the JPEG.
    offset: i64,

    // The length of the section data.
    len: i64,
};

//
// The state of the parseSections iterator of "test parseSections".
//
const IParseSectionsState = struct {
    // The expected sections, in order.
    expectedSections: []const IExpectedSection,

    // The mark at the start of the JPEG.
    start: node_api.exif_parser_bufferstream.IMarker,

    // The index of the next expected section.
    index: usize = 0,
};

//
// The parseSections iterator of "test parseSections": checks each section against the next expected section.
//
fn checkSection(state: *IParseSectionsState, markerType: u8, sectionStream: *BufferStream) anyerror!void {
    const expectedSection = state.expectedSections[state.index];
    try std.testing.expectEqual(expectedSection.type, markerType);
    try std.testing.expectEqual(expectedSection.offset, sectionStream.offsetFrom(state.start));
    try std.testing.expectEqual(expectedSection.len, sectionStream.remainingLength());
    state.index += 1;
}

test "test parseSections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const buffer = try readFixture(allocator, "test.jpg");
    const expectedSections = [_]IExpectedSection{
        .{ .type = 216, .offset = 2, .len = 0 },
        .{ .type = 224, .offset = 6, .len = 14 },
        .{ .type = 226, .offset = 24, .len = 3158 },
        .{ .type = 225, .offset = 3186, .len = 200 },
        .{ .type = 225, .offset = 3390, .len = 374 },
        .{ .type = 219, .offset = 3768, .len = 65 },
        .{ .type = 219, .offset = 3837, .len = 65 },
        .{ .type = 192, .offset = 3906, .len = 15 },
        .{ .type = 196, .offset = 3925, .len = 29 },
        .{ .type = 196, .offset = 3958, .len = 179 },
        .{ .type = 196, .offset = 4141, .len = 29 },
        .{ .type = 196, .offset = 4174, .len = 179 },
        .{ .type = 218, .offset = 4355, .len = 0 },
    };
    var jpegStream = BufferStream.init(buffer, 0, @intCast(buffer.len), false);
    var state: IParseSectionsState = .{
        .expectedSections = &expectedSections,
        .start = jpegStream.mark(),
    };
    try jpeg.parseSections(&jpegStream, &state, checkSection);
    try std.testing.expectEqual(expectedSections.len, state.index);
}

test "test getSizeFromSOFSection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const buffer = try readFixture(allocator, "test.jpg");
    var stream = BufferStream.init(buffer, 3906, 15, true);
    const size = try jpeg.getSizeFromSOFSection(&stream);
    try std.testing.expectEqual(@as(u16, 2), size.width);
    try std.testing.expectEqual(@as(u16, 1), size.height);
}

test "test getSectionName" {
    const soi = jpeg.getSectionName(0xD8);
    try std.testing.expectEqualStrings("SOI", soi.name.?);
    try std.testing.expect(soi.index == null);
    const app = jpeg.getSectionName(0xEF);
    try std.testing.expectEqualStrings("APP", app.name.?);
    try std.testing.expectEqual(@as(?u8, 15), app.index);
    const dht = jpeg.getSectionName(0xC4);
    try std.testing.expectEqualStrings("DHT", dht.name.?);
    try std.testing.expect(dht.index == null);
}

test "parse needs simple values turned off, the only way Photosphere calls it" {
    var parser = exif_parser.Parser.create(&.{});
    try std.testing.expectError(error.FlagNotPorted, parser.parse(std.testing.allocator));
}
