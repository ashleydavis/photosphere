const std = @import("std");
const bdb = @import("bdb-zig");
const serialization_zig = @import("serialization-zig");
const helpers = @import("test-helpers.zig");
const js_value = bdb.js_value;
const BsonValue = serialization_zig.bson.BsonValue;
const BsonDocument = serialization_zig.bson.BsonDocument;

//
// Formats a JS number with js_value.writeNumber (like `Number.prototype.toString()`).
//
fn numberToString(allocator: std.mem.Allocator, value: f64) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    try js_value.writeNumber(&output.writer, value);
    return output.written();
}

//
// Parses 16 hex digits into the double with those bits.
//
fn doubleFromBits(bitsHex: []const u8) !f64 {
    const bits = try std.fmt.parseInt(u64, bitsHex, 16);
    return @bitCast(bits);
}

test "numberToString matches Number.prototype.toString for the golden numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const fixture = try helpers.readJsonFixture(allocator, io, "js-values.json");
    var mismatches: usize = 0;
    for (fixture.object.get("numbers").?.array.items) |item| {
        const value = try doubleFromBits(item.object.get("bits").?.string);
        const expected = item.object.get("text").?.string;
        const actual = try numberToString(allocator, value);
        if (!std.mem.eql(u8, expected, actual)) {
            if (mismatches < 10) {
                std.debug.print("number {s}: expected {s}, got {s}\n", .{ item.object.get("bits").?.string, expected, actual });
            }
            mismatches += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

test "numberToString formats the JavaScript edge cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("0", try numberToString(allocator, -0.0));
    try std.testing.expectEqualStrings("1e+21", try numberToString(allocator, 1e21));
    try std.testing.expectEqualStrings("100000000000000000000", try numberToString(allocator, 1e20));
    try std.testing.expectEqualStrings("1e-7", try numberToString(allocator, 1e-7));
    try std.testing.expectEqualStrings("0.000001", try numberToString(allocator, 1e-6));
    try std.testing.expectEqualStrings("NaN", try numberToString(allocator, std.math.nan(f64)));
    try std.testing.expectEqualStrings("-Infinity", try numberToString(allocator, -std.math.inf(f64)));
}

test "stringToNumber matches Number(string)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const fixture = try helpers.readJsonFixture(allocator, io, "js-values.json");
    for (fixture.object.get("numberStrings").?.array.items) |item| {
        const text = item.object.get("text").?.string;
        const actual = js_value.stringToNumber(text);
        if (item.object.get("isNaN").?.bool) {
            if (!std.math.isNan(actual)) {
                std.debug.print("Number({s}) should be NaN, got {d}\n", .{ text, actual });
                return error.TestUnexpectedResult;
            }
        }
        else {
            const expected = try doubleFromBits(item.object.get("bits").?.string);
            if (@as(u64, @bitCast(expected)) != @as(u64, @bitCast(actual))) {
                std.debug.print("Number({s}): expected {d}, got {d}\n", .{ text, expected, actual });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "parseDate matches Date.parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const fixture = try helpers.readJsonFixture(allocator, io, "js-values.json");
    for (fixture.object.get("dates").?.array.items) |item| {
        const text = item.object.get("text").?.string;
        const actual = js_value.parseDate(text);
        const expected = item.object.get("time").?;
        if (expected == .null) {
            if (!std.math.isNan(actual)) {
                std.debug.print("Date.parse({s}) should be NaN, got {d}\n", .{ text, actual });
                return error.TestUnexpectedResult;
            }
        }
        else {
            const expectedTime: f64 = switch (expected) {
                .integer => |integer| @floatFromInt(integer),
                .float => |float| float,
                else => unreachable,
            };
            if (expectedTime != actual) {
                std.debug.print("Date.parse({s}): expected {d}, got {d}\n", .{ text, expectedTime, actual });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "date toString and toJSON match JavaScript (UTC)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const fixture = try helpers.readJsonFixture(allocator, io, "js-values.json");
    for (fixture.object.get("dateTimes").?.array.items) |item| {
        const time: i64 = switch (item.object.get("time").?) {
            .integer => |integer| integer,
            .float => |float| @intFromFloat(float),
            else => unreachable,
        };
        try std.testing.expectEqualStrings(item.object.get("toString").?.string, try js_value.toString(allocator, .{ .date = time }));
        const json = try js_value.applyToJson(allocator, .{ .date = time });
        try std.testing.expectEqualStrings(item.object.get("toJSON").?.string, json.string);
    }
}

test "compareUtf16 orders by UTF-16 code units" {
    try std.testing.expect(js_value.compareUtf16("a", "b") < 0);
    try std.testing.expect(js_value.compareUtf16("10", "9") < 0);
    try std.testing.expect(js_value.compareUtf16("\u{1F600}", "\u{FFFF}") < 0);
    try std.testing.expect(js_value.compareUtf16("ab", "a") > 0);
    try std.testing.expectEqual(@as(i32, 0), js_value.compareUtf16("same", "same"));
}

test "utf16Length counts surrogate pairs as two" {
    try std.testing.expectEqual(@as(usize, 3), js_value.utf16Length("abc"));
    try std.testing.expectEqual(@as(usize, 2), js_value.utf16Length("\u{1F600}"));
    try std.testing.expectEqual(@as(usize, 1), js_value.utf16Length("\u{00E9}"));
}

test "primitiveLessThan follows the abstract relational comparison" {
    try std.testing.expect(js_value.primitiveLessThan(.{ .number = 1 }, .{ .number = 2 }));
    try std.testing.expect(!js_value.primitiveLessThan(.{ .number = std.math.nan(f64) }, .{ .number = 2 }));
    try std.testing.expect(js_value.primitiveLessThan(.{ .string = "a" }, .{ .string = "b" }));
    try std.testing.expect(js_value.primitiveLessThan(.{ .string = "1" }, .{ .number = 2 }));
    try std.testing.expect(!js_value.primitiveLessThan(.{ .string = "x" }, .{ .number = 2 }));
}

test "strictEquals compares primitives by value and objects never" {
    try std.testing.expect(js_value.strictEquals(.{ .string = "a" }, .{ .string = "a" }));
    try std.testing.expect(!js_value.strictEquals(.{ .number = std.math.nan(f64) }, .{ .number = std.math.nan(f64) }));
    try std.testing.expect(js_value.strictEquals(.null, .null));
    try std.testing.expect(!js_value.strictEquals(.{ .date = 5 }, .{ .date = 5 }));
    try std.testing.expect(!js_value.strictEquals(.{ .number = 1 }, .{ .string = "1" }));
}

test "toString formats values like String()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("null", try js_value.toString(allocator, .null));
    try std.testing.expectEqualStrings("undefined", try js_value.toString(allocator, .undefined));
    try std.testing.expectEqualStrings("true", try js_value.toString(allocator, .{ .boolean = true }));
    try std.testing.expectEqualStrings("[object Object]", try js_value.toString(allocator, .{ .document = .empty }));
    var elements = [_]BsonValue{ .{ .number = 1 }, .null, .{ .string = "x" } };
    try std.testing.expectEqualStrings("1,,x", try js_value.toString(allocator, .{ .array = &elements }));
}

test "jsonStringifyIndented matches JSON.stringify(value, null, 2)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("\"abc\"", try js_value.jsonStringifyIndented(allocator, .{ .string = "abc" }));
    try std.testing.expectEqualStrings("undefined", try js_value.jsonStringifyIndented(allocator, .undefined));
    try std.testing.expectEqualStrings("\"1970-01-01T00:00:00.000Z\"", try js_value.jsonStringifyIndented(allocator, .{ .date = 0 }));
    var elements = [_]BsonValue{ .{ .number = 1 }, .undefined };
    try std.testing.expectEqualStrings("[\n  1,\n  null\n]", try js_value.jsonStringifyIndented(allocator, .{ .array = &elements }));
}

test "isObject matches typeof object, not null and not an array" {
    var elements = [_]BsonValue{.{ .number = 1 }};
    try std.testing.expect(js_value.isObject(.{ .document = .empty }));
    try std.testing.expect(js_value.isObject(.{ .date = 0 }));
    try std.testing.expect(!js_value.isObject(.null));
    try std.testing.expect(!js_value.isObject(.undefined));
    try std.testing.expect(!js_value.isObject(.{ .array = &elements }));
    try std.testing.expect(!js_value.isObject(.{ .string = "a" }));
    try std.testing.expect(!js_value.isObject(.{ .number = 1 }));
}

test "objectKeys matches Object.keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const document = try BsonDocument.fromFields(allocator, &.{
        .{
            .key = "b",
            .value = .undefined,
        },
        .{
            .key = "a",
            .value = .{ .number = 1 },
        },
    });
    const keys = try js_value.objectKeys(allocator, .{ .document = document });
    try std.testing.expectEqual(@as(usize, 2), keys.len);
    try std.testing.expectEqualStrings("b", keys[0]);
    try std.testing.expectEqualStrings("a", keys[1]);
    try std.testing.expectEqual(@as(usize, 0), (try js_value.objectKeys(allocator, .{ .date = 0 })).len);
    try std.testing.expectEqual(@as(usize, 0), (try js_value.objectKeys(allocator, .{ .number = 5 })).len);
    try std.testing.expectError(error.Thrown, js_value.objectKeys(allocator, .{ .string = "ab" }));
}

test "getProperty reads a property like value[key]" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const document = try BsonDocument.fromFields(allocator, &.{
        .{
            .key = "a",
            .value = .{ .number = 1 },
        },
    });
    try std.testing.expectEqual(@as(f64, 1), (try js_value.getProperty(.{ .document = document }, "a")).number);
    try std.testing.expect(try js_value.getProperty(.{ .document = document }, "missing") == .undefined);
    try std.testing.expect(try js_value.getProperty(.{ .date = 0 }, "a") == .undefined);
    try std.testing.expectError(error.Thrown, js_value.getProperty(.null, "a"));
}

//
// Number(string) trims every JavaScript whitespace character (Number("　5 ") is 5, and
// Number(" 5") is 5), but not the zero width space (Number("​5") is NaN).
//
test "stringToNumber trims the Unicode space separators like Number(string)" {
    try std.testing.expectEqual(@as(f64, 5), js_value.stringToNumber("\u{3000}5\u{2000}"));
    try std.testing.expectEqual(@as(f64, 5), js_value.stringToNumber("\u{1680}5"));
    try std.testing.expect(std.math.isNan(js_value.stringToNumber("\u{200B}5")));
}

test "stringToNumber trims every JavaScript whitespace character" {
    try std.testing.expectEqual(@as(f64, 12), js_value.stringToNumber(" \u{00A0} 12 \u{FEFF}"));
    try std.testing.expectEqual(@as(f64, 7), js_value.stringToNumber("\u{2028} 7 \u{2029}"));
    try std.testing.expectEqual(@as(f64, 0), js_value.stringToNumber("\u{FEFF}"));
}

test "toString formats every kind of value like String()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("-7", try js_value.toString(allocator, .{ .int32 = -7 }));
    try std.testing.expectEqualStrings("9007199254740993", try js_value.toString(allocator, .{ .int64 = 9007199254740993 }));
    try std.testing.expectEqualStrings("Thu Jan 01 1970 00:00:00 GMT+0000 (Coordinated Universal Time)", try js_value.toString(allocator, .{ .date = 0 }));

    // A UUID is its dashed hex string, any other Binary its bytes as UTF-8, and an ObjectId its hex string.
    const uuidBytes = [_]u8{ 0x12, 0x3e, 0x45, 0x67, 0xe8, 0x9b, 0x12, 0xd3, 0xa4, 0x56, 0x42, 0x66, 0x14, 0x17, 0x40, 0x00 };
    try std.testing.expectEqualStrings("123e4567-e89b-12d3-a456-426614174000", try js_value.toString(allocator, .{ .binary = .{ .subType = 4, .data = &uuidBytes } }));
    try std.testing.expectEqualStrings("hi", try js_value.toString(allocator, .{ .binary = .{ .subType = 0, .data = "hi" } }));
    const objectId = [_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67 };
    try std.testing.expectEqualStrings("0123456789abcdef01234567", try js_value.toString(allocator, .{ .objectId = objectId }));
}

test "toNumber converts every kind of value like Number()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqual(@as(f64, 3), try js_value.toNumber(allocator, .{ .int32 = 3 }));
    try std.testing.expectEqual(@as(f64, 42), try js_value.toNumber(allocator, .{ .string = " 42 " }));
    try std.testing.expectEqual(@as(f64, 1), try js_value.toNumber(allocator, .{ .boolean = true }));
    try std.testing.expectEqual(@as(f64, 0), try js_value.toNumber(allocator, .{ .boolean = false }));
    try std.testing.expectEqual(@as(f64, 0), try js_value.toNumber(allocator, .null));
    try std.testing.expect(std.math.isNan(try js_value.toNumber(allocator, .undefined)));
    try std.testing.expectEqual(@as(f64, 5), try js_value.toNumber(allocator, .{ .date = 5 }));
    try std.testing.expect(std.math.isNan(try js_value.toNumber(allocator, .{ .date = std.math.maxInt(i64) })));
    try std.testing.expect(std.math.isNan(try js_value.toNumber(allocator, .{ .document = .empty })));
    var elements = [_]BsonValue{.{ .number = 8 }};
    try std.testing.expectEqual(@as(f64, 8), try js_value.toNumber(allocator, .{ .array = &elements }));
}

test "compareUtf16 reads invalid UTF-8 as replacement characters" {
    // A byte that cannot start a sequence, a truncated sequence and an overlong encoding each read as U+FFFD.
    try std.testing.expectEqual(@as(i32, 0), js_value.compareUtf16("\xff", "\u{FFFD}"));
    try std.testing.expectEqual(@as(i32, 0), js_value.compareUtf16("\xe2\x82", "\u{FFFD}\u{FFFD}"));
    try std.testing.expectEqual(@as(i32, 0), js_value.compareUtf16("\xc0\x80", "\u{FFFD}\u{FFFD}"));
}

test "jsonStringifyIndented writes every kind of value like JSON.stringify(value, null, 2)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const objectId = [_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67 };
    const uuidBytes = [_]u8{ 0x12, 0x3e, 0x45, 0x67, 0xe8, 0x9b, 0x12, 0xd3, 0xa4, 0x56, 0x42, 0x66, 0x14, 0x17, 0x40, 0x00 };
    var elements = [_]BsonValue{ .{ .number = std.math.inf(f64) }, .{ .boolean = false }, .null };
    const inner = try BsonDocument.fromFields(allocator, &.{.{ .key = "x", .value = .undefined }});
    const document = try BsonDocument.fromFields(allocator, &.{
        .{ .key = "list", .value = .{ .array = &elements } },
        .{ .key = "skipped", .value = .undefined },
        .{ .key = "empty", .value = .{ .document = inner } },
        .{ .key = "invalid", .value = .{ .date = std.math.maxInt(i64) } },
        .{ .key = "binary", .value = .{ .binary = .{ .subType = 0, .data = "hi" } } },
        .{ .key = "uuid", .value = .{ .binary = .{ .subType = 4, .data = &uuidBytes } } },
        .{ .key = "id", .value = .{ .objectId = objectId } },
        .{ .key = "long", .value = .{ .int64 = -2 } },
        .{ .key = "int", .value = .{ .int32 = 3 } },
        .{ .key = "double", .value = .{ .double = 2.5 } },
    });
    try std.testing.expectEqualStrings(
        "{\n  \"list\": [\n    null,\n    false,\n    null\n  ],\n  \"empty\": {},\n  \"invalid\": null,\n  \"binary\": \"aGk=\",\n  \"uuid\": \"123e4567-e89b-12d3-a456-426614174000\",\n  \"id\": \"0123456789abcdef01234567\",\n  \"long\": {\n    \"low\": -2,\n    \"high\": -1,\n    \"unsigned\": false\n  },\n  \"int\": 3,\n  \"double\": 2.5\n}",
        try js_value.jsonStringifyIndented(allocator, .{ .document = document }),
    );
    var emptyElements = [_]BsonValue{};
    try std.testing.expectEqualStrings("[]", try js_value.jsonStringifyIndented(allocator, .{ .array = &emptyElements }));
}

test "writeJsonString writes a lone surrogate held as WTF-8 as a \\u escape, as JSON.stringify does" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    // D83D alone (ED A0 BD) and DE00 alone (ED B8 80), around a character that is not a surrogate.
    try js_value.writeJsonString(&output.writer, "a\xED\xA0\xBD\u{E9}\xED\xB8\x80");
    try std.testing.expectEqualStrings("\"a\\ud83d\u{E9}\\ude00\"", output.written());
}
