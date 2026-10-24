//
// The MCP server the desktop app runs, so that an MCP client (an AI assistant) can work on the user's photos and videos while the app is
// open. It is a Streamable HTTP server on the loopback interface with the route `/mcp`. The port is fixed, so that a single client
// configuration keeps working between launches, except in test mode, where it is a free port so that two instances can run side by side.
//
// The server does none of the work itself. Every tool forwards its call to the page, which holds the open database and knows what the
// user is looking at, and gives the page's response back to the client: the server sends the page an `mcp-tool-request` event and waits
// for the page to reply with the `mcp-tool-response` message, which the main thread passes to the connection thread that holds the call.
//
// The server runs for the life of the app, started when the main window is created and stopped when the app stops (see
// MainState.mainWindowCreated and MainState.stop). A phone has no MCP server.
//

const std = @import("std");
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const serialization_zig = @import("serialization-zig");
const config = @import("config-zig");
const mcp = @import("mcp-zig");
const events = @import("events.zig");
const main_state = @import("main-state.zig");
const test_mode = @import("test-mode.zig");

const json = ziggy.json;
const HandlerServices = ziggy.core.HandlerServices;
const Timers = ziggy.timers.Timers;
const protocol = mcp.protocol;
const McpServer = protocol.McpServer;
const IField = mcp.input_schema.IField;
const HttpServer = node_utils.http_server.HttpServer;
const BsonDocument = serialization_zig.bson.BsonDocument;
const log = &utils.log.log;

//
// The fixed port of the MCP server. It is the same on every launch, so that one MCP client configuration keeps working without
// copying the address from the About page.
//
pub const MCP_PORT = 3475;

//
// The host the server binds. The server lets a client work on the user's photos, so it must only be reachable from this machine.
//
const MCP_HOST = "127.0.0.1";

//
// Server-level instructions describing what Photosphere is. Sent to MCP clients as part of the server's information so the model knows
// when to use these tools and does not fall back on filesystem or shell tools for photo and video questions.
//
pub const PHOTOSPHERE_INSTRUCTIONS =
    "Photosphere is a local-first photo and video management app (think Google Photos, but the user owns their data).\n" ++
    "It stores a database of media files (photos and videos) with metadata: filename, location, GPS coordinates, date taken, labels, description, content type, dimensions.\n" ++
    "\n" ++
    "Use these tools whenever the user asks about their photos, videos, image library, media collection, or photo database. Prefer these over filesystem tools (ls, find, Read) when the user is referring to media in their Photosphere library.\n" ++
    "\n" ++
    "Capabilities:\n" ++
    "- list_databases / open_database / close_database: choose which Photosphere database to work on\n" ++
    "- list_media_files: page through media files in the open database (newest first)\n" ++
    "- search_media_files: filter media files by filename, location, content type, or photo date range\n" ++
    "- get_media_file_info: full metadata for a single media file by id\n" ++
    "- open_media_file: show a media file to the user in the Photosphere gallery viewer\n" ++
    "- save_media_file: save a media file (original, display, or thumbnail) to a path on disk\n" ++
    "- import_media_files: import photos/videos from files or directories into the open database\n" ++
    "- update_media_file: edit description, labels, date, or location\n" ++
    "- delete_media_file: remove a media file\n" ++
    "- get_database_summary / verify_database: inspect or check the database's integrity";

//
// A tool the server offers: its name, what it does and the fields of its input.
//
const IToolDefinition = struct {
    // The name of the tool.
    name: []const u8,

    // What the tool does, for the model.
    description: []const u8,

    // The fields of the tool's input.
    inputSchema: []const IField,
};

//
// Every tool the server offers, in the order they are listed in. Each forwards its call to the page.
//
const tool_definitions = [_]IToolDefinition{
    .{
        .name = "get_database_summary",
        .description = "Get a high-level summary of the open Photosphere database (file count, total size, hashes).",
        .inputSchema = &.{},
    },
    .{
        .name = "list_media_files",
        .description = "List a page of media files (photos and videos) in the open Photosphere database, sorted by the date the photo or video was taken (newest first).",
        .inputSchema = &.{
            .{
                .name = "limit",
                .fieldType = .{
                    .integer = .{
                        .minimum = 1,
                        .maximum = 200,
                    },
                },
                .presence = .{
                    .default = .{
                        .number = 20,
                    },
                },
            },
            .{
                .name = "pageId",
                .fieldType = .string,
                .presence = .optional,
            },
        },
    },
    .{
        .name = "get_media_file_info",
        .description = "Return detailed metadata for a single media file (photo or video).",
        .inputSchema = &.{
            .{
                .name = "assetId",
                .fieldType = .string,
                .presence = .required,
            },
        },
    },
    .{
        .name = "search_media_files",
        .description = "Search photos and videos in the open Photosphere database by filename, location, content type, or photo date range. The full result set is shown to the user in the gallery; `limit` controls only how many matches are returned to you (raise it when the user asks for more).",
        .inputSchema = &.{
            .{
                .name = "query",
                .fieldType = .string,
                .presence = .{
                    .default = .{
                        .string = "",
                    },
                },
            },
            .{
                .name = "contentType",
                .fieldType = .string,
                .presence = .optional,
            },
            .{
                .name = "dateFrom",
                .fieldType = .string,
                .presence = .optional,
            },
            .{
                .name = "dateTo",
                .fieldType = .string,
                .presence = .optional,
            },
            .{
                .name = "limit",
                .fieldType = .{
                    .integer = .{
                        .minimum = 1,
                        .maximum = 200,
                    },
                },
                .presence = .{
                    .default = .{
                        .number = 10,
                    },
                },
            },
        },
    },
    .{
        .name = "save_media_file",
        .description = "Save a media file (photo or video) to a chosen path on disk. Type may be 'original', 'display' or 'thumb'.",
        .inputSchema = &.{
            .{
                .name = "assetId",
                .fieldType = .string,
                .presence = .required,
            },
            .{
                .name = "outputPath",
                .fieldType = .string,
                .presence = .required,
            },
            .{
                .name = "type",
                .fieldType = .{
                    .enumeration = &.{ "original", "display", "thumb" },
                },
                .presence = .{
                    .default = .{
                        .string = "original",
                    },
                },
            },
        },
    },
    .{
        .name = "open_media_file",
        .description = "Open a photo or video in the Photosphere gallery viewer so the user can see it.",
        .inputSchema = &.{
            .{
                .name = "assetId",
                .fieldType = .string,
                .presence = .required,
            },
        },
    },
    .{
        .name = "import_media_files",
        .description = "Import photos and videos from files or directories into the open Photosphere database. Set dryRun to preview without writing.",
        .inputSchema = &.{
            .{
                .name = "paths",
                .fieldType = .stringArray,
                .presence = .required,
            },
            .{
                .name = "dryRun",
                .fieldType = .boolean,
                .presence = .{
                    .default = .{
                        .boolean = false,
                    },
                },
            },
        },
    },
    .{
        .name = "open_database",
        .description = "Open a database from disk.",
        .inputSchema = &.{
            .{
                .name = "path",
                .fieldType = .string,
                .presence = .required,
            },
        },
    },
    .{
        .name = "close_database",
        .description = "Close the currently open database.",
        .inputSchema = &.{},
    },
    .{
        .name = "list_databases",
        .description = "List databases the host is aware of.",
        .inputSchema = &.{},
    },
    .{
        .name = "delete_media_file",
        .description = "Delete a media file (photo or video) by id.",
        .inputSchema = &.{
            .{
                .name = "assetId",
                .fieldType = .string,
                .presence = .required,
            },
        },
    },
    .{
        .name = "update_media_file",
        .description = "Update editable fields on a media file (description, labels, date taken, location).",
        .inputSchema = &.{
            .{
                .name = "assetId",
                .fieldType = .string,
                .presence = .required,
            },
            .{
                .name = "description",
                .fieldType = .string,
                .presence = .optional,
            },
            .{
                .name = "labels",
                .fieldType = .stringArray,
                .presence = .optional,
            },
            .{
                .name = "photoDate",
                .fieldType = .string,
                .presence = .optional,
            },
            .{
                .name = "location",
                .fieldType = .string,
                .presence = .optional,
            },
        },
    },
    .{
        .name = "verify_database",
        .description = "Run a full integrity check over the open database.",
        .inputSchema = &.{},
    },
};

//
// The most connection threads the MCP server starts. A client makes a handful of calls at once at most.
//
const MAX_CONNECTION_THREADS = 4;

//
// How long a tool call waits for a message to its connection thread at a time, in milliseconds, before it looks again.
//
const RESPONSE_WAIT_MS = 1000;

//
// The type of the message the main thread passes the page's response to a tool call on in, to the connection thread that holds the call.
//
pub const TOOL_RESPONSE_TYPE = "mcp-tool-response";

//
// The page's response to a tool call, as the main thread passes it to the server: the call's id in `key`, which the connection thread
// holding the call holds.
//
const IToolResponse = struct {
    // Always TOOL_RESPONSE_TYPE.
    type: []const u8 = TOOL_RESPONSE_TYPE,
    // The id of the tool call this responds to.
    key: []const u8,
    // Whether the page failed to do what the tool requested.
    failed: bool,
    // The text of the result, or the reason for the failure.
    text: []const u8,
};

//
// What one connection thread of the server keeps: an MCP server of its own with every tool registered, and what its tools need to
// forward their calls to the page. Made and freed on the thread, with the thread's own allocator.
//
pub const McpConnection = struct {
    // The MCP server. The connection thread's state for the HTTP framework points at it.
    server: McpServer,
    // The thread's copy of the native app's callbacks, through which the thread sends the page each tool call itself.
    native_callbacks: ziggy.core.NativeCallbacks,
    // Makes the ids of the tool calls.
    uuids: utils.random_uuid_generator.RandomUuidGenerator,
    // What each tool is called with, one for each of tool_definitions, in the same order.
    forwarding: [tool_definitions.len]IForwardingTool,
};

//
// The type of the app event a connection thread sends the page a tool call in.
//
pub const TOOL_REQUEST_TYPE = "mcp-tool-request";

//
// What a tool needs to forward its call to the page. The connection thread's server holds one for each tool.
//
pub const IForwardingTool = struct {
    // The connection the tool belongs to.
    connection: *McpConnection,

    // The name of the tool, which the page dispatches on.
    tool: []const u8,
};

//
// Gives the connection its MCP server with every tool registered, each forwarding its call to the page through the connection. The list of
// tools is allocated with the allocator, the connection thread's own, which frees it with McpServer.deinit.
//
fn registerTools(connection: *McpConnection, allocator: std.mem.Allocator) !void {
    connection.server = McpServer.init(.{
        .name = "photosphere",
        .version = config.version,
    }, .{
        .instructions = PHOTOSPHERE_INSTRUCTIONS,
    });
    errdefer connection.server.deinit(allocator);
    for (tool_definitions, &connection.forwarding) |definition, *forwarding| {
        forwarding.* = .{
            .connection = connection,
            .tool = definition.name,
        };
        try connection.server.registerTool(allocator, definition.name, .{
            .description = definition.description,
            .inputSchema = definition.inputSchema,
        }, forwarding, forwardToPage);
    }
}

//
// The handler of every tool: sends the call to the page and gives back the page's response. The connection thread holds the call,
// so the main thread's message with the page's response is passed to it. A failure of the page is the failure of the tool, with the page's
// reason as its text, and a server that stops while the call waits ends it as cancelled.
//
fn forwardToPage(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, arguments: BsonDocument) anyerror!protocol.ICallToolResult {
    const forwarding: *IForwardingTool = @ptrCast(@alignCast(context.?));
    const connection = forwarding.connection;
    const request = node_utils.http_server.currentRequest() orelse {
        return utils.errors.throwError("A tool was called outside a request.", .{});
    };
    const arguments_json = try protocol.stringifyCompact(allocator, .{
        .document = arguments,
    });
    const request_id = try connection.uuids.uuidGenerator().generate(allocator, io);
    // The call is held before the page is told of it, so the page's result can never arrive for a call nobody holds. The thread sends
    // the page the call itself, through the native app's callbacks.
    try request.hold(io, allocator, request_id);
    try events.sendEvent(connection.native_callbacks, io, allocator, TOOL_REQUEST_TYPE, .{
        .requestId = request_id,
        .tool = forwarding.tool,
        .args = try std.json.parseFromSliceLeaky(std.json.Value, allocator, arguments_json, .{}),
    });
    while (true) {
        const message = request.waitForMessage(io, allocator, RESPONSE_WAIT_MS) orelse {
            if (request.stopped) {
                return error.Cancelled;
            }
            continue;
        };
        defer allocator.free(message.text);
        const response = try std.json.parseFromSliceLeaky(IToolResponse, allocator, message.text, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        if (!std.mem.eql(u8, response.key, request_id)) {
            continue;
        }
        if (response.failed) {
            return utils.errors.throwError("{s}", .{response.text});
        }
        const content = try allocator.alloc(protocol.ITextContent, 1);
        content[0] = .{
            .text = response.text,
        };
        return .{
            .content = content,
        };
    }
}

//
// The mcp-tool-response message: the page's response to a tool call. The payload holds the `requestId` of the call and either a `result`, the
// text to give the client, or an `error`, the reason the page could not do what was requested. It is passed to the MCP server, whose
// connection thread holding the call gives it to the client. The response is null.
//
pub fn mcpToolResponseHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: McpToolResponseRequest) !void {
    _ = services;
    _ = timers;
    const state = main_state.current();
    const running = state.mcp_server orelse {
        return;
    };
    const failure = request.@"error" orelse "";
    const text = try json.stringify(allocator, IToolResponse{
        .key = request.requestId,
        .failed = failure.len > 0,
        .text = if (failure.len > 0) failure else request.result orelse "",
    });
    try running.http_server.post(io, text);
}

//
// The data of mcp-tool-response.
//
pub const McpToolResponseRequest = struct {
    // The id of the tool call this responds to.
    requestId: []const u8,
    // The text to give the client, or null when the call failed.
    result: ?[]const u8 = null,
    // Why the page could not do what was asked, or null when it could.
    @"error": ?[]const u8 = null,
};

//
// The port the server asks for: the fixed one, or a free one (0) in test mode so that two instances running together do not collide.
//
fn requestedPort() u16 {
    return if (test_mode.isTestMode()) 0 else MCP_PORT;
}

//
// The MCP server while it runs: an HTTP server of Photosphere's own, not a task, so it holds no worker. It was a task that slept until it
// was cancelled, which held a worker for the life of the app: with the asset server holding another, a machine with three cores (the
// macOS arm64 GitHub runner) had one worker left, the import took it and waited for the work it queued, which had no worker to run on,
// and every import in the macOS arm64 release workflow's app smoke tests timed out. Owned by the main state, which stops it. No
// connection thread holds it: each has an MCP server of its own and a copy of the native app's callbacks.
//
pub const RunningMcpServer = struct {
    // The HTTP server.
    http_server: *HttpServer,
    // The port the server is listening on.
    port: u16,

    //
    // Stops the server, which tells the calls and the open streams to end, waits for its threads and frees it.
    //
    pub fn stop(self: *RunningMcpServer, io: std.Io, allocator: std.mem.Allocator) void {
        self.http_server.stop(io, allocator);
        allocator.destroy(self);
    }
};

//
// Starts the MCP server and returns it running, on the main thread. Each connection thread is given a copy of the native app's
// callbacks, through which it sends the page its tool calls itself. The server is not started in test mode on the fixed port, but on a
// free one. A failure to listen (the port is taken, for example) is returned, and the caller carries on without the server.
//
pub fn startMcpServer(allocator: std.mem.Allocator, io: std.Io, native_callbacks: ziggy.core.NativeCallbacks) !*RunningMcpServer {
    const running = try allocator.create(RunningMcpServer);
    errdefer allocator.destroy(running);
    const listener = try node_utils.http_server.open(io, MCP_HOST, requestedPort());
    running.* = .{
        .http_server = undefined,
        .port = listener.port,
    };
    running.http_server = try HttpServer.start(io, allocator, listener, .{
        // The routes hold nothing: each request is given to the MCP server of the connection thread it arrives on.
        .router = mcp.streamable_http.StreamableHttpRoutes.router,
        .maxConnectionThreads = MAX_CONNECTION_THREADS,
        .connectionState = .{
            .create = createConnection,
            .destroy = destroyConnection,
        },
        .nativeCallbacks = native_callbacks,
        .environment = node_utils.process_env.getEnvironMap(),
    });
    var buffer: [64]u8 = undefined;
    log.info(std.fmt.bufPrint(&buffer, "MCP server initialized on port {d}", .{running.port}) catch "MCP server initialized");
    return running;
}

//
// Makes the state of one connection thread, on the thread: its own MCP server. The state the HTTP framework holds is the server inside
// it.
//
fn createConnection(connection_config: []const u8, native_callbacks: ?*const ziggy.core.NativeCallbacks, allocator: std.mem.Allocator, io: std.Io) anyerror!*anyopaque {
    _ = connection_config;
    _ = io;
    const connection = try allocator.create(McpConnection);
    errdefer allocator.destroy(connection);
    connection.* = .{
        .server = undefined,
        .native_callbacks = (native_callbacks orelse return error.McpServerNeedsTheNativeCallbacks).*,
        .uuids = .{},
        .forwarding = undefined,
    };
    try registerTools(connection, allocator);
    return &connection.server;
}

//
// Frees the state of one connection thread, on the thread, with the thread's allocator that made it.
//
fn destroyConnection(state: *anyopaque, allocator: std.mem.Allocator) void {
    const server: *McpServer = @ptrCast(@alignCast(state));
    const connection: *McpConnection = @fieldParentPtr("server", server);
    connection.server.deinit(allocator);
    allocator.destroy(connection);
}

