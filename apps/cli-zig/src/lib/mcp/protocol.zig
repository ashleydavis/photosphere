const std = @import("std");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const bdb = @import("bdb-zig");
const input_schema = @import("input-schema.zig");
const BsonValue = serialization_zig.bson.BsonValue;
const BsonDocument = serialization_zig.bson.BsonDocument;
const jsonParse = serialization_zig.json_parse.jsonParse;
const writeNumber = serialization_zig.js_number.writeNumber;
const writeJsonString = bdb.js_value.writeJsonString;
const IField = input_schema.IField;
const console = utils.console;

//
// No TypeScript counterpart: stands in for the parts of the MCP TypeScript SDK (@modelcontextprotocol/sdk) that
// `psi mcp` uses: McpServer (initialize, ping, tools/list and tools/call) and StdioServerTransport (newline-delimited
// JSON-RPC 2.0 messages on stdin and stdout). It is written from the MCP specification
// (https://modelcontextprotocol.io/specification) and answers the way SDK version 1.29 does, so that a client sees the
// same responses from both CLIs.
//
// Differences from the SDK:
// - Requests are handled one at a time, in the order they arrive. The SDK starts each request as it arrives, so its
//   responses can come back in a different order than the requests.
// - A line that is not JSON gets a Parse error (-32700) and a message that is not a JSON-RPC 2.0 message gets an
//   Invalid Request error (-32600), as JSON-RPC 2.0 requires; so does a request whose params is not an object, which
//   MCP requires. The SDK reports these to its onerror handler and answers nothing.
// - The params of a request are checked for the fields this server reads (the SDK checks the whole schema of the
//   request); an issue is reported the way the SDK reports it.
//

//
// The newest protocol version (the SDK's LATEST_PROTOCOL_VERSION). The server answers with it when the client asks
// for a version it does not support.
//
pub const LATEST_PROTOCOL_VERSION = "2025-11-25";

//
// The protocol versions the server supports (the SDK's SUPPORTED_PROTOCOL_VERSIONS). The server answers with the
// version the client asks for when it is one of these.
//
pub const SUPPORTED_PROTOCOL_VERSIONS = [_][]const u8{ LATEST_PROTOCOL_VERSION, "2025-06-18", "2025-03-26", "2024-11-05", "2024-10-07" };

//
// The JSON-RPC 2.0 error codes the server uses (the SDK's ErrorCode).
//
pub const ErrorCode = struct {
    // The line is not JSON.
    pub const ParseError: f64 = -32700;

    // The JSON is not a JSON-RPC 2.0 request or notification.
    pub const InvalidRequest: f64 = -32600;

    // The method does not exist.
    pub const MethodNotFound: f64 = -32601;

    // The params of the method are not valid.
    pub const InvalidParams: f64 = -32602;

    // The server failed while handling the request.
    pub const InternalError: f64 = -32603;
};

//
// A text content block of a tool result (the SDK's TextContent).
//
pub const ITextContent = struct {
    // The content type, always "text".
    type: []const u8 = "text",

    // The text.
    text: []const u8,
};

//
// The result of a tool call (the SDK's CallToolResult, limited to the text content these tools return).
//
pub const ICallToolResult = struct {
    // The content blocks of the result.
    content: []const ITextContent,

    // True when the tool failed (left out of the result when null).
    isError: ?bool = null,
};

//
// The description and input of a tool (the config of the SDK's registerTool).
//
pub const IToolConfig = struct {
    // What the tool does, for the model.
    description: []const u8,

    // The fields of the tool's input (the zod raw shape).
    inputSchema: []const IField,
};

//
// A tool's handler (the callback of the SDK's registerTool): called with the context it was registered with and the
// parsed arguments. An error it returns becomes an error result of the tool, like an exception the callback throws.
// The allocator only lives until the response to the call has been written.
//
pub const IToolHandler = *const fn (context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, arguments: BsonDocument) anyerror!ICallToolResult;

//
// A tool registered with the server.
//
const IRegisteredTool = struct {
    // The name of the tool.
    name: []const u8,

    // The description and input of the tool.
    config: IToolConfig,

    // The context the handler is called with.
    context: ?*anyopaque,

    // The handler.
    handler: IToolHandler,
};

//
// The name and version the server reports to the client (the SDK's Implementation).
//
pub const IServerInfo = struct {
    // The name of the server.
    name: []const u8,

    // The version of the server.
    version: []const u8,
};

//
// The options of the server (the SDK's ServerOptions, limited to the ones `psi mcp` gives).
//
pub const IServerOptions = struct {
    // What the server is for, sent to the client in the result of initialize.
    instructions: []const u8,
};

//
// The failure of a request: the error of a JSON-RPC error response (the SDK's McpError).
//
const IRequestError = struct {
    // The JSON-RPC error code.
    code: f64,

    // The message.
    message: []const u8,
};

//
// The outcome of handling a request: its result, or the error to answer it with.
//
const IRequestOutcome = union(enum) {
    // The result of the request.
    result: BsonValue,

    // The error of the request.
    failure: IRequestError,
};

//
// An MCP server with tools (the SDK's McpServer).
//
pub const McpServer = struct {
    // Allocates the registered tools.
    allocator: std.mem.Allocator,

    // The name and version reported to the client.
    serverInfo: IServerInfo,

    // The options of the server.
    options: IServerOptions,

    // The registered tools, in the order they were registered (the order tools/list reports them in).
    tools: std.ArrayList(IRegisteredTool) = .empty,

    //
    // Creates a server with no tools.
    //
    pub fn init(allocator: std.mem.Allocator, serverInfo: IServerInfo, options: IServerOptions) McpServer {
        return .{
            .allocator = allocator,
            .serverInfo = serverInfo,
            .options = options,
        };
    }

    //
    // Registers a tool. Fails when a tool with the name is already registered, like the SDK.
    //
    pub fn registerTool(self: *McpServer, name: []const u8, config: IToolConfig, context: ?*anyopaque, handler: IToolHandler) !void {
        if (self.findTool(name) != null) {
            return utils.errors.throwError("Tool {s} is already registered", .{name});
        }
        try self.tools.append(self.allocator, .{
            .name = name,
            .config = config,
            .context = context,
            .handler = handler,
        });
    }

    //
    // Finds a registered tool by name.
    //
    fn findTool(self: *McpServer, name: []const u8) ?IRegisteredTool {
        for (self.tools.items) |tool| {
            if (std.mem.eql(u8, tool.name, name)) {
                return tool;
            }
        }
        return null;
    }

    //
    // Handles one line of input: a JSON-RPC message. Returns the line to answer with (without its newline), or null
    // when the message gets no answer (a notification, or a response). Everything is allocated with the allocator.
    //
    pub fn handleMessage(self: *McpServer, allocator: std.mem.Allocator, io: std.Io, line: []const u8) !?[]const u8 {
        const parsed = jsonParse(allocator, line) catch {
            return try errorResponse(allocator, .null, .{ .code = ErrorCode.ParseError, .message = "Parse error" });
        };
        const message = switch (parsed) {
            .document => |document| document,
            else => {
                return try errorResponse(allocator, .null, .{ .code = ErrorCode.InvalidRequest, .message = "Invalid Request" });
            },
        };
        const version = message.get("jsonrpc");
        if (version == null or version.? != .string or !std.mem.eql(u8, version.?.string, "2.0")) {
            return try errorResponse(allocator, validId(message) orelse .null, .{ .code = ErrorCode.InvalidRequest, .message = "Invalid Request" });
        }

        const method = message.get("method") orelse {
            if (message.get("id") != null and (message.get("result") != null or message.get("error") != null)) {
                // A response to a request of the server's; the server sends none, so there is nothing to match it to.
                return null;
            }
            return try errorResponse(allocator, validId(message) orelse .null, .{ .code = ErrorCode.InvalidRequest, .message = "Invalid Request" });
        };
        if (method != .string) {
            return try errorResponse(allocator, validId(message) orelse .null, .{ .code = ErrorCode.InvalidRequest, .message = "Invalid Request" });
        }

        if (message.get("id") == null) {
            // A notification (notifications/initialized, notifications/cancelled, ...): nothing to answer.
            return null;
        }
        const id = validId(message) orelse {
            return try errorResponse(allocator, .null, .{ .code = ErrorCode.InvalidRequest, .message = "Invalid Request" });
        };

        // MCP requests carry their params as an object.
        const params = message.get("params");
        if (params != null and params.? != .document) {
            return try errorResponse(allocator, id, .{ .code = ErrorCode.InvalidRequest, .message = "Invalid Request" });
        }

        const outcome = try self.handleRequest(allocator, io, method.string, params);
        return switch (outcome) {
            .result => |result| try resultResponse(allocator, id, result),
            .failure => |failure| try errorResponse(allocator, id, failure),
        };
    }

    //
    // Handles a request: dispatches on its method.
    //
    fn handleRequest(self: *McpServer, allocator: std.mem.Allocator, io: std.Io, method: []const u8, params: ?BsonValue) !IRequestOutcome {
        if (std.mem.eql(u8, method, "initialize")) {
            return self.handleInitialize(allocator, params);
        }
        if (std.mem.eql(u8, method, "ping")) {
            return .{ .result = .{ .document = .empty } };
        }
        if (std.mem.eql(u8, method, "tools/list")) {
            return self.handleToolsList(allocator, params);
        }
        if (std.mem.eql(u8, method, "tools/call")) {
            return self.handleToolsCall(allocator, io, params);
        }
        return .{ .failure = .{ .code = ErrorCode.MethodNotFound, .message = "Method not found" } };
    }

    //
    // Handles initialize: agrees on the protocol version and reports the server's capabilities, name, version and
    // instructions.
    //
    fn handleInitialize(self: *McpServer, allocator: std.mem.Allocator, params: ?BsonValue) !IRequestOutcome {
        var issues: std.ArrayList(BsonValue) = .empty;
        const paramsDocument = try requireDocument(allocator, &issues, params, &.{.{ .string = "params" }}, "object");
        var requestedVersion: ?[]const u8 = null;
        if (paramsDocument) |document| {
            requestedVersion = try requireString(allocator, &issues, document, "protocolVersion", &.{ .{ .string = "params" }, .{ .string = "protocolVersion" } });
            _ = try requireDocument(allocator, &issues, document.get("capabilities"), &.{ .{ .string = "params" }, .{ .string = "capabilities" } }, "object");
            const clientInfo = try requireDocument(allocator, &issues, document.get("clientInfo"), &.{ .{ .string = "params" }, .{ .string = "clientInfo" } }, "object");
            if (clientInfo) |info| {
                _ = try requireString(allocator, &issues, info, "name", &.{ .{ .string = "params" }, .{ .string = "clientInfo" }, .{ .string = "name" } });
                _ = try requireString(allocator, &issues, info, "version", &.{ .{ .string = "params" }, .{ .string = "clientInfo" }, .{ .string = "version" } });
            }
        }
        if (issues.items.len > 0) {
            return .{ .failure = .{ .code = ErrorCode.InternalError, .message = try input_schema.formatIssues(allocator, issues.items) } };
        }

        var protocolVersion: []const u8 = LATEST_PROTOCOL_VERSION;
        for (SUPPORTED_PROTOCOL_VERSIONS) |supported| {
            if (std.mem.eql(u8, supported, requestedVersion.?)) {
                protocolVersion = supported;
            }
        }

        var tools: BsonDocument = .empty;
        try tools.put(allocator, "listChanged", .{ .boolean = true });
        var capabilities: BsonDocument = .empty;
        try capabilities.put(allocator, "tools", .{ .document = tools });
        var serverInfo: BsonDocument = .empty;
        try serverInfo.put(allocator, "name", .{ .string = self.serverInfo.name });
        try serverInfo.put(allocator, "version", .{ .string = self.serverInfo.version });
        var result: BsonDocument = .empty;
        try result.put(allocator, "protocolVersion", .{ .string = protocolVersion });
        try result.put(allocator, "capabilities", .{ .document = capabilities });
        try result.put(allocator, "serverInfo", .{ .document = serverInfo });
        try result.put(allocator, "instructions", .{ .string = self.options.instructions });
        return .{ .result = .{ .document = result } };
    }

    //
    // Handles tools/list: reports every tool with its description and the JSON Schema of its input.
    //
    fn handleToolsList(self: *McpServer, allocator: std.mem.Allocator, params: ?BsonValue) !IRequestOutcome {
        var issues: std.ArrayList(BsonValue) = .empty;
        if (params) |paramsValue| {
            const cursor = paramsValue.document.get("cursor");
            if (cursor != null and cursor.? != .string) {
                try issues.append(allocator, try input_schema.invalidTypeIssue4(allocator, "string", cursor, &.{ .{ .string = "params" }, .{ .string = "cursor" } }));
            }
        }
        if (issues.items.len > 0) {
            return .{ .failure = .{ .code = ErrorCode.InternalError, .message = try input_schema.formatIssues(allocator, issues.items) } };
        }

        const toolList = try allocator.alloc(BsonValue, self.tools.items.len);
        for (self.tools.items, 0..) |tool, toolIndex| {
            var execution: BsonDocument = .empty;
            try execution.put(allocator, "taskSupport", .{ .string = "forbidden" });
            var definition: BsonDocument = .empty;
            try definition.put(allocator, "name", .{ .string = tool.name });
            try definition.put(allocator, "description", .{ .string = tool.config.description });
            try definition.put(allocator, "inputSchema", try input_schema.toJsonSchema(allocator, tool.config.inputSchema));
            try definition.put(allocator, "execution", .{ .document = execution });
            toolList[toolIndex] = .{ .document = definition };
        }
        var result: BsonDocument = .empty;
        try result.put(allocator, "tools", .{ .array = toolList });
        return .{ .result = .{ .document = result } };
    }

    //
    // Handles tools/call: checks the arguments against the tool's input and calls the tool. An unknown tool, invalid
    // arguments and a failing tool all give a result with isError set, like the SDK.
    //
    fn handleToolsCall(self: *McpServer, allocator: std.mem.Allocator, io: std.Io, params: ?BsonValue) !IRequestOutcome {
        var issues: std.ArrayList(BsonValue) = .empty;
        const paramsDocument = try requireDocument(allocator, &issues, params, &.{.{ .string = "params" }}, "object");
        var name: ?[]const u8 = null;
        var arguments: ?BsonDocument = null;
        if (paramsDocument) |document| {
            name = try requireString(allocator, &issues, document, "name", &.{ .{ .string = "params" }, .{ .string = "name" } });
            const argumentsValue = document.get("arguments");
            if (argumentsValue != null) {
                arguments = try requireDocument(allocator, &issues, argumentsValue, &.{ .{ .string = "params" }, .{ .string = "arguments" } }, "record");
            }
        }
        if (issues.items.len > 0) {
            return .{ .failure = .{ .code = ErrorCode.InternalError, .message = try input_schema.formatIssues(allocator, issues.items) } };
        }

        const tool = self.findTool(name.?) orelse {
            return .{ .result = try toolErrorResult(allocator, try mcpErrorMessage(allocator, ErrorCode.InvalidParams, try std.fmt.allocPrint(allocator, "Tool {s} not found", .{name.?}))) };
        };
        const parsedArguments = switch (try input_schema.parseArguments(allocator, tool.config.inputSchema, arguments)) {
            .success => |parsed| parsed,
            .failure => |argumentIssues| {
                const detail = try std.fmt.allocPrint(allocator, "Input validation error: Invalid arguments for tool {s}: {s}", .{ tool.name, try input_schema.formatIssues(allocator, argumentIssues) });
                return .{ .result = try toolErrorResult(allocator, try mcpErrorMessage(allocator, ErrorCode.InvalidParams, detail)) };
            },
        };
        const toolResult = tool.handler(tool.context, allocator, io, parsedArguments) catch |err| {
            return .{ .result = try toolErrorResult(allocator, utils.errors.errorMessage(err)) };
        };
        return .{ .result = try callToolResultValue(allocator, toolResult) };
    }

    //
    // Serves the MCP client on a stream of newline-delimited JSON-RPC messages (the SDK's StdioServerTransport on
    // stdin): answers each message on stdout as it arrives, and returns when the stream ends. Like the SDK, a last
    // line with no newline after it is not a message. Each message is handled with an allocator of its own, whose
    // memory is released once the answer has been written.
    //
    pub fn serve(self: *McpServer, io: std.Io, reader: *std.Io.Reader) !void {
        while (true) {
            var messageArena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer messageArena.deinit();
            const allocator = messageArena.allocator();

            var line: std.Io.Writer.Allocating = .init(allocator);
            _ = try reader.streamDelimiterEnding(&line.writer, '\n');
            _ = reader.takeByte() catch |err| {
                if (err == error.EndOfStream) {
                    return;
                }
                return err;
            };

            // The SDK drops the carriage return of a line that ends with CRLF.
            const text = std.mem.trimEnd(u8, line.written(), "\r");
            if (text.len == 0) {
                continue;
            }
            if (try self.handleMessage(allocator, io, text)) |response| {
                console.log(response);
            }
        }
    }
};

//
// The id of a message when it is one JSON-RPC allows (a string or a number), or null.
//
fn validId(message: BsonDocument) ?BsonValue {
    const id = message.get("id") orelse {
        return null;
    };
    return switch (id) {
        .string, .number => id,
        else => null,
    };
}

//
// A value that must be an object: the object, or null with an issue appended when the value is something else.
// `expected` is what the issue says was expected ("object", or "record" for a map of arbitrary keys).
//
fn requireDocument(allocator: std.mem.Allocator, issues: *std.ArrayList(BsonValue), value: ?BsonValue, path: []const BsonValue, expected: []const u8) !?BsonDocument {
    if (value != null and value.? == .document) {
        return value.?.document;
    }
    try issues.append(allocator, try input_schema.invalidTypeIssue4(allocator, expected, value, path));
    return null;
}

//
// A field of an object that must be a string: the string, or null with an issue appended when it is not one.
//
fn requireString(allocator: std.mem.Allocator, issues: *std.ArrayList(BsonValue), document: BsonDocument, name: []const u8, path: []const BsonValue) !?[]const u8 {
    const value = document.get(name);
    if (value != null and value.? == .string) {
        return value.?.string;
    }
    try issues.append(allocator, try input_schema.invalidTypeIssue4(allocator, "string", value, path));
    return null;
}

//
// The message of an McpError (`MCP error ${code}: ${message}`).
//
fn mcpErrorMessage(allocator: std.mem.Allocator, code: f64, message: []const u8) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    try output.writer.writeAll("MCP error ");
    try writeNumber(&output.writer, code);
    try output.writer.print(": {s}", .{message});
    return output.written();
}

//
// The result of a tool call that failed (the SDK's createToolError).
//
fn toolErrorResult(allocator: std.mem.Allocator, message: []const u8) !BsonValue {
    const content = try allocator.alloc(ITextContent, 1);
    content[0] = .{ .text = message };
    return callToolResultValue(allocator, .{ .content = content, .isError = true });
}

//
// The JSON value of a tool result.
//
fn callToolResultValue(allocator: std.mem.Allocator, toolResult: ICallToolResult) !BsonValue {
    const content = try allocator.alloc(BsonValue, toolResult.content.len);
    for (toolResult.content, 0..) |block, blockIndex| {
        var blockDocument: BsonDocument = .empty;
        try blockDocument.put(allocator, "type", .{ .string = block.type });
        try blockDocument.put(allocator, "text", .{ .string = block.text });
        content[blockIndex] = .{ .document = blockDocument };
    }
    var result: BsonDocument = .empty;
    try result.put(allocator, "content", .{ .array = content });
    if (toolResult.isError) |isError| {
        try result.put(allocator, "isError", .{ .boolean = isError });
    }
    return .{ .document = result };
}

//
// The line of a successful response, with the fields in the order the SDK writes them (result, jsonrpc, id).
//
fn resultResponse(allocator: std.mem.Allocator, id: BsonValue, result: BsonValue) ![]const u8 {
    var response: BsonDocument = .empty;
    try response.put(allocator, "result", result);
    try response.put(allocator, "jsonrpc", .{ .string = "2.0" });
    try response.put(allocator, "id", id);
    return stringifyCompact(allocator, .{ .document = response });
}

//
// The line of an error response, with the fields in the order the SDK writes them (jsonrpc, id, error).
//
fn errorResponse(allocator: std.mem.Allocator, id: BsonValue, failure: IRequestError) ![]const u8 {
    var errorDocument: BsonDocument = .empty;
    try errorDocument.put(allocator, "code", .{ .number = failure.code });
    try errorDocument.put(allocator, "message", .{ .string = failure.message });
    var response: BsonDocument = .empty;
    try response.put(allocator, "jsonrpc", .{ .string = "2.0" });
    try response.put(allocator, "id", id);
    try response.put(allocator, "error", .{ .document = errorDocument });
    return stringifyCompact(allocator, .{ .document = response });
}

//
// Formats a value like `JSON.stringify(value)` (no whitespace, undefined fields left out).
//
pub fn stringifyCompact(allocator: std.mem.Allocator, value: BsonValue) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    try writeCompact(&output.writer, value);
    return output.written();
}

//
// Writes a value as JSON with no whitespace. Values JSON has no form for (undefined in an array, dates, binaries)
// are written as null.
//
fn writeCompact(writer: *std.Io.Writer, value: BsonValue) !void {
    switch (value) {
        .number => |number| {
            if (std.math.isFinite(number)) {
                try writeNumber(writer, number);
            }
            else {
                try writer.writeAll("null");
            }
        },
        .string => |text| {
            try writeJsonString(writer, text);
        },
        .boolean => |boolean| {
            try writer.writeAll(if (boolean) "true" else "false");
        },
        .array => |elements| {
            try writer.writeAll("[");
            for (elements, 0..) |element, elementIndex| {
                if (elementIndex > 0) {
                    try writer.writeAll(",");
                }
                try writeCompact(writer, element);
            }
            try writer.writeAll("]");
        },
        .document => |document| {
            try writer.writeAll("{");
            var wroteField = false;
            for (document.fields.items) |field| {
                if (field.value == .undefined) {
                    continue;
                }
                if (wroteField) {
                    try writer.writeAll(",");
                }
                try writeJsonString(writer, field.key);
                try writer.writeAll(":");
                try writeCompact(writer, field.value);
                wroteField = true;
            }
            try writer.writeAll("}");
        },
        else => {
            try writer.writeAll("null");
        },
    }
}
