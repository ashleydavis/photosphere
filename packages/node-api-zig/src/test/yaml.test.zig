const std = @import("std");
const node_api = @import("node-api-zig");
const utils = @import("utils-zig");
const helpers = @import("test-helpers.zig");
const yaml = node_api.yaml;

//
// Compares two JSON values by their JSON text.
//
fn expectSameJson(allocator: std.mem.Allocator, expected: std.json.Value, actual: std.json.Value) !void {
    try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(allocator, expected, .{}), try std.json.Stringify.valueAlloc(allocator, actual, .{}));
}

test "load parses the news feeds like js-yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);
    const files = [_][]const u8{ "../../news.yaml", "../../test/demo-news.yaml" };
    for (files) |file| {
        const expected = try helpers.runBunJson(allocator, io, "yaml-ts.ts", &.{ "load", file }, &.{});
        const actual = try yaml.load(allocator, try helpers.readFile(allocator, io, file));
        try expectSameJson(allocator, expected, actual);
    }
}

test "load parses scalars, flow collections and comments like js-yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const dir = try helpers.setupEnvironment(io);
    const source =
        \\# A comment
        \\shown_news_ids:
        \\- a
        \\- 'b c'
        \\- "d\te"
        \\last_shown_update_version: 1.2.3
        \\numbers: [1, -2, 3.5, true, null, ~, "x"]
        \\empty: []
        \\map: {a: 1, b: two}
        \\nested:
        \\  key: value # trailing comment
        \\  list:
        \\    - id: one
        \\      message: "hello: world"
        \\    - id: two
        \\quoted: 'it''s'
        \\
    ;
    const file = try std.fmt.allocPrint(allocator, "{s}/scalars.yaml", .{dir});
    try helpers.writeFile(io, file, source);
    const expected = try helpers.runBunJson(allocator, io, "yaml-ts.ts", &.{ "load", file }, &.{});
    try expectSameJson(allocator, expected, try yaml.load(allocator, source));
}

test "load reports malformed YAML" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectError(error.Thrown, yaml.load(allocator, "items: [unclosed"));
    try std.testing.expectEqualStrings("YAMLException", utils.errors.lastErrorName());
    try std.testing.expectError(error.Thrown, yaml.load(allocator, "a: 1\n  b: 2\n"));
    try std.testing.expect(try yaml.load(allocator, "") == .null);
}

test "dump writes the news state like js-yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);
    const inputs = [_][]const u8{
        "{\"shown_news_ids\":[]}",
        "{\"shown_news_ids\":[\"welcome-2026-05-17\",\"demo-002-survey\"]}",
        "{\"shown_news_ids\":[\"a\"],\"last_shown_update_version\":\"1.2.3\"}",
        "{\"shown_news_ids\":[\"123\",\"true\",\"null\",\"has: colon\",\"#hash\",\"-dash\",\" space\",\"it's\",\"1.5\",\"line\\nbreak\"],\"last_shown_update_version\":\"2\"}",
    };
    for (inputs) |input| {
        const expected = (try helpers.runBunJson(allocator, io, "yaml-ts.ts", &.{ "dump", input }, &.{})).string;
        const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, input, .{});
        try std.testing.expectEqualStrings(expected, try yaml.dump(allocator, value));
    }
}
