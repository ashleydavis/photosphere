const std = @import("std");
const node_utils = @import("node-utils-zig");
const utils = @import("utils-zig");
const yaml = node_utils.yaml;

//
// A YAML input and the value js-yaml 4.1.0 `yaml.load` returns for it, written as the JSON text of
// `JSON.stringify(yaml.load(text))`.
//
const ExpectedLoad = struct {
    // The path of the YAML file, relative to the package directory.
    file: []const u8,

    // The JSON text of the value js-yaml loads.
    json: []const u8,
};

//
// A value and the text js-yaml 4.1.0 `yaml.dump` writes for it (default options: indent 2, lineWidth 80, single quotes).
//
const ExpectedDump = struct {
    // The JSON text of the value that is dumped.
    json: []const u8,

    // The YAML text js-yaml writes.
    yaml: []const u8,
};

//
// Compares two JSON values by their JSON text.
//
fn expectSameJson(allocator: std.mem.Allocator, expected: std.json.Value, actual: std.json.Value) !void {
    try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(allocator, expected, .{}), try std.json.Stringify.valueAlloc(allocator, actual, .{}));
}

//
// Dumps each value and checks the output is the text js-yaml writes.
//
fn expectDumps(allocator: std.mem.Allocator, expectedDumps: []const ExpectedDump) !void {
    for (expectedDumps) |expectedDump| {
        const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, expectedDump.json, .{});
        try std.testing.expectEqualStrings(expectedDump.yaml, try yaml.dump(allocator, value));
    }
}

test "load parses the news feeds like js-yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    // Every value in the feeds is a mapping, a sequence or a string (no scalar resolves to another type).
    const expectedLoads = [_]ExpectedLoad{
        .{
            .file = "../../news.yaml",
            .json = "{\"items\":[{\"id\":\"welcome-2026-05-17\",\"message\":\"Welcome to Photosphere. Thanks for trying it out!\",\"link\":{\"label\":\"Read the docs\",\"url\":\"https://github.com/ashleydavis/photosphere/wiki\"},\"action\":{\"label\":\"What's new\",\"url\":\"https://github.com/ashleydavis/photosphere/releases/latest\"}}]}",
        },
        .{
            .file = "../../test/demo-news.yaml",
            .json = "{\"items\":[" ++
                "{\"id\":\"demo-001-welcome\",\"message\":\"Welcome to Photosphere. Thanks for trying it out!\",\"link\":{\"label\":\"Read the docs\",\"url\":\"https://github.com/ashleydavis/photosphere/wiki\"},\"action\":{\"label\":\"What's new\",\"url\":\"https://github.com/ashleydavis/photosphere/releases/latest\"}}," ++
                "{\"id\":\"demo-002-survey\",\"message\":\"We'd love your feedback. Take our 2-minute user survey!\",\"color\":\"neutral\",\"link\":{\"label\":\"Open the survey\",\"url\":\"https://example.com/photosphere/survey\"}}," ++
                "{\"id\":\"demo-003-blog\",\"message\":\"New blog post: how Photosphere stores your photos end-to-end encrypted.\",\"color\":\"neutral\",\"action\":{\"label\":\"Read the post\",\"url\":\"https://example.com/photosphere/blog/e2ee\"}}," ++
                "{\"id\":\"demo-004-release\",\"message\":\"Photosphere v1.5 is out: much faster sync and a redesigned navbar.\",\"color\":\"success\",\"link\":{\"label\":\"Release notes\",\"url\":\"https://example.com/photosphere/releases/v1.5\"},\"action\":{\"label\":\"Upgrade now\",\"url\":\"https://example.com/photosphere/download\"}}," ++
                "{\"id\":\"demo-005-bare\",\"message\":\"Heads up: scheduled maintenance window this weekend (no link, no button).\",\"color\":\"warning\"}" ++
                "]}",
        },
    };
    for (expectedLoads) |expectedLoad| {
        const expected = try std.json.parseFromSliceLeaky(std.json.Value, allocator, expectedLoad.json, .{});
        const actual = try yaml.load(allocator, try std.Io.Dir.cwd().readFileAlloc(io, expectedLoad.file, allocator, .unlimited));
        try expectSameJson(allocator, expected, actual);
    }
}

test "load parses scalars, flow collections and comments like js-yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
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

    // js-yaml: "\t" in double quotes is a tab, "1.2.3" matches no int or float pattern so it stays a string, "~" and
    // null are null, and '' in single quotes is one quote.
    const expectedJson = "{\"shown_news_ids\":[\"a\",\"b c\",\"d\\te\"],\"last_shown_update_version\":\"1.2.3\"," ++
        "\"numbers\":[1,-2,3.5,true,null,null,\"x\"],\"empty\":[],\"map\":{\"a\":1,\"b\":\"two\"}," ++
        "\"nested\":{\"key\":\"value\",\"list\":[{\"id\":\"one\",\"message\":\"hello: world\"},{\"id\":\"two\"}]},\"quoted\":\"it's\"}";
    const expected = try std.json.parseFromSliceLeaky(std.json.Value, allocator, expectedJson, .{});
    try expectSameJson(allocator, expected, try yaml.load(allocator, source));
}

test "load reads literal and folded block scalars like js-yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Each input and JSON.stringify(yaml.load(input)) from js-yaml 4.1.0.
    const expectedLoads = [_][2][]const u8{
        .{ "a: >-\n  folded line one\n  folded line two\nb: 1\n", "{\"a\":\"folded line one folded line two\",\"b\":1}" },
        .{ "a: |-\n  line one\n  line two\n", "{\"a\":\"line one\\nline two\"}" },
        .{ "a: |\n  keep one\n\n  after empty\n", "{\"a\":\"keep one\\n\\nafter empty\\n\"}" },
        .{ "a: |+\n  keep\n\n\nb: 2\n", "{\"a\":\"keep\\n\\n\\n\",\"b\":2}" },
        .{ "list:\n  - |2-\n     leading space\n  - >\n    x\n     more\n    y\n", "{\"list\":[\" leading space\",\"x\\n more\\ny\\n\"]}" },
        .{ "a: >\n  # not a comment\n  text\n", "{\"a\":\"# not a comment text\\n\"}" },
        .{ "a: |\n  no trailing newline", "{\"a\":\"no trailing newline\\n\"}" },
        .{ "a: > # comment\n  folded\n\n  para\n", "{\"a\":\"folded\\npara\\n\"}" },
        .{ "- |\n a\n- b\n", "[\"a\\n\",\"b\"]" },
    };
    for (expectedLoads) |expectedLoad| {
        const expected = try std.json.parseFromSliceLeaky(std.json.Value, allocator, expectedLoad[1], .{});
        try expectSameJson(allocator, expected, try yaml.load(allocator, expectedLoad[0]));
    }

    // js-yaml's errors for a bad header.
    try std.testing.expectError(error.Thrown, yaml.load(allocator, "a: |++\n  x\n"));
    try std.testing.expectEqualStrings("repeat of a chomping mode identifier (1:1)", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, yaml.load(allocator, "a: |0\n  x\n"));
    try std.testing.expectEqualStrings("bad explicit indentation width of a block scalar; it cannot be less than one (1:1)", utils.errors.lastErrorMessage());
    try std.testing.expectError(error.Thrown, yaml.load(allocator, "a: |x\n  y\n"));
    try std.testing.expectEqualStrings("a line break is expected (1:1)", utils.errors.lastErrorMessage());
}

test "a long or multi-line string that dump writes as a block scalar loads back as the same string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const json = "{\"desktop\":{\"last_folder\":\"/Users/someone/Pictures/Holiday photos from the summer of twenty twenty four in the south of France\"},\"ui\":{\"a\":\"line one\\nline two\"}}";
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
    const dumped = try yaml.dump(allocator, value);

    // What js-yaml 4.1.0 writes for it.
    try std.testing.expectEqualStrings("desktop:\n  last_folder: >-\n    /Users/someone/Pictures/Holiday photos from the summer of twenty twenty four\n    in the south of France\nui:\n  a: |-\n    line one\n    line two\n", dumped);
    try expectSameJson(allocator, value, try yaml.load(allocator, dumped));
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

    // js-yaml quotes strings that would load as another type ('123', 'true', 'null', '1.5', '2'), strings that start
    // with an indicator or a space, and ": "; a string with a line break is a literal block with strip chomping.
    const expectedDumps = [_]ExpectedDump{
        .{
            .json = "{\"shown_news_ids\":[]}",
            .yaml = "shown_news_ids: []\n",
        },
        .{
            .json = "{\"shown_news_ids\":[\"welcome-2026-05-17\",\"demo-002-survey\"]}",
            .yaml =
            \\shown_news_ids:
            \\  - welcome-2026-05-17
            \\  - demo-002-survey
            \\
            ,
        },
        .{
            .json = "{\"shown_news_ids\":[\"a\"],\"last_shown_update_version\":\"1.2.3\"}",
            .yaml =
            \\shown_news_ids:
            \\  - a
            \\last_shown_update_version: 1.2.3
            \\
            ,
        },
        .{
            .json = "{\"shown_news_ids\":[\"123\",\"true\",\"null\",\"has: colon\",\"#hash\",\"-dash\",\" space\",\"it's\",\"1.5\",\"line\\nbreak\"],\"last_shown_update_version\":\"2\"}",
            .yaml =
            \\shown_news_ids:
            \\  - '123'
            \\  - 'true'
            \\  - 'null'
            \\  - 'has: colon'
            \\  - '#hash'
            \\  - '-dash'
            \\  - ' space'
            \\  - it's
            \\  - '1.5'
            \\  - |-
            \\    line
            \\    break
            \\last_shown_update_version: '2'
            \\
            ,
        },
    };
    try expectDumps(allocator, &expectedDumps);
}

test "dump writes nested sections, sequences of mappings and every scalar style like js-yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expectedDumps = [_]ExpectedDump{
        // Nested mappings and sequences; the key "n" is quoted because it is a YAML 1.1 boolean.
        .{
            .json = "{\"desktop\":{\"last_folder\":\"/home/me/Pictures\",\"dev_tools_open\":true},\"gallery\":{\"sort\":\"date\",\"row_height\":120.5},\"news\":{\"shown_news_ids\":[\"a\"],\"feed\":[{\"id\":\"x\",\"message\":\"m: y\",\"duration\":1500,\"link\":\"http://a\"},{\"id\":\"z\",\"message\":\"q\",\"color\":\"primary\"}]},\"ui\":{\"sidebar.collapsed\":true,\"n\":3,\"list\":[\"a\",\"b\"],\"empty\":[]}}",
            .yaml =
            \\desktop:
            \\  last_folder: /home/me/Pictures
            \\  dev_tools_open: true
            \\gallery:
            \\  sort: date
            \\  row_height: 120.5
            \\news:
            \\  shown_news_ids:
            \\    - a
            \\  feed:
            \\    - id: x
            \\      message: 'm: y'
            \\      duration: 1500
            \\      link: http://a
            \\    - id: z
            \\      message: q
            \\      color: primary
            \\ui:
            \\  sidebar.collapsed: true
            \\  'n': 3
            \\  list:
            \\    - a
            \\    - b
            \\  empty: []
            \\
            ,
        },
        // Plain, single quoted (YAML 1.1 booleans, base 60 numbers, timestamps, ints, floats, merge, null and
        // indicators) and double quoted (characters that are not printable, with their escapes) scalars.
        .{
            .json = "{\"quoted\":[\"yes\",\"No\",\"off\",\"y\",\"2024-01-01\",\"2024-1-2 3:04:05\",\"2024-01-01T10:00:00Z\",\"0x1F\",\"0o17\",\"0b101\",\"1_000\",\"_1\",\"1_\",\".5\",\".inf\",\"-.Inf\",\".nan\",\"1e5\",\"1:30\",\"<<\",\"~\",\"\",\"a#b\",\"a #b\",\"a: b\",\"a:b\",\"[x]\",\"x]\",\"=x\",\"%x\",\"x \",\"tab\\there\",\"\\u0007bell\",\"caf\\u00e9\",\"\\ud83d\\ude00 smile\",\"nbsp\\u00a0x\",\"line\\u2028sep\"]}",
            .yaml =
            \\quoted:
            \\  - 'yes'
            \\  - 'No'
            \\  - 'off'
            \\  - 'y'
            \\  - '2024-01-01'
            \\  - '2024-1-2 3:04:05'
            \\  - '2024-01-01T10:00:00Z'
            \\  - '0x1F'
            \\  - '0o17'
            \\  - '0b101'
            \\  - '1_000'
            \\  - _1
            \\  - 1_
            \\  - '.5'
            \\  - '.inf'
            \\  - '-.Inf'
            \\  - '.nan'
            \\  - '1e5'
            \\  - '1:30'
            \\  - '<<'
            \\  - '~'
            \\  - ''
            \\  - a#b
            \\  - 'a #b'
            \\  - 'a: b'
            \\  - a:b
            \\  - '[x]'
            \\  - x]
            \\  - '=x'
            \\  - '%x'
            \\  - 'x '
            \\  - "tab\there"
            \\  - "\abell"
            \\  - café
            \\  - 😀 smile
            \\  - "nbsp\_x"
            \\  - "line\Lsep"
            \\
            ,
        },
        // Folded blocks for lines longer than 78 columns (80 less the indent), literal blocks with clip, keep and
        // strip chomping and an indentation indicator, and nested flow and block collections.
        .{
            .json = "{\"long\":\"This is a long line of text with spaces that goes on well past the eighty column line width limit of js-yaml\",\"longNoSpaces\":\"/home/someone/a/very/long/path/without/any/spaces/that/is/longer/than/eighty/columns/in/total/length\",\"multi\":\"first line\\nsecond line\\n\",\"keep\":\"a\\n\\n\",\"indented\":\" leading space\\nnext\",\"mixed\":\"short\\nThis second line of the block scalar is long enough that js-yaml chooses the folded style for it\",\"nested\":[[1,2],[],{},{\"k\":[{\"deep\":null}]}]}",
            .yaml =
            \\long: >-
            \\  This is a long line of text with spaces that goes on well past the eighty
            \\  column line width limit of js-yaml
            \\longNoSpaces: >-
            \\  /home/someone/a/very/long/path/without/any/spaces/that/is/longer/than/eighty/columns/in/total/length
            \\multi: |
            \\  first line
            \\  second line
            \\keep: |+
            \\  a
            \\
            \\indented: |2-
            \\   leading space
            \\  next
            \\mixed: >-
            \\  short
            \\
            \\  This second line of the block scalar is long enough that js-yaml chooses the
            \\  folded style for it
            \\nested:
            \\  - - 1
            \\    - 2
            \\  - []
            \\  - {}
            \\  - k:
            \\      - deep: null
            \\
            ,
        },
        // Keys: JavaScript orders the integer-like key "1" first; keys are single line, so a line break is escaped in
        // double quotes and a long key is not folded.
        .{
            .json = "{\"a very long key that goes on and on and on and on and on and on and on and on and on and past eighty\":1,\"key: with colon\":\"v\",\"true\":false,\"1\":\"one\",\"multi\\nline key\":\"x\"}",
            .yaml =
            \\'1': one
            \\a very long key that goes on and on and on and on and on and on and on and on and on and past eighty: 1
            \\'key: with colon': v
            \\'true': false
            \\"multi\nline key": x
            \\
            ,
        },
    };
    try expectDumps(allocator, &expectedDumps);
}

//
// A YAML text and the JSON text of the value js-yaml 4.1.0 `yaml.load` returns for it.
//
const IExpectedInlineLoad = struct {
    // The YAML text.
    source: []const u8,

    // The JSON text of the value js-yaml loads.
    json: []const u8,
};

test "load reads every block and flow form it supports like js-yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = [_]IExpectedInlineLoad{
        .{ .source = "---\na: 1\n", .json = "{\"a\":1}" },
        .{ .source = "a:\n", .json = "{\"a\":null}" },
        .{ .source = "a:\nb: 1\n", .json = "{\"a\":null,\"b\":1}" },
        .{ .source = "a:\n  value\n", .json = "{\"a\":\"value\"}" },
        .{ .source = "-\n  x\n", .json = "[\"x\"]" },
        .{ .source = "- - a\n  - b\n- c\n", .json = "[[\"a\",\"b\"],\"c\"]" },
        .{ .source = "a:\n  b: 1\nc: 2\n", .json = "{\"a\":{\"b\":1},\"c\":2}" },
        .{ .source = "'it''s: x': 1\n", .json = "{\"it's: x\":1}" },
        .{ .source = "a: \"x\\ny\\tz\\r\\0\\\"\\\\\\/\\ \"\n", .json = "{\"a\":\"x\\ny\\tz\\r\\u0000\\\"\\\\/ \"}" },
        .{ .source = "a: \"\\x41\\u00e9\\U0001F600\"\n", .json = "{\"a\":\"Aé😀\"}" },
        .{ .source = "a: false\n", .json = "{\"a\":false}" },
        .{ .source = "a: 1.5e3\n", .json = "{\"a\":1500}" },
        .{ .source = "a: .5\n", .json = "{\"a\":0.5}" },
        .{ .source = "a: 1e\n", .json = "{\"a\":\"1e\"}" },
        .{ .source = "a: +\n", .json = "{\"a\":\"+\"}" },
        .{ .source = "a: [1, [2, 3], {b: 4}]\n", .json = "{\"a\":[1,[2,3],{\"b\":4}]}" },
        .{ .source = "a: {b, c: }\n", .json = "{\"a\":{\"b\":null,\"c\":null}}" },
        .{ .source = "a:\n- 1\n- 2\n", .json = "{\"a\":[1,2]}" },
        .{ .source = "a: 99999999999999999999\n", .json = "{\"a\":100000000000000000000}" },
        .{ .source = "a: 'x, y'\n", .json = "{\"a\":\"x, y\"}" },
        .{ .source = "a: [\"x, y\", 'z]']\n", .json = "{\"a\":[\"x, y\",\"z]\"]}" },
        .{ .source = "a:b\n", .json = "\"a:b\"" },
        .{ .source = "\"k\": v\n", .json = "{\"k\":\"v\"}" },
        .{ .source = "a: x # comment\n", .json = "{\"a\":\"x\"}" },
        .{ .source = "a: 'x # y'\n", .json = "{\"a\":\"x # y\"}" },
    };
    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.source});
        const expected = try std.json.parseFromSliceLeaky(std.json.Value, allocator, case.json, .{});
        try expectSameJson(allocator, expected, try yaml.load(allocator, case.source));
    }
}

test "load throws a YAMLException for what js-yaml refuses, and for the constructs it does not port" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // js-yaml refuses each of these.
    const refused = [_][]const u8{
        "\ta: 1\n",
        "a: 1\n b: 2\n",
        "a: 1\na: 2\n",
        "a: \"\\x4\"\n",
        "a: \"\\q\"\n",
        "a: \"unterminated\n",
        "a: [1, 2\n",
        "a: {b: 1\n",
        "a: 'x' y\n",
        "a: 1\n- b\n",
        "- a\nb: 1\n",
    };

    // Not ported: anchors and plain scalars that go on over several lines, which js-yaml reads
    // (as "x", [1, "2 - 3"] and "x y"). Block scalars are ported (see the block scalar tests).
    const notPorted = [_][]const u8{ "a: &anchor x\n", "- 1\n- 2\n  - 3\n", "x\ny\n" };
    for (refused ++ notPorted) |source| {
        errdefer std.debug.print("case: {s}\n", .{source});
        try std.testing.expectError(error.Thrown, yaml.load(allocator, source));
        try std.testing.expectEqualStrings("YAMLException", utils.errors.lastErrorName());
    }
}

// js-yaml drops a UTF-8 byte order mark at the start of the document (`if (input.charCodeAt(0) === 0xFEFF) input =
// input.slice(1)`), so a file an editor saved with one reads as it would without.
test "load skips a byte order mark at the start of the document, as js-yaml does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const value = try yaml.load(allocator, "\xEF\xBB\xBFa: 1\n");
    try std.testing.expectEqual(@as(usize, 1), value.object.count());
    try std.testing.expectEqual(@as(i64, 1), value.object.get("a").?.integer);
}

// js-yaml refuses an empty item between commas in a flow collection ("expected the node content, but found ','").
test "load refuses an empty item in a flow collection, as js-yaml does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for ([_][]const u8{ "a: [a,,b]\n", "a: [,]\n", "a: {a: 1,, b: 2}\n" }) |source| {
        errdefer std.debug.print("case: {s}\n", .{source});
        try std.testing.expectError(error.Thrown, yaml.load(allocator, source));
        try std.testing.expectEqualStrings("YAMLException", utils.errors.lastErrorName());
    }
}

test "dump quotes, escapes and folds strings, and orders keys, like js-yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try expectDumps(allocator, &.{
        .{ .json = "{\"a\":\" leading space\\nsecond\"}", .yaml = "a: |2-\n   leading space\n  second\n" },
        .{ .json = "{\"a\":\"\\n\"}", .yaml = "a: |+\n\n" },
        .{ .json = "{\"a\":\"trailing\\n\\n\"}", .yaml = "a: |+\n  trailing\n\n" },
        .{ .json = "{\"a\":\"null\"}", .yaml = "a: 'null'\n" },
        .{ .json = "{\"a\":\"~\"}", .yaml = "a: '~'\n" },
        .{ .json = "{\"a\":\"True\"}", .yaml = "a: 'True'\n" },
        .{ .json = "{\"a\":\"yes\"}", .yaml = "a: 'yes'\n" },
        .{ .json = "{\"a\":\"0x1F\"}", .yaml = "a: '0x1F'\n" },
        .{ .json = "{\"a\":\"0o17\"}", .yaml = "a: '0o17'\n" },
        .{ .json = "{\"a\":\"0b101\"}", .yaml = "a: '0b101'\n" },
        .{ .json = "{\"a\":\"1_000\"}", .yaml = "a: '1_000'\n" },
        .{ .json = "{\"a\":\"-0x_1\"}", .yaml = "a: '-0x_1'\n" },
        .{ .json = "{\"a\":\"0x\"}", .yaml = "a: 0x\n" },
        .{ .json = "{\"a\":\"1:20\"}", .yaml = "a: '1:20'\n" },
        .{ .json = "{\"a\":\"1.5e+3\"}", .yaml = "a: '1.5e+3'\n" },
        .{ .json = "{\"a\":\".inf\"}", .yaml = "a: '.inf'\n" },
        .{ .json = "{\"a\":\"-.Inf\"}", .yaml = "a: '-.Inf'\n" },
        .{ .json = "{\"a\":\".NaN\"}", .yaml = "a: '.NaN'\n" },
        .{ .json = "{\"a\":\"1e3\"}", .yaml = "a: '1e3'\n" },
        .{ .json = "{\"a\":\"2001-12-14\"}", .yaml = "a: '2001-12-14'\n" },
        .{ .json = "{\"a\":\"2001-12-14t21:59:43.10-05:00\"}", .yaml = "a: '2001-12-14t21:59:43.10-05:00'\n" },
        .{ .json = "{\"a\":\"2001-12-14 21:59:43.10 Z\"}", .yaml = "a: '2001-12-14 21:59:43.10 Z'\n" },
        .{ .json = "{\"a\":\"2001-1-4\"}", .yaml = "a: 2001-1-4\n" },
        .{ .json = "{\"a\":\"190:20:30\"}", .yaml = "a: '190:20:30'\n" },
        .{ .json = "{\"a\":\"abc\\u0001def\"}", .yaml = "a: \"abc\\x01def\"\n" },
        .{ .json = "{\"a\":\"tab\\there\"}", .yaml = "a: \"tab\\there\"\n" },
        .{ .json = "{\"a\":\"x\u{2028}y\"}", .yaml = "a: \"x\\Ly\"\n" },
        .{ .json = "{\"a\":\"a very long line of text that goes on and on well past the eighty character limit of the dumper so it folds\"}", .yaml = "a: >-\n  a very long line of text that goes on and on well past the eighty character\n  limit of the dumper so it folds\n" },
        .{ .json = "{\"a\":\"a very long line of text that goes on and on\\nwell past the eighty character limit of the dumper so it folds, with a second line that is also long enough\"}", .yaml = "a: >-\n  a very long line of text that goes on and on\n\n  well past the eighty character limit of the dumper so it folds, with a second\n  line that is also long enough\n" },
        .{ .json = "{\"a\":\"averylongwordwithoutanyspacesthatcannotbefoldedatallbecauseithasnospacesanywhereinsideitatall and then\"}", .yaml = "a: >-\n  averylongwordwithoutanyspacesthatcannotbefoldedatallbecauseithasnospacesanywhereinsideitatall\n  and then\n" },
        .{ .json = "{\"multi\\nline key\":1}", .yaml = "\"multi\\nline key\": 1\n" },
        .{ .json = "{\"\":1}", .yaml = "'': 1\n" },
        .{ .json = "{\"1\":\"e\",\"2\":\"b\",\"10\":\"c\",\"a\":\"d\"}", .yaml = "'1': e\n'2': b\n'10': c\na: d\n" },
        .{ .json = "{\"a\":[]}", .yaml = "a: []\n" },
        .{ .json = "{\"a\":{}}", .yaml = "a: {}\n" },
        .{ .json = "[[1,2],[],{}]", .yaml = "- - 1\n  - 2\n- []\n- {}\n" },
        .{ .json = "[{\"a\":[1,{\"b\":2}]}]", .yaml = "- a:\n    - 1\n    - b: 2\n" },
        .{ .json = "{\"a\":\"it's\"}", .yaml = "a: it's\n" },
        .{ .json = "{\"a\":\"#comment\"}", .yaml = "a: '#comment'\n" },
        .{ .json = "{\"a\":\"- dash\"}", .yaml = "a: '- dash'\n" },
        .{ .json = "{\"a\":\"key: value\"}", .yaml = "a: 'key: value'\n" },
        .{ .json = "{\"a\":\"x \"}", .yaml = "a: 'x '\n" },
        .{ .json = "{\"a\":\"@at\"}", .yaml = "a: '@at'\n" },
        .{ .json = "{\"a\":\"\u{1F600}\"}", .yaml = "a: \u{1F600}\n" },
        .{ .json = "{\"a\":\"\u{FEFF}bom\"}", .yaml = "a: \"\\uFEFFbom\"\n" },
        .{ .json = "{\"a\":\"\u{0085}nel\"}", .yaml = "a: \"\\Nnel\"\n" },
        .{ .json = "{\"a\":1.5}", .yaml = "a: 1.5\n" },
        .{ .json = "{\"a\":-3}", .yaml = "a: -3\n" },
        .{ .json = "{\"a\":\"   \"}", .yaml = "a: '   '\n" },
        .{ .json = "{\"a\":\"? q\"}", .yaml = "a: '? q'\n" },
        .{ .json = "{\"a\":\"a\\r\\nb\"}", .yaml = "a: \"a\\r\\nb\"\n" },
    });
}

//
// A number and the text js-yaml 4.1.0 `yaml.dump` writes for it.
//
const IExpectedNumberDump = struct {
    // The number.
    value: std.json.Value,

    // The YAML text js-yaml writes.
    yaml: []const u8,
};

test "dump writes the numbers JSON cannot hold like js-yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cases = [_]IExpectedNumberDump{
        .{ .value = .{ .float = std.math.nan(f64) }, .yaml = ".nan\n" },
        .{ .value = .{ .float = std.math.inf(f64) }, .yaml = ".inf\n" },
        .{ .value = .{ .float = -std.math.inf(f64) }, .yaml = "-.inf\n" },
        .{ .value = .{ .float = -0.0 }, .yaml = "-0.0\n" },
        .{ .value = .{ .float = 1e21 }, .yaml = "1e+21\n" },
        .{ .value = .{ .float = 123456789012 }, .yaml = "123456789012\n" },
        .{ .value = .{ .float = 1e-7 }, .yaml = "1.e-7\n" },
        .{ .value = .{ .float = 1.5e-7 }, .yaml = "1.5e-7\n" },
        .{ .value = .{ .float = -2.5e-8 }, .yaml = "-2.5e-8\n" },
        .{ .value = .{ .float = 1.5e300 }, .yaml = "1.5e+300\n" },
        .{ .value = .{ .float = 0.1 }, .yaml = "0.1\n" },
        .{ .value = .{ .number_string = "123456789012345678901234567890" }, .yaml = "123456789012345678901234567890\n" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.yaml, try yaml.dump(allocator, case.value));
    }
}

test "dump decides what looks like a number, a time or a timestamp, quotes apostrophes and folds lines, like js-yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try expectDumps(allocator, &.{
        .{ .json = "{\"a\":\"\"}", .yaml = "a: ''\n" },
        .{ .json = "{\"a\":\"-\"}", .yaml = "a: '-'\n" },
        .{ .json = "{\"a\":\"+\"}", .yaml = "a: +\n" },
        .{ .json = "{\"a\":\"+12\"}", .yaml = "a: '+12'\n" },
        .{ .json = "{\"a\":\"0\"}", .yaml = "a: '0'\n" },
        .{ .json = "{\"a\":\"0b\"}", .yaml = "a: 0b\n" },
        .{ .json = "{\"a\":\"0o\"}", .yaml = "a: 0o\n" },
        .{ .json = "{\"a\":\"0b12\"}", .yaml = "a: 0b12\n" },
        .{ .json = "{\"a\":\"0x1G\"}", .yaml = "a: 0x1G\n" },
        .{ .json = "{\"a\":\"09\"}", .yaml = "a: '09'\n" },
        .{ .json = "{\"a\":\"1__2\"}", .yaml = "a: '1__2'\n" },
        .{ .json = "{\"a\":\"-_1\"}", .yaml = "a: '-_1'\n" },
        .{ .json = "{\"a\":\"1e\"}", .yaml = "a: 1e\n" },
        .{ .json = "{\"a\":\"1.5e+\"}", .yaml = "a: 1.5e+\n" },
        .{ .json = "{\"a\":\"12:30:45\"}", .yaml = "a: '12:30:45'\n" },
        .{ .json = "{\"a\":\"1:2:\"}", .yaml = "a: '1:2:'\n" },
        .{ .json = "{\"a\":\"1:_\"}", .yaml = "a: '1:_'\n" },
        .{ .json = "{\"a\":\"2001-12-14 21:59\"}", .yaml = "a: 2001-12-14 21:59\n" },
        .{ .json = "{\"a\":\"2001-12-14 21:59:43 +5\"}", .yaml = "a: '2001-12-14 21:59:43 +5'\n" },
        .{ .json = "{\"a\":\"2001-12-14 21:59:43 +05:3\"}", .yaml = "a: 2001-12-14 21:59:43 +05:3\n" },
        .{ .json = "{\"a\":\"2001-12-14T21:59:43+05:30\"}", .yaml = "a: '2001-12-14T21:59:43+05:30'\n" },
        .{ .json = "{\"a\":\"2001-12-14T21:59:43X\"}", .yaml = "a: 2001-12-14T21:59:43X\n" },
        .{ .json = "{\"a\":\"2001-12-14T1:59:43\"}", .yaml = "a: '2001-12-14T1:59:43'\n" },
        .{ .json = "{\"a\":\"it's: x\"}", .yaml = "a: 'it''s: x'\n" },
        .{ .json = "{\"a\":\"one two three four five six seven eight nine ten eleven twelve thirteen\\n  indented line that is also long enough to need folding past eighty chars\\nlast\"}", .yaml = "a: |-\n  one two three four five six seven eight nine ten eleven twelve thirteen\n    indented line that is also long enough to need folding past eighty chars\n  last\n" },
        .{ .json = "{\"a\":\"first line\\n\\nthird paragraph line that is long enough to fold past the eighty character width, yes\"}", .yaml = "a: >-\n  first line\n\n\n  third paragraph line that is long enough to fold past the eighty character\n  width, yes\n" },
        .{ .json = "[{\"a\":[1]}]", .yaml = "- a:\n    - 1\n" },
        .{ .json = "[\"x\\ny\"]", .yaml = "- |-\n  x\n  y\n" },
        .{ .json = "[\" leading\"]", .yaml = "- ' leading'\n" },
        .{ .json = "{\"4294967294\":3,\"01\":1,\"4294967295\":2,\"b\":4}", .yaml = "'4294967294': 3\n'01': 1\n'4294967295': 2\nb: 4\n" },
    });

    // A key longer than 1024 characters is written as an explicit pair.
    const longKey = try allocator.alloc(u8, 1100);
    @memset(longKey, 'k');
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, longKey, .{
        .integer = 1,
    });
    try std.testing.expectEqualStrings(try std.mem.concat(allocator, u8, &.{ "? ", longKey, "\n: 1\n" }), try yaml.dump(allocator, .{
        .object = object,
    }));
}

test "load reads a flow collection that is the whole document, and refuses an escape cut short by the end, like js-yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // js-yaml loads "[a, b]" as ["a","b"] and "{a: 1}" as {"a":1}.
    try std.testing.expectEqualStrings("[\"a\",\"b\"]", try std.json.Stringify.valueAlloc(allocator, try yaml.load(allocator, "[a, b]\n"), .{}));
    try std.testing.expectEqualStrings("{\"a\":1}", try std.json.Stringify.valueAlloc(allocator, try yaml.load(allocator, "{a: 1}\n"), .{}));

    // "a: \"\\x4" ends before the second hexadecimal digit: "expected hexadecimal character".
    try std.testing.expectError(error.Thrown, yaml.load(allocator, "a: \"\\x4"));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "expected hexadecimal character"));
}

// A word of fifty "a", so that two or three of them on a line are longer than the folding width.
const WORD_A = "a" ** 50;

// A word of fifty "b".
const WORD_B = "b" ** 50;

test "dump folds a last word that makes the line too long, and leaves empty and more-indented lines unfolded, like js-yaml" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The break is inserted before the last word: nothing in the line is over the width until its end.
    // An empty first line and a more-indented line are each kept as they are, not folded.
    try expectDumps(allocator, &.{
        .{
            .json = "{\"a\":\"" ++ WORD_A ++ " " ++ WORD_B ++ "\"}",
            .yaml = "a: >-\n  " ++ WORD_A ++ "\n  " ++ WORD_B ++ "\n",
        },
        .{
            .json = "{\"a\":\"\\n\\n" ++ WORD_A ++ " " ++ WORD_B ++ " " ++ WORD_A ++ "\\n\"}",
            .yaml = "a: >\n\n\n  " ++ WORD_A ++ "\n  " ++ WORD_B ++ "\n  " ++ WORD_A ++ "\n",
        },
        .{
            .json = "{\"a\":\"" ++ WORD_A ++ " " ++ WORD_B ++ " " ++ WORD_A ++ "\\n  " ++ WORD_A ++ " " ++ WORD_B ++ "\\nlast\"}",
            .yaml = "a: >-\n  " ++ WORD_A ++ "\n  " ++ WORD_B ++ "\n  " ++ WORD_A ++ "\n    " ++ WORD_A ++ " " ++ WORD_B ++ "\n  last\n",
        },
    });
}
