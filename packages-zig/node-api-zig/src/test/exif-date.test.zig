const std = @import("std");
const node_api = @import("node-api-zig");
const serialization_zig = @import("serialization-zig");
const BsonValue = serialization_zig.bson.BsonValue;
const BsonDocument = serialization_zig.bson.BsonDocument;
const parseExifDate = node_api.image.parseExifDate;
const pickExifDate = node_api.image.pickExifDate;

//
// Which EXIF date a photo is given, and when it is given none (port of exif-date.test.ts).
//

//
// A tag name and its string value.
//
const ITag = struct {
    // The tag name.
    name: []const u8,

    // The tag value.
    value: []const u8,
};

//
// Parses a string the way parseExifDate is given a string tag.
//
fn parseText(allocator: std.mem.Allocator, text: []const u8) !?[]const u8 {
    return parseExifDate(allocator, .{ .string = text });
}

//
// Expects a string to parse to the ISO timestamp.
//
fn expectParsed(expected: []const u8, text: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parseText(arena.allocator(), text);
    try std.testing.expect(parsed != null);
    try std.testing.expectEqualStrings(expected, parsed.?);
}

//
// Expects a string to parse to nothing.
//
fn expectRefused(text: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(try parseText(arena.allocator(), text) == null);
}

//
// Picks the date out of tags, as a string (or null).
//
fn pick(allocator: std.mem.Allocator, tags: []const ITag) !?[]const u8 {
    var document: BsonDocument = .{};
    for (tags) |tag| {
        try document.put(allocator, tag.name, .{ .string = tag.value });
    }
    return pickExifDate(allocator, document);
}

//
// Expects tags to give the ISO timestamp.
//
fn expectPicked(expected: []const u8, tags: []const ITag) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const picked = try pick(arena.allocator(), tags);
    try std.testing.expect(picked != null);
    try std.testing.expectEqualStrings(expected, picked.?);
}

test "parseExifDate reads the EXIF date format" {
    try expectParsed("2025-03-27T20:22:57.000Z", "2025:03:27 20:22:57");
}

test "parseExifDate accepts a T in place of the space" {
    try expectParsed("2025-03-27T20:22:57.000Z", "2025:03:27T20:22:57");
}

test "parseExifDate ignores anything after the seconds" {
    try expectParsed("2025-03-27T20:22:57.000Z", "2025:03:27 20:22:57.123");
    try expectParsed("2025-03-27T20:22:57.000Z", "2025:03:27 20:22:57+10:00");
}

test "parseExifDate ignores surrounding whitespace" {
    try expectParsed("2025-03-27T20:22:57.000Z", "  2025:03:27 20:22:57\n");
}

test "parseExifDate ignores surrounding whitespace that is not ASCII, as String.prototype.trim does" {
    try expectParsed("2024-01-02T03:04:05.000Z", "\u{00A0}2024:01:02 03:04:05\u{3000}");
    try expectParsed("2024-01-02T03:04:05.000Z", "\u{FEFF}2024:01:02 03:04:05");
}

test "parseExifDate refuses the years 1 to 99, which Date.UTC reads as 1901 to 1999" {
    try expectRefused("0050:01:01 00:00:00");
    try expectRefused("0099:12:31 23:59:59");
    try expectParsed("0100-01-01T00:00:00.000Z", "0100:01:01 00:00:00");
}

test "parseExifDate reads the first and last moment of a day" {
    try expectParsed("2024-01-01T00:00:00.000Z", "2024:01:01 00:00:00");
    try expectParsed("2024-12-31T23:59:59.000Z", "2024:12:31 23:59:59");
}

test "parseExifDate reads a leap day" {
    try expectParsed("2024-02-29T12:00:00.000Z", "2024:02:29 12:00:00");
}

test "parseExifDate refuses a value that is not a date" {
    try expectRefused("not a date");
    try expectRefused("");
    try expectRefused("2025-03-27 20:22:57");
    try expectRefused("2025:03:27");

    // The separators are in place but a field is not all digits.
    try expectRefused("20a5:03:27 20:22:57");
    try expectRefused("2025:03:27 20:2x:57");
}

test "parseExifDate refuses the all-zero date a camera writes when its clock was never set" {
    try expectRefused("0000:00:00 00:00:00");
}

test "parseExifDate refuses a date with a zero month or day" {
    try expectRefused("2025:00:27 20:22:57");
    try expectRefused("2025:03:00 20:22:57");
}

test "parseExifDate refuses a day that is not in its month" {
    try expectRefused("2025:02:29 12:00:00");
    try expectRefused("2025:04:31 12:00:00");
}

test "parseExifDate refuses an out of range month or time" {
    try expectRefused("2025:13:01 12:00:00");
    try expectRefused("2025:03:27 24:00:00");
    try expectRefused("2025:03:27 20:60:00");
    try expectRefused("2025:03:27 20:22:60");
}

test "parseExifDate refuses a value that is not a string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expect(try parseExifDate(allocator, null) == null);
    try std.testing.expect(try parseExifDate(allocator, .{ .number = 1743107777 }) == null);
    var items = [_]BsonValue{
        .{ .number = 2025 },
        .{ .number = 3 },
        .{ .number = 27 },
    };
    try std.testing.expect(try parseExifDate(allocator, .{ .array = &items }) == null);
}

test "pickExifDate reads DateTimeOriginal" {
    try expectPicked("2025-03-27T20:22:57.000Z", &.{
        .{ .name = "DateTimeOriginal", .value = "2025:03:27 20:22:57" },
    });
}

test "pickExifDate reads DateTimeDigitized" {
    try expectPicked("2019-07-04T08:15:00.000Z", &.{
        .{ .name = "DateTimeDigitized", .value = "2019:07:04 08:15:00" },
    });
}

test "pickExifDate reads DateTime" {
    try expectPicked("2018-11-23T17:45:01.000Z", &.{
        .{ .name = "DateTime", .value = "2018:11:23 17:45:01" },
    });
}

test "pickExifDate reads ModifyDate" {
    try expectPicked("2017-05-09T06:30:22.000Z", &.{
        .{ .name = "ModifyDate", .value = "2017:05:09 06:30:22" },
    });
}

test "pickExifDate: DateTimeOriginal beats every other field" {
    try expectPicked("2025-03-27T20:22:57.000Z", &.{
        .{ .name = "DateTime", .value = "2025:03:31 12:40:49" },
        .{ .name = "DateTimeOriginal", .value = "2025:03:27 20:22:57" },
        .{ .name = "DateTimeDigitized", .value = "2025:03:28 09:00:00" },
        .{ .name = "ModifyDate", .value = "2025:03:31 12:40:49" },
    });
}

test "pickExifDate: DateTimeDigitized beats the modification fields" {
    try expectPicked("2025-03-28T09:00:00.000Z", &.{
        .{ .name = "DateTime", .value = "2025:03:31 12:40:49" },
        .{ .name = "DateTimeDigitized", .value = "2025:03:28 09:00:00" },
        .{ .name = "ModifyDate", .value = "2025:03:31 12:40:49" },
    });
}

test "pickExifDate: a modification date is never taken over a capture date" {
    try expectPicked("2025-03-27T20:22:57.000Z", &.{
        .{ .name = "DateTimeOriginal", .value = "2025:03:27 20:22:57" },
        .{ .name = "ModifyDate", .value = "2025:03:31 12:40:49" },
    });
}

test "pickExifDate skips a preferred field that holds no usable date" {
    try expectPicked("2025-03-28T09:00:00.000Z", &.{
        .{ .name = "DateTimeOriginal", .value = "0000:00:00 00:00:00" },
        .{ .name = "DateTimeDigitized", .value = "2025:03:28 09:00:00" },
    });
}

test "pickExifDate: metadata with no date fields gives no date" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var document: BsonDocument = .{};
    try document.put(allocator, "Make", .{ .string = "Google" });
    try document.put(allocator, "Model", .{ .string = "Pixel 6" });
    try document.put(allocator, "Orientation", .{ .number = 1 });
    try std.testing.expect(try pickExifDate(allocator, document) == null);
}

test "pickExifDate: empty metadata gives no date" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(try pick(arena.allocator(), &.{}) == null);
}

test "pickExifDate: absent metadata gives no date" {
    try std.testing.expect(try pickExifDate(std.testing.allocator, null) == null);
}

test "pickExifDate: date fields that are all unusable give no date" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect(try pick(arena.allocator(), &.{
        .{ .name = "DateTimeOriginal", .value = "0000:00:00 00:00:00" },
        .{ .name = "DateTime", .value = "not a date" },
        .{ .name = "ModifyDate", .value = "" },
    }) == null);
}
