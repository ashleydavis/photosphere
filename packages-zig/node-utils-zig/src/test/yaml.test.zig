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
