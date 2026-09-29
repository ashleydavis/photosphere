const std = @import("std");
const node_utils = @import("node-utils-zig");
const utils = @import("utils-zig");
const toml = node_utils.toml;
const errors = utils.errors;

//
// A TOML document and the value smol-toml parses it to (see fixtures/generate.ts).
//
const ParseCase = struct {
    // Name of the case.
    name: []const u8,

    // The TOML document.
    toml: []const u8,

    // The value smol-toml returns, as JSON.
    json: std.json.Value,
};

//
// An object and the text smol-toml stringifies it to (see fixtures/generate.ts).
//
const StringifyCase = struct {
    // Name of the case.
    name: []const u8,

    // The object, as JSON.
    object: std.json.Value,

    // The TOML text smol-toml produces.
    toml: []const u8,
};

//
// Returns the numeric value of an integer or float value.
//
fn numberValue(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => null,
    };
}

//
// Compares two dynamic values (integers and floats compare numerically, like JavaScript numbers).
// When `ordered` is true the keys of tables must also be in the same order.
//
fn expectValuesEqual(expected: std.json.Value, actual: std.json.Value, ordered: bool) !void {
    if (numberValue(expected)) |expected_number| {
        const actual_number = numberValue(actual) orelse return error.TestExpectedNumber;
        try std.testing.expectEqual(expected_number, actual_number);
        return;
    }
    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        .string => |string| try std.testing.expectEqualStrings(string, actual.string),
        .bool => |boolean| try std.testing.expectEqual(boolean, actual.bool),
        .array => |array| {
            try std.testing.expectEqual(array.items.len, actual.array.items.len);
            for (array.items, actual.array.items) |expected_item, actual_item| {
                try expectValuesEqual(expected_item, actual_item, ordered);
            }
        },
        .object => |object| {
            try std.testing.expectEqual(object.count(), actual.object.count());
            for (object.keys(), object.values(), actual.object.keys()) |expected_key, expected_value, actual_key| {
                if (ordered) {
                    try std.testing.expectEqualStrings(expected_key, actual_key);
                }
                const actual_value = actual.object.get(expected_key) orelse return error.TestMissingKey;
                try expectValuesEqual(expected_value, actual_value, ordered);
            }
        },
        else => {},
    }
}

test "parse matches smol-toml for the golden documents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = try std.json.parseFromSliceLeaky([]ParseCase, allocator, @embedFile("fixtures/toml-parse.json"), .{});
    try std.testing.expect(cases.len >= 8);
    for (cases) |parse_case| {
        const parsed = toml.parse(allocator, parse_case.toml) catch |err| {
            std.debug.print("Case '{s}' failed: {s}\n", .{ parse_case.name, errors.errorMessage(err) });
            return err;
        };
        expectValuesEqual(parse_case.json, parsed, true) catch |err| {
            std.debug.print("Case '{s}' differs\n", .{parse_case.name});
            return err;
        };
    }
}

test "stringify matches smol-toml for the golden objects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = try std.json.parseFromSliceLeaky([]StringifyCase, allocator, @embedFile("fixtures/toml-stringify.json"), .{});
    try std.testing.expect(cases.len >= 6);
    for (cases) |stringify_case| {
        const text = try toml.stringify(allocator, stringify_case.object);
        std.testing.expectEqualStrings(stringify_case.toml, text) catch |err| {
            std.debug.print("Case '{s}' differs\n", .{stringify_case.name});
            return err;
        };
    }
}

test "stringify output parses back to the same value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = try std.json.parseFromSliceLeaky([]StringifyCase, allocator, @embedFile("fixtures/toml-stringify.json"), .{});
    const databases_config = cases[0];
    const reparsed = try toml.parse(allocator, try toml.stringify(allocator, databases_config.object));
    try expectValuesEqual(databases_config.object, reparsed, false);
}

test "parse keeps date-times as text and reads inf and nan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try toml.parse(arena.allocator(),
        \\odt = 1979-05-27T07:32:00Z
        \\spaced = 1979-05-27 07:32:00.999999-07:00
        \\local_date = 1979-05-27
        \\local_time = 07:32:00
        \\positive = inf
        \\negative = -inf
        \\not_a_number = nan
    );
    try std.testing.expectEqualStrings("1979-05-27T07:32:00Z", parsed.object.get("odt").?.string);
    try std.testing.expectEqualStrings("1979-05-27 07:32:00.999999-07:00", parsed.object.get("spaced").?.string);
    try std.testing.expectEqualStrings("1979-05-27", parsed.object.get("local_date").?.string);
    try std.testing.expectEqualStrings("07:32:00", parsed.object.get("local_time").?.string);
    try std.testing.expect(std.math.isPositiveInf(parsed.object.get("positive").?.float));
    try std.testing.expect(std.math.isNegativeInf(parsed.object.get("negative").?.float));
    try std.testing.expect(std.math.isNan(parsed.object.get("not_a_number").?.float));
}

test "parse rejects invalid documents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const invalid_documents = [_][]const u8{
        "key = ",
        "key = \"unterminated",
        "key value",
        "a = 1\na = 2",
        "a = 1 b = 2",
        "big = 9007199254740992",
        "[table",
        "x = [1, 2",
        "a = 01",
        "a = 1__0",
        "a = 1\n[a]",
    };
    for (invalid_documents) |document| {
        try std.testing.expectError(error.Thrown, toml.parse(allocator, document));
        try std.testing.expect(std.mem.startsWith(u8, errors.lastErrorMessage(), "Invalid TOML document: "));
    }
}

test "stringify rejects values that are not tables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Thrown, toml.stringify(arena.allocator(), .{ .integer = 1 }));
    try std.testing.expectEqualStrings("stringify can only be called with an object", errors.lastErrorMessage());
}

test "parse reads every escape, and the newline forms of multi-line strings, like smol-toml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const escapes = try toml.parse(allocator, "a = \"\\b\\t\\n\\f\\r\\\"\\\\\\u00e9\\U0001F600\"\n");
    try std.testing.expectEqualStrings("\x08\t\n\x0c\r\"\\\u{00E9}\u{1F600}", escapes.object.get("a").?.string);

    // The CRLF right after the opening delimiter is dropped, and a line ending backslash drops the newline and the
    // whitespace after it.
    try std.testing.expectEqualStrings("line", (try toml.parse(allocator, "a = \"\"\"\r\nline\"\"\"\n")).object.get("a").?.string);
    try std.testing.expectEqualStrings("one two", (try toml.parse(allocator, "a = \"\"\"one \\\n    two\"\"\"\n")).object.get("a").?.string);

    // An escape smol-toml does not know, and one cut off by the end of the document.
    for ([_][]const u8{ "a = \"\\q\"\n", "a = \"\\" }) |document| {
        try std.testing.expectError(error.Thrown, toml.parse(allocator, document));
        try std.testing.expect(std.mem.startsWith(u8, errors.lastErrorMessage(), "Invalid TOML document: "));
    }
}

//
// A value and the TOML text smol-toml stringifies `{ a: value }` to.
//
const IValueStringifyCase = struct {
    // The value of a.
    value: std.json.Value,

    // The TOML text.
    toml: []const u8,
};

test "stringify writes the numbers JSON cannot hold like smol-toml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = [_]IValueStringifyCase{
        .{ .value = .{ .float = std.math.nan(f64) }, .toml = "a = nan\n" },
        .{ .value = .{ .float = std.math.inf(f64) }, .toml = "a = inf\n" },
        .{ .value = .{ .float = -std.math.inf(f64) }, .toml = "a = -inf\n" },
        .{ .value = .{ .float = 1e21 }, .toml = "a = 1e+21\n" },
        .{ .value = .{ .float = -0.0 }, .toml = "a = 0\n" },
        .{ .value = .{ .float = 1e-7 }, .toml = "a = 1e-7\n" },
        .{ .value = .{ .number_string = "12345678901234567890" }, .toml = "a = 12345678901234567890\n" },
    };
    for (cases) |case| {
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "a", case.value);
        try std.testing.expectEqualStrings(case.toml, try toml.stringify(allocator, .{ .object = object }));
    }
}

test "stringify writes an empty table as one newline and refuses null in an array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("\n", try toml.stringify(allocator, .{ .object = .empty }));

    // smol-toml throws reading Object.keys of the null.
    var array = std.json.Array.init(allocator);
    try array.append(.null);
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "a", .{ .array = array });
    try std.testing.expectError(error.Thrown, toml.stringify(allocator, .{ .object = object }));
}

test "stringify refuses tables and arrays nested deeper than smol-toml's maximum depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 1100 nested tables, and 1100 nested arrays under one key.
    var table: std.json.Value = .{ .object = .empty };
    var nestedArray: std.json.Value = .{ .array = std.json.Array.init(allocator) };
    for (0..1100) |_| {
        var outerTable: std.json.ObjectMap = .empty;
        try outerTable.put(allocator, "x", table);
        table = .{ .object = outerTable };
        var outerArray = std.json.Array.init(allocator);
        try outerArray.append(nestedArray);
        nestedArray = .{ .array = outerArray };
    }
    try std.testing.expectError(error.Thrown, toml.stringify(allocator, table));
    try std.testing.expectEqualStrings("Could not stringify the object: maximum object depth exceeded", errors.lastErrorMessage());

    var arrayHolder: std.json.ObjectMap = .empty;
    try arrayHolder.put(allocator, "a", nestedArray);
    try std.testing.expectError(error.Thrown, toml.stringify(allocator, .{ .object = arrayHolder }));
    try std.testing.expectEqualStrings("Could not stringify the object: maximum object depth exceeded", errors.lastErrorMessage());

    // An array of tables nested that deep.
    var tables: std.json.Value = .{ .object = .empty };
    for (0..1100) |_| {
        var items = std.json.Array.init(allocator);
        try items.append(tables);
        var holder: std.json.ObjectMap = .empty;
        try holder.put(allocator, "t", .{ .array = items });
        tables = .{ .object = holder };
    }
    try std.testing.expectError(error.Thrown, toml.stringify(allocator, tables));
    try std.testing.expectEqualStrings("Could not stringify the object: maximum object depth exceeded", errors.lastErrorMessage());
}

test "parse reads the escape character and escapes in multi-line strings like smol-toml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // smol-toml.parse('a = "x\\ey"') is { a: "x\u001by" }, and a tab escape in a multi-line string is a tab.
    try std.testing.expectEqualStrings("x\x1by", (try toml.parse(allocator, "a = \"x\\ey\"\n")).object.get("a").?.string);
    try std.testing.expectEqualStrings("p\tq", (try toml.parse(allocator, "a = \"\"\"p\\tq\"\"\"\n")).object.get("a").?.string);
}

test "stringify refuses null inside a nested array like smol-toml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // smol-toml.stringify({ a: [[1, null]] }) throws "arrays cannot contain null or undefined values".
    var inner = std.json.Array.init(allocator);
    try inner.append(.{
        .integer = 1,
    });
    try inner.append(.null);
    var outer = std.json.Array.init(allocator);
    try outer.append(.{
        .array = inner,
    });
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "a", .{
        .array = outer,
    });
    try std.testing.expectError(error.Thrown, toml.stringify(allocator, .{
        .object = object,
    }));
    try std.testing.expectEqualStrings("arrays cannot contain null or undefined values", errors.lastErrorMessage());
}

test "stringify leaves out keys whose value is null, like smol-toml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // smol-toml.stringify({ a: null }) is "\n", and stringify({ a: [{ b: null }] }) is "[[a]]\n".
    var nullValue: std.json.ObjectMap = .empty;
    try nullValue.put(allocator, "a", .null);
    try std.testing.expectEqualStrings("\n", try toml.stringify(allocator, .{
        .object = nullValue,
    }));

    var entry: std.json.ObjectMap = .empty;
    try entry.put(allocator, "b", .null);
    var entries = std.json.Array.init(allocator);
    try entries.append(.{
        .object = entry,
    });
    var arrayTable: std.json.ObjectMap = .empty;
    try arrayTable.put(allocator, "a", .{
        .array = entries,
    });
    try std.testing.expectEqualStrings("[[a]]\n", try toml.stringify(allocator, .{
        .object = arrayTable,
    }));
}

//
// Stringifies { a: value } and returns the message it is refused with.
//
fn refusedMessage(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "a", value);
    try std.testing.expectError(error.Thrown, toml.stringify(allocator, .{
        .object = object,
    }));
    return errors.lastErrorMessage();
}

//
// A JSON array of the values.
//
fn jsonArray(allocator: std.mem.Allocator, values: []const std.json.Value) !std.json.Value {
    var array = std.json.Array.init(allocator);
    try array.appendSlice(values);
    return .{
        .array = array,
    };
}

test "stringify refuses null where smol-toml does, with smol-toml's messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var nullEntry: std.json.ObjectMap = .empty;
    try nullEntry.put(allocator, "b", .null);

    // { a: [null] } and { a: [[{ b: null }]] } fail in Object.keys of the null; { a: [[null]] } and { a: [1, null] }
    // fail in stringifyArray.
    try std.testing.expectEqualStrings("Cannot convert undefined or null to object", try refusedMessage(allocator, try jsonArray(allocator, &.{.null})));
    try std.testing.expectEqualStrings("Cannot convert undefined or null to object", try refusedMessage(allocator, try jsonArray(allocator, &.{try jsonArray(allocator, &.{.{
        .object = nullEntry,
    }})})));
    try std.testing.expectEqualStrings("arrays cannot contain null or undefined values", try refusedMessage(allocator, try jsonArray(allocator, &.{try jsonArray(allocator, &.{.null})})));
    try std.testing.expectEqualStrings("arrays cannot contain null or undefined values", try refusedMessage(allocator, try jsonArray(allocator, &.{
        .{
            .integer = 1,
        },
        .null,
    })));
}
