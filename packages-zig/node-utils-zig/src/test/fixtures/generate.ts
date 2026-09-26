//
// Generates the golden fixtures used by the Zig tests of node-utils-zig.
// Run with: bun run src/test/fixtures/generate.ts (from packages-zig/node-utils-zig).
//
import * as fs from "fs";
import * as path from "path";
import { parse, stringify } from "smol-toml";

//
// TOML documents parsed by smol-toml. Date-times, inf and nan are left out because they do not
// survive JSON.stringify (they are covered by hand-written Zig tests).
//
const parseCases: { name: string, toml: string }[] = [
    {
        name: "databases config",
        toml: `recent_database_names = [ "photos", "Backup" ]

[[databases]]
name = "photos"
description = ""
path = "/home/user/photos"
origin = "s3:bucket:/photos"
s3_key = "s3-default"
encryption_key = "my-key"

[[databases]]
name = "Backup"
description = "The \\"backup\\" copy"
path = "C:\\\\Users\\\\me\\\\backup"
geocoding_key = "geo"
`,
    },
    {
        name: "legacy recent paths",
        toml: `recent_database_paths = ["/a", "/b"]
databases = []
`,
    },
    {
        name: "scalars and comments",
        toml: `# A comment
title = "TOML" # trailing comment
int = +99
negative = -17
zero = 0
big = 9_007_199_254_740_991
hex = 0xDEAD_BEEF
octal = 0o755
binary = 0b1101
float = 3.1415
exponent = 5e+22
small = 6.626e-34
flag = true
off = false
literal = 'C:\\Users\\nodejs\\templates'
unicode = "\\u00e9\\U0001F600"
escapes = "tab\\tnewline\\nquote\\"backslash\\\\"
"quoted key" = 1
'literal key' = 2
bare-key_1 = 3
`,
    },
    {
        name: "multi-line strings",
        toml: `basic = """
Roses are red
Violets are blue"""
trimmed = """\\
    The quick brown \\
    fox."""
quotes = """Here are two quotation marks: "". Simple enough."""
fivequotes = """"This," she said, "is just a pointless statement.""""
literal = '''
The first newline is
trimmed in raw strings.
   All other whitespace
   is preserved.
'''
literalquotes = ''''That,' she said, 'is still pointless.''''
`,
    },
    {
        name: "arrays",
        toml: `integers = [ 1, 2, 3 ]
colors = [ "red", "yellow", "green" ]
nested = [ [ 1, 2 ], ["a", 'b'] ]
mixed = [ 0.1, 0.2, 0.5, 1, 2, 5 ]
multiline = [
    1,  # one
    2,
    3, # trailing comma
]
empty = []
tables = [ { x = 1 }, { y = 2 } ]
`,
    },
    {
        name: "tables and dotted keys",
        toml: `name = "root"
dotted.key.here = true
site."google.com" = true
inline = { first = "Tom", last = "Preston-Werner", nested.deep = 1 }
empty_inline = {}

[server]
ip = "10.0.0.1"

[server.alpha]
role = "frontend"

[ dog . "tater.man" ]
type.name = "pug"

[a.b.c]
[a]
d = 1
`,
    },
    {
        name: "arrays of tables",
        toml: `[[products]]
name = "Hammer"
sku = 738594937

[[products]]

[[products]]
name = "Nail"
color = "gray"

[[fruits]]
name = "apple"

[fruits.physical]
color = "red"

[[fruits.varieties]]
name = "red delicious"

[[fruits.varieties]]
name = "granny smith"

[[fruits]]
name = "banana"

[[fruits.varieties]]
name = "plantain"
`,
    },
    {
        name: "windows line endings",
        toml: "a = 1\r\nb = \"two\"\r\n\r\n[t]\r\nc = [\r\n  1,\r\n  2\r\n]\r\n",
    },
];

//
// Objects stringified by smol-toml.
//
const stringifyCases: { name: string, object: any }[] = [
    {
        name: "databases config",
        object: {
            databases: [
                { name: "photos", description: "", path: "/home/user/photos", origin: "s3:bucket:/photos", s3_key: "s3-default", encryption_key: "my-key" },
                { name: "Backup", description: "The \"backup\" copy", path: "C:\\Users\\me\\backup", geocoding_key: "geo" },
            ],
            recent_database_names: ["photos", "Backup"],
        },
    },
    {
        name: "empty databases config",
        object: { databases: [], recent_database_names: [] },
    },
    {
        name: "flat object",
        object: { name: "test", count: 42, flag: true },
    },
    {
        name: "string arrays",
        object: { tags: ["alpha", "beta", "gamma"] },
    },
    {
        name: "array of tables",
        object: { items: [{ name: "a", value: 1 }, { name: "b", value: 2 }] },
    },
    {
        name: "everything",
        object: {
            name: "test", count: 42, negative: -3, float: 1.5, big: 1e21, tiny: 1.5e-7, flag: false,
            nested: { x: 1, deep: { y: "z" }, list: [{ a: 1 }] },
            emptyTable: {},
            onlyTables: { inner: { v: 1 } },
            items: [{ name: "a", value: 1, sub: { k: "v" } }],
            empty: [], tags: ["alpha", "beta"], mixed: [1, "a", [2, 3], { inline: true, "odd key": {} }],
            escapes: "line1\nline2\ttab\u0001\u007f\"\\\b\f\r",
            "key with space": 1, "dotted.key": 2, "": 3, "unicodé": "ü",
            nothing: null,
        },
    },
];

const parseFixture = parseCases.map(parseCase => ({ name: parseCase.name, toml: parseCase.toml, json: parse(parseCase.toml) }));
fs.writeFileSync(path.join(__dirname, "toml-parse.json"), JSON.stringify(parseFixture, null, 4) + "\n");

const stringifyFixture = stringifyCases.map(stringifyCase => ({ name: stringifyCase.name, object: stringifyCase.object, toml: stringify(stringifyCase.object) }));
fs.writeFileSync(path.join(__dirname, "toml-stringify.json"), JSON.stringify(stringifyFixture, null, 4) + "\n");
