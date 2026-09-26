const std = @import("std");
const bdb = @import("bdb-zig");
const serialization_zig = @import("serialization-zig");
const helpers = @import("test-helpers.zig");
const js_value = bdb.js_value;
const BsonValue = serialization_zig.bson.BsonValue;

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
