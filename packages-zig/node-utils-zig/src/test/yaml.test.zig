const std = @import("std");
const node_utils = @import("node-utils-zig");
const utils = @import("utils-zig");
const yaml = node_utils.yaml;

//
// Creates an empty, unique temporary directory under the package's .zig-cache and returns its path.
//
fn makeTempDir(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    var randomBytes: [8]u8 = undefined;
    io.random(&randomBytes);
    const tempDir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp-tests/yaml-{s}", .{&std.fmt.bytesToHex(randomBytes, .lower)});
    try std.Io.Dir.cwd().createDirPath(io, tempDir);
    return tempDir;
}

//
// Runs src/test/fixtures/yaml-ts.ts (js-yaml) with bun and parses the last line of its stdout as JSON.
// The test is skipped where bun cannot be spawned.
//
fn runJsYaml(allocator: std.mem.Allocator, io: std.Io, arguments: []const []const u8) !std.json.Value {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ "bun", "run", "src/test/fixtures/yaml-ts.ts" });
    try argv.appendSlice(allocator, arguments);
    var environment = try std.testing.environ.createMap(allocator);
    const result = std.process.run(allocator, io, .{ .argv = argv.items, .environ_map = &environment }) catch |err| {
        if (err == error.FileNotFound) {
            return error.SkipZigTest;
        }
        return err;
    };
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("bun yaml-ts.ts failed:\n{s}\n{s}\n", .{ result.stdout, result.stderr });
        return error.TestUnexpectedResult;
    }
    const trimmed = std.mem.trimEnd(u8, result.stdout, "\r\n");
    const lastLineStart = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |index| index + 1 else 0;
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, trimmed[lastLineStart..], .{});
}

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
    const files = [_][]const u8{ "../../news.yaml", "../../test/demo-news.yaml" };
    for (files) |file| {
        const expected = try runJsYaml(allocator, io, &.{ "load", file });
        const actual = try yaml.load(allocator, try std.Io.Dir.cwd().readFileAlloc(io, file, allocator, .unlimited));
        try expectSameJson(allocator, expected, actual);
    }
}

test "load parses scalars, flow collections and comments like js-yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const dir = try makeTempDir(allocator, io);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
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
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = source });
    const expected = try runJsYaml(allocator, io, &.{ "load", file });
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
    const inputs = [_][]const u8{
        "{\"shown_news_ids\":[]}",
        "{\"shown_news_ids\":[\"welcome-2026-05-17\",\"demo-002-survey\"]}",
        "{\"shown_news_ids\":[\"a\"],\"last_shown_update_version\":\"1.2.3\"}",
        "{\"shown_news_ids\":[\"123\",\"true\",\"null\",\"has: colon\",\"#hash\",\"-dash\",\" space\",\"it's\",\"1.5\",\"line\\nbreak\"],\"last_shown_update_version\":\"2\"}",
    };
    for (inputs) |input| {
        const expected = (try runJsYaml(allocator, io, &.{ "dump", input })).string;
        const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, input, .{});
        try std.testing.expectEqualStrings(expected, try yaml.dump(allocator, value));
    }
}

test "dump writes nested sections, sequences of mappings and every scalar style like js-yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const inputs = [_][]const u8{
        "{\"desktop\":{\"last_folder\":\"/home/me/Pictures\",\"dev_tools_open\":true},\"gallery\":{\"sort\":\"date\",\"row_height\":120.5},\"news\":{\"shown_news_ids\":[\"a\"],\"feed\":[{\"id\":\"x\",\"message\":\"m: y\",\"duration\":1500,\"link\":\"http://a\"},{\"id\":\"z\",\"message\":\"q\",\"color\":\"primary\"}]},\"ui\":{\"sidebar.collapsed\":true,\"n\":3,\"list\":[\"a\",\"b\"],\"empty\":[]}}",
        "{\"quoted\":[\"yes\",\"No\",\"off\",\"y\",\"2024-01-01\",\"2024-1-2 3:04:05\",\"2024-01-01T10:00:00Z\",\"0x1F\",\"0o17\",\"0b101\",\"1_000\",\"_1\",\"1_\",\".5\",\".inf\",\"-.Inf\",\".nan\",\"1e5\",\"1:30\",\"<<\",\"~\",\"\",\"a#b\",\"a #b\",\"a: b\",\"a:b\",\"[x]\",\"x]\",\"=x\",\"%x\",\"x \",\"tab\\there\",\"\\u0007bell\",\"caf\\u00e9\",\"\\ud83d\\ude00 smile\",\"nbsp\\u00a0x\",\"line\\u2028sep\"]}",
        "{\"long\":\"This is a long line of text with spaces that goes on well past the eighty column line width limit of js-yaml\",\"longNoSpaces\":\"/home/someone/a/very/long/path/without/any/spaces/that/is/longer/than/eighty/columns/in/total/length\",\"multi\":\"first line\\nsecond line\\n\",\"keep\":\"a\\n\\n\",\"indented\":\" leading space\\nnext\",\"mixed\":\"short\\nThis second line of the block scalar is long enough that js-yaml chooses the folded style for it\",\"nested\":[[1,2],[],{},{\"k\":[{\"deep\":null}]}]}",
        "{\"a very long key that goes on and on and on and on and on and on and on and on and on and past eighty\":1,\"key: with colon\":\"v\",\"true\":false,\"1\":\"one\",\"multi\\nline key\":\"x\"}",
    };
    for (inputs) |input| {
        const expected = (try runJsYaml(allocator, io, &.{ "dump", input })).string;
        const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, input, .{});
        try std.testing.expectEqualStrings(expected, try yaml.dump(allocator, value));
    }
}
