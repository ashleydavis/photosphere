const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const protocol = cli.mcp_protocol;
const input_schema = cli.mcp_input_schema;
const McpServer = protocol.McpServer;
const ICallToolResult = protocol.ICallToolResult;
const IField = input_schema.IField;
const BsonValue = serialization_zig.bson.BsonValue;
const BsonDocument = serialization_zig.bson.BsonDocument;
const jsonParse = serialization_zig.json_parse.jsonParse;
const io = std.testing.io;

//
// The expected responses of these tests are the ones the MCP TypeScript SDK (version 1.29, as `psi mcp` of
// apps/cli uses it) gives to the same requests, recorded from `bun run start -- mcp`.
//

//
// The input of the echo tool the tests register: every kind of field the psi tools use.
//
const echo_input = [_]IField{
    .{
        .name = "text",
        .fieldType = .string,
        .presence = .required,
    },
    .{
        .name = "count",
        .fieldType = .{
            .integer = .{
                .minimum = 1,
                .maximum = 200,
            },
        },
        .presence = .{
            .default = .{ .number = 20 },
        },
    },
    .{
        .name = "label",
        .fieldType = .string,
        .presence = .optional,
    },
    .{
        .name = "flag",
        .fieldType = .boolean,
        .presence = .{
            .default = .{ .boolean = false },
        },
    },
    .{
        .name = "names",
        .fieldType = .stringArray,
        .presence = .optional,
    },
    .{
        .name = "kind",
        .fieldType = .{
            .enumeration = &.{ "original", "display", "thumb" },
        },
        .presence = .{
            .default = .{ .string = "original" },
        },
    },
};

//
// The handler of the echo tool: answers with the JSON of the arguments it was called with.
//
fn echo(context: ?*anyopaque, allocator: std.mem.Allocator, toolIo: std.Io, arguments: BsonDocument) !ICallToolResult {
    _ = context;
    _ = toolIo;
    const content = try allocator.alloc(protocol.ITextContent, 1);
    content[0] = .{ .text = try protocol.stringifyCompact(allocator, .{ .document = arguments }) };
    return .{ .content = content };
}

//
// The handler of the failing tool: fails the way a TypeScript handler throws.
//
fn fail(context: ?*anyopaque, allocator: std.mem.Allocator, toolIo: std.Io, arguments: BsonDocument) !ICallToolResult {
    _ = context;
    _ = allocator;
    _ = toolIo;
    _ = arguments;
    return utils.errors.throwError("The tool broke: {s}", .{"on purpose"});
}

//
// Creates a server with the echo tool, a tool without input and the failing tool.
//
fn testServer(allocator: std.mem.Allocator) !McpServer {
    var server = McpServer.init(allocator, .{ .name = "test-server", .version = "1.2.3" }, .{ .instructions = "Use the tools." });
    try server.registerTool("echo", .{ .description = "Echoes its arguments.", .inputSchema = &echo_input }, null, echo);
    try server.registerTool("nothing", .{ .description = "Takes nothing.", .inputSchema = &.{} }, null, echo);
    try server.registerTool("fail", .{ .description = "Always fails.", .inputSchema = &.{} }, null, fail);
    return server;
}

//
// Sends one line to the server and expects the answer.
//
fn expectAnswer(server: *McpServer, allocator: std.mem.Allocator, line: []const u8, expected: ?[]const u8) !void {
    const answer = try server.handleMessage(allocator, io, line);
    if (expected) |expectedLine| {
        try std.testing.expectEqualStrings(expectedLine, answer orelse "(no answer)");
    }
    else {
        try std.testing.expectEqual(@as(?[]const u8, null), answer);
    }
}

test "initialize answers with the requested protocol version when it is supported, and the latest otherwise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var server = try testServer(allocator);

    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}
    ,
        \\{"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"test-server","version":"1.2.3"},"instructions":"Use the tools."},"jsonrpc":"2.0","id":1}
    );
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":"x","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}
    ,
        \\{"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"test-server","version":"1.2.3"},"instructions":"Use the tools."},"jsonrpc":"2.0","id":"x"}
    );
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}
    ,
        \\{"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"test-server","version":"1.2.3"},"instructions":"Use the tools."},"jsonrpc":"2.0","id":2}
    );
}

test "initialize reports the params it is missing the way the SDK does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var server = try testServer(allocator);

    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    ,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"[\n  {\n    \"expected\": \"string\",\n    \"code\": \"invalid_type\",\n    \"path\": [\n      \"params\",\n      \"protocolVersion\"\n    ],\n    \"message\": \"Invalid input: expected string, received undefined\"\n  },\n  {\n    \"expected\": \"object\",\n    \"code\": \"invalid_type\",\n    \"path\": [\n      \"params\",\n      \"capabilities\"\n    ],\n    \"message\": \"Invalid input: expected object, received undefined\"\n  },\n  {\n    \"expected\": \"object\",\n    \"code\": \"invalid_type\",\n    \"path\": [\n      \"params\",\n      \"clientInfo\"\n    ],\n    \"message\": \"Invalid input: expected object, received undefined\"\n  }\n]"}}
    );
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":2,"method":"initialize"}
    ,
        \\{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"[\n  {\n    \"expected\": \"object\",\n    \"code\": \"invalid_type\",\n    \"path\": [\n      \"params\"\n    ],\n    \"message\": \"Invalid input: expected object, received undefined\"\n  }\n]"}}
    );
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"version":5}}}
    ,
        \\{"jsonrpc":"2.0","id":3,"error":{"code":-32603,"message":"[\n  {\n    \"expected\": \"string\",\n    \"code\": \"invalid_type\",\n    \"path\": [\n      \"params\",\n      \"clientInfo\",\n      \"name\"\n    ],\n    \"message\": \"Invalid input: expected string, received undefined\"\n  },\n  {\n    \"expected\": \"string\",\n    \"code\": \"invalid_type\",\n    \"path\": [\n      \"params\",\n      \"clientInfo\",\n      \"version\"\n    ],\n    \"message\": \"Invalid input: expected string, received number\"\n  }\n]"}}
    );
}

test "ping answers with an empty result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var server = try testServer(allocator);

    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":7,"method":"ping"}
    ,
        \\{"result":{},"jsonrpc":"2.0","id":7}
    );
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":"p","method":"ping","params":{"_meta":{}}}
    ,
        \\{"result":{},"jsonrpc":"2.0","id":"p"}
    );
}

test "tools/list reports each tool with the JSON Schema of its input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var server = try testServer(allocator);

    const expected =
        \\{"result":{"tools":[{"name":"echo","description":"Echoes its arguments.","inputSchema":{"type":"object","properties":{"text":{"type":"string"},"count":{"type":"integer","minimum":1,"maximum":200,"default":20},"label":{"type":"string"},"flag":{"type":"boolean","default":false},"names":{"type":"array","items":{"type":"string"}},"kind":{"type":"string","enum":["original","display","thumb"],"default":"original"}},"required":["text"],"additionalProperties":false,"$schema":"http://json-schema.org/draft-07/schema#"},"execution":{"taskSupport":"forbidden"}},{"name":"nothing","description":"Takes nothing.","inputSchema":{"$schema":"http://json-schema.org/draft-07/schema#","type":"object","properties":{}},"execution":{"taskSupport":"forbidden"}},{"name":"fail","description":"Always fails.","inputSchema":{"$schema":"http://json-schema.org/draft-07/schema#","type":"object","properties":{}},"execution":{"taskSupport":"forbidden"}}]},"jsonrpc":"2.0","id":2}
    ;
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    , expected);
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{"cursor":5}}
    ,
        \\{"jsonrpc":"2.0","id":3,"error":{"code":-32603,"message":"[\n  {\n    \"expected\": \"string\",\n    \"code\": \"invalid_type\",\n    \"path\": [\n      \"params\",\n      \"cursor\"\n    ],\n    \"message\": \"Invalid input: expected string, received number\"\n  }\n]"}}
    );
}

test "the tools of psi mcp are listed with the input schemas the SDK reports for them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var toolContext: cli.mcp_types.IMcpToolContext = .{
        .uuidGenerator = undefined,
        .timestampProvider = undefined,
        .sessionId = "session",
        .options = .{},
        .allocator = allocator,
    };
    const server = try cli.mcp.createMcpServer(allocator, &toolContext);

    // The second line of mcp-session-expected.jsonl is the TypeScript CLI's answer to tools/list (id 2).
    const expected = try std.Io.Dir.cwd().readFileAlloc(io, "src/test/fixtures/mcp-session-expected.jsonl", allocator, .unlimited);
    var lines = std.mem.splitScalar(u8, expected, '\n');
    _ = lines.next();
    try expectAnswer(server, allocator,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    , lines.next().?);
}

test "tools/call calls the tool with its arguments checked, the defaults filled in and unknown fields left out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var server = try testServer(allocator);

    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{"extra":1,"text":"hi"}}}
    ,
        \\{"result":{"content":[{"type":"text","text":"{\"text\":\"hi\",\"count\":20,\"flag\":false,\"kind\":\"original\"}"}]},"jsonrpc":"2.0","id":4}
    );
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"echo","arguments":{"kind":"thumb","names":["a","b"],"flag":true,"label":"l","count":200,"text":""}}}
    ,
        \\{"result":{"content":[{"type":"text","text":"{\"text\":\"\",\"count\":200,\"label\":\"l\",\"flag\":true,\"names\":[\"a\",\"b\"],\"kind\":\"thumb\"}"}]},"jsonrpc":"2.0","id":5}
    );

    // A tool without input takes any arguments, and ignores them.
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nothing","arguments":{"x":1}}}
    ,
        \\{"result":{"content":[{"type":"text","text":"{}"}]},"jsonrpc":"2.0","id":6}
    );
}

test "tools/call answers an unknown tool, invalid arguments and a failing tool with an error result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var server = try testServer(allocator);

    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"nope","arguments":{}}}
    ,
        \\{"result":{"content":[{"type":"text","text":"MCP error -32602: Tool nope not found"}],"isError":true},"jsonrpc":"2.0","id":1}
    );
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fail","arguments":{}}}
    ,
        \\{"result":{"content":[{"type":"text","text":"The tool broke: on purpose"}],"isError":true},"jsonrpc":"2.0","id":2}
    );
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"count":"x"}}}
    ,
        \\{"result":{"content":[{"type":"text","text":"MCP error -32602: Input validation error: Invalid arguments for tool echo: [\n  {\n    \"code\": \"invalid_type\",\n    \"expected\": \"string\",\n    \"received\": \"undefined\",\n    \"path\": [\n      \"text\"\n    ],\n    \"message\": \"Required\"\n  },\n  {\n    \"code\": \"invalid_type\",\n    \"expected\": \"number\",\n    \"received\": \"string\",\n    \"path\": [\n      \"count\"\n    ],\n    \"message\": \"Expected number, received string\"\n  }\n]"}],"isError":true},"jsonrpc":"2.0","id":3}
    );

    // No arguments at all: zod 3 for an input with fields, zod 4 for an input without.
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo"}}
    ,
        \\{"result":{"content":[{"type":"text","text":"MCP error -32602: Input validation error: Invalid arguments for tool echo: [\n  {\n    \"code\": \"invalid_type\",\n    \"expected\": \"object\",\n    \"received\": \"undefined\",\n    \"path\": [],\n    \"message\": \"Required\"\n  }\n]"}],"isError":true},"jsonrpc":"2.0","id":4}
    );
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nothing"}}
    ,
        \\{"result":{"content":[{"type":"text","text":"MCP error -32602: Input validation error: Invalid arguments for tool nothing: [\n  {\n    \"expected\": \"object\",\n    \"code\": \"invalid_type\",\n    \"path\": [],\n    \"message\": \"Invalid input: expected object, received undefined\"\n  }\n]"}],"isError":true},"jsonrpc":"2.0","id":5}
    );
}

test "tools/call reports params that are missing or of the wrong type the way the SDK does" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var server = try testServer(allocator);

    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}
    ,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"[\n  {\n    \"expected\": \"string\",\n    \"code\": \"invalid_type\",\n    \"path\": [\n      \"params\",\n      \"name\"\n    ],\n    \"message\": \"Invalid input: expected string, received undefined\"\n  }\n]"}}
    );
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call"}
    ,
        \\{"jsonrpc":"2.0","id":2,"error":{"code":-32603,"message":"[\n  {\n    \"expected\": \"object\",\n    \"code\": \"invalid_type\",\n    \"path\": [\n      \"params\"\n    ],\n    \"message\": \"Invalid input: expected object, received undefined\"\n  }\n]"}}
    );
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":[]}}
    ,
        \\{"jsonrpc":"2.0","id":3,"error":{"code":-32603,"message":"[\n  {\n    \"expected\": \"record\",\n    \"code\": \"invalid_type\",\n    \"path\": [\n      \"params\",\n      \"arguments\"\n    ],\n    \"message\": \"Invalid input: expected record, received array\"\n  }\n]"}}
    );
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":null}}
    ,
        \\{"jsonrpc":"2.0","id":4,"error":{"code":-32603,"message":"[\n  {\n    \"expected\": \"record\",\n    \"code\": \"invalid_type\",\n    \"path\": [\n      \"params\",\n      \"arguments\"\n    ],\n    \"message\": \"Invalid input: expected record, received null\"\n  }\n]"}}
    );
}

test "unknown methods are not found, and notifications and responses get no answer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var server = try testServer(allocator);

    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":9,"method":"resources/list"}
    ,
        \\{"jsonrpc":"2.0","id":9,"error":{"code":-32601,"message":"Method not found"}}
    );
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    , null);
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","method":"notifications/whatever","params":{}}
    , null);
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":1,"result":{}}
    , null);
}

test "lines that are not JSON-RPC 2.0 requests are answered with the JSON-RPC errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var server = try testServer(allocator);

    try expectAnswer(&server, allocator, "not json",
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}
    );
    try expectAnswer(&server, allocator, "[]",
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request"}}
    );
    try expectAnswer(&server, allocator,
        \\{"id":1,"method":"ping"}
    ,
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid Request"}}
    );
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":2,"method":5}
    ,
        \\{"jsonrpc":"2.0","id":2,"error":{"code":-32600,"message":"Invalid Request"}}
    );
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":null,"method":"ping"}
    ,
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Invalid Request"}}
    );
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":3,"method":"ping","params":[]}
    ,
        \\{"jsonrpc":"2.0","id":3,"error":{"code":-32600,"message":"Invalid Request"}}
    );
    try expectAnswer(&server, allocator,
        \\{"jsonrpc":"2.0","id":4}
    ,
        \\{"jsonrpc":"2.0","id":4,"error":{"code":-32600,"message":"Invalid Request"}}
    );
}

test "registering a tool twice fails like the SDK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var server = try testServer(allocator);

    try std.testing.expectError(error.Thrown, server.registerTool("echo", .{ .description = "Again.", .inputSchema = &.{} }, null, echo));
    try std.testing.expectEqualStrings("Tool echo is already registered", utils.errors.lastErrorMessage());
}

test "serve answers each line on stdout and returns when its input ends" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var server = try testServer(allocator);
    var stdout_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(&stdout_capture.writer, null);
    defer utils.console.setCapture(null, null);

    // An empty line, a CRLF line, a notification, and a last line with no newline, which is not a message (like the
    // SDK's ReadBuffer, which only reads whole lines).
    var reader: std.Io.Reader = .fixed(
        "\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\r\n" ++
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"text\":\"a\"}}}\n" ++
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}",
    );
    try server.serve(io, &reader);

    try std.testing.expectEqualStrings(
        \\{"result":{},"jsonrpc":"2.0","id":1}
        \\{"result":{"content":[{"type":"text","text":"{\"text\":\"a\",\"count\":20,\"flag\":false,\"kind\":\"original\"}"}]},"jsonrpc":"2.0","id":2}
        \\
    , stdout_capture.written());
}

test "toJsonSchema writes the JSON Schema zod-to-json-schema writes, and the SDK's schema for an input without fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings(
        \\{"$schema":"http://json-schema.org/draft-07/schema#","type":"object","properties":{}}
    , try protocol.stringifyCompact(allocator, try input_schema.toJsonSchema(allocator, &.{})));

    // No field is required: the "required" list is left out.
    try std.testing.expectEqualStrings(
        \\{"type":"object","properties":{"query":{"type":"string","default":""},"pageId":{"type":"string"}},"additionalProperties":false,"$schema":"http://json-schema.org/draft-07/schema#"}
    , try protocol.stringifyCompact(allocator, try input_schema.toJsonSchema(allocator, &.{
        .{ .name = "query", .fieldType = .string, .presence = .{ .default = .{ .string = "" } } },
        .{ .name = "pageId", .fieldType = .string, .presence = .optional },
    })));
}

//
// Checks arguments against the echo input and expects the issues, as the SDK formats them.
//
fn expectIssues(allocator: std.mem.Allocator, argumentsJson: []const u8, expected: []const u8) !void {
    const arguments = (try jsonParse(allocator, argumentsJson)).document;
    const result = try input_schema.parseArguments(allocator, &echo_input, arguments);
    try std.testing.expect(result == .failure);
    try std.testing.expectEqualStrings(expected, try input_schema.formatIssues(allocator, result.failure));
}

test "parseArguments reports the issues zod 3 reports, for every field that has one, in the order of the fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Integer checks: not an integer, then below the minimum, then above the maximum; every one that fails.
    try expectIssues(allocator,
        \\{"text":"a","count":-0.5}
    ,
        \\[
        \\  {
        \\    "code": "invalid_type",
        \\    "expected": "integer",
        \\    "received": "float",
        \\    "message": "Expected integer, received float",
        \\    "path": [
        \\      "count"
        \\    ]
        \\  },
        \\  {
        \\    "code": "too_small",
        \\    "minimum": 1,
        \\    "type": "number",
        \\    "inclusive": true,
        \\    "exact": false,
        \\    "message": "Number must be greater than or equal to 1",
        \\    "path": [
        \\      "count"
        \\    ]
        \\  }
        \\]
    );
    try expectIssues(allocator,
        \\{"text":"a","count":1e400}
    ,
        \\[
        \\  {
        \\    "code": "invalid_type",
        \\    "expected": "integer",
        \\    "received": "float",
        \\    "message": "Expected integer, received float",
        \\    "path": [
        \\      "count"
        \\    ]
        \\  },
        \\  {
        \\    "code": "too_big",
        \\    "maximum": 200,
        \\    "type": "number",
        \\    "inclusive": true,
        \\    "exact": false,
        \\    "message": "Number must be less than or equal to 200",
        \\    "path": [
        \\      "count"
        \\    ]
        \\  }
        \\]
    );

    // A null is not undefined: the default does not apply, and the issue says what was received.
    try expectIssues(allocator,
        \\{"text":null,"count":null,"flag":"no"}
    ,
        \\[
        \\  {
        \\    "code": "invalid_type",
        \\    "expected": "string",
        \\    "received": "null",
        \\    "path": [
        \\      "text"
        \\    ],
        \\    "message": "Expected string, received null"
        \\  },
        \\  {
        \\    "code": "invalid_type",
        \\    "expected": "number",
        \\    "received": "null",
        \\    "path": [
        \\      "count"
        \\    ],
        \\    "message": "Expected number, received null"
        \\  },
        \\  {
        \\    "code": "invalid_type",
        \\    "expected": "boolean",
        \\    "received": "string",
        \\    "path": [
        \\      "flag"
        \\    ],
        \\    "message": "Expected boolean, received string"
        \\  }
        \\]
    );

    // Arrays report each element that is wrong, with its index in the path; enums report a value that is not one of
    // theirs, and a value that is not a string.
    try expectIssues(allocator,
        \\{"text":"a","names":[1,"b",true],"kind":"big"}
    ,
        \\[
        \\  {
        \\    "code": "invalid_type",
        \\    "expected": "string",
        \\    "received": "number",
        \\    "path": [
        \\      "names",
        \\      0
        \\    ],
        \\    "message": "Expected string, received number"
        \\  },
        \\  {
        \\    "code": "invalid_type",
        \\    "expected": "string",
        \\    "received": "boolean",
        \\    "path": [
        \\      "names",
        \\      2
        \\    ],
        \\    "message": "Expected string, received boolean"
        \\  },
        \\  {
        \\    "received": "big",
        \\    "code": "invalid_enum_value",
        \\    "options": [
        \\      "original",
        \\      "display",
        \\      "thumb"
        \\    ],
        \\    "path": [
        \\      "kind"
        \\    ],
        \\    "message": "Invalid enum value. Expected 'original' | 'display' | 'thumb', received 'big'"
        \\  }
        \\]
    );
    try expectIssues(allocator,
        \\{"text":{},"names":"a","kind":null}
    ,
        \\[
        \\  {
        \\    "code": "invalid_type",
        \\    "expected": "string",
        \\    "received": "object",
        \\    "path": [
        \\      "text"
        \\    ],
        \\    "message": "Expected string, received object"
        \\  },
        \\  {
        \\    "code": "invalid_type",
        \\    "expected": "array",
        \\    "received": "string",
        \\    "path": [
        \\      "names"
        \\    ],
        \\    "message": "Expected array, received string"
        \\  },
        \\  {
        \\    "expected": "'original' | 'display' | 'thumb'",
        \\    "received": "null",
        \\    "code": "invalid_type",
        \\    "path": [
        \\      "kind"
        \\    ],
        \\    "message": "Expected 'original' | 'display' | 'thumb', received null"
        \\  }
        \\]
    );
}

test "parsedType names values the way zod does" {
    try std.testing.expectEqualStrings("undefined", input_schema.parsedType(null));
    try std.testing.expectEqualStrings("null", input_schema.parsedType(.null));
    try std.testing.expectEqualStrings("string", input_schema.parsedType(.{ .string = "" }));
    try std.testing.expectEqualStrings("number", input_schema.parsedType(.{ .number = 1 }));
    try std.testing.expectEqualStrings("boolean", input_schema.parsedType(.{ .boolean = false }));
    try std.testing.expectEqualStrings("array", input_schema.parsedType(.{ .array = &.{} }));
    try std.testing.expectEqualStrings("object", input_schema.parsedType(.{ .document = .empty }));
}

test "stringifyCompact writes JSON like JSON.stringify" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const value = try jsonParse(allocator,
        \\{"a":[1,2.5,-3e-7,"x\"y\n",true,null,{}],"b":{"c":1e21}}
    );
    try std.testing.expectEqualStrings(
        \\{"a":[1,2.5,-3e-7,"x\"y\n",true,null,{}],"b":{"c":1e+21}}
    , try protocol.stringifyCompact(allocator, value));

    // Undefined fields are left out, like JSON.stringify leaves them out.
    var document: BsonDocument = .empty;
    try document.put(allocator, "gone", .undefined);
    try document.put(allocator, "kept", .{ .number = 1 });
    try std.testing.expectEqualStrings(
        \\{"kept":1}
    , try protocol.stringifyCompact(allocator, .{ .document = document }));
}
