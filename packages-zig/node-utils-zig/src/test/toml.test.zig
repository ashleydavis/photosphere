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
