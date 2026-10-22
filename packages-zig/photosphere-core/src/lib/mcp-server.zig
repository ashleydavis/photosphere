//
// The MCP server the desktop app runs, so that an MCP client (an AI assistant) can work on the user's photos and videos while the app is
// open. It is a Streamable HTTP server on the loopback interface with the route `/mcp`. The port is fixed, so that a single client
// configuration keeps working between launches, except in test mode, where it is a free port so that two instances can run side by side.
//
// The server does none of the work itself. Every tool forwards its call to the page, which holds the open database and knows what the
// user is looking at, and gives the page's answer back to the client: the server sends the page an `mcp-tool-request` event and waits
// for the page to answer on the `mcp-tool-response` message (see mcp-bridge.zig).
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
const mcp_bridge = @import("mcp-bridge.zig");
const test_mode = @import("test-mode.zig");

const Core = ziggy.core.Core;
const json = ziggy.json;
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
// Allocates the server and the threads of its connections, which use it from many threads at once, so it has to be thread safe.
//
const server_allocator = std.heap.smp_allocator;

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
// What a tool needs to forward its call to the page. The server holds one for each tool, for as long as it runs.
//
pub const IForwardingTool = struct {
    // The main process's state, which holds the bridge and tells when the app is stopping.
    state: *main_state.MainState,

    // The name of the tool, which the page dispatches on.
    tool: []const u8,

    // Set when the server is stopping, so a call that is waiting for the page gives up.
    stopping: *const std.atomic.Value(bool),
};

//
// Creates the MCP server with every tool registered, each forwarding its call to the page. Everything it allocates, the tools and what they
// are called with included, is allocated with the allocator, which must live as long as the server does.
//
pub fn createMcpServer(allocator: std.mem.Allocator, state: *main_state.MainState, stopping: *const std.atomic.Value(bool)) !*McpServer {
    const server = try allocator.create(McpServer);
    server.* = McpServer.init(allocator, .{
        .name = "photosphere",
        .version = config.version,
    }, .{
        .instructions = PHOTOSPHERE_INSTRUCTIONS,
    });
    for (tool_definitions) |definition| {
        const forwarding = try allocator.create(IForwardingTool);
        forwarding.* = .{
            .state = state,
            .tool = definition.name,
            .stopping = stopping,
        };
        try server.registerTool(definition.name, .{
            .description = definition.description,
            .inputSchema = definition.inputSchema,
        }, forwarding, forwardToPage);
    }
    return server;
}

//
// The handler of every tool: sends the call to the page and gives back what the page answers. A failure of the page is the failure of the
// tool, with the page's reason as its text.
//
fn forwardToPage(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, arguments: BsonDocument) anyerror!protocol.ICallToolResult {
    const forwarding: *IForwardingTool = @ptrCast(@alignCast(context.?));
    const state = forwarding.state;
    const arguments_json = try protocol.stringifyCompact(allocator, .{
        .document = arguments,
    });
    const request_id = try state.uuid_generator.generate(allocator, io);
    // The bridge is told before the page is, so the answer can never arrive for a request it does not know.
    try state.mcp_bridge.begin(request_id);
    errdefer state.mcp_bridge.cancel(request_id);
    try events.sendEvent(state.core, allocator, "mcp-tool-request", .{
        .requestId = request_id,
        .tool = forwarding.tool,
        .args = try std.json.parseFromSliceLeaky(std.json.Value, allocator, arguments_json, .{}),
    });
    const answer = try state.mcp_bridge.wait(allocator, request_id, forwarding.stopping);
    if (answer.failed) {
        return utils.errors.throwError("{s}", .{answer.text});
    }
    const content = try allocator.alloc(protocol.ITextContent, 1);
    content[0] = .{
        .text = answer.text,
    };
    return .{
        .content = content,
    };
}

//
// The mcp-tool-response message: the page's answer to a tool call. The payload holds the `requestId` of the call and either a `result`, the
// text to give the client, or an `error`, the reason the page could not do what was asked. The response is null.
//
pub fn mcpToolResponseHandler(core: *Core, arena: std.mem.Allocator, request: McpToolResponseRequest) !void {
    _ = arena;
    const state = main_state.fromCore(core);
    const failure = request.@"error" orelse "";
    if (failure.len > 0) {
        try state.mcp_bridge.respond(request.requestId, true, failure);
    }
    else {
        try state.mcp_bridge.respond(request.requestId, false, request.result orelse "");
    }
}

//
// The data of mcp-tool-response.
//
pub const McpToolResponseRequest = struct {
    // The id of the tool call this answers.
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
// The MCP server while it runs. Its HTTP server answers requests on threads of its own, so the server holds no worker of the task runner.
// It was a task that slept until it was cancelled, which held a worker for the life of the app: with the asset server holding another,
// a machine with three cores (the macOS arm64 GitHub runner) had one worker left, the import took it and waited for the work it queued,
// which had no worker to run on, and every import in the macOS arm64 release workflow's app smoke tests timed out. Owned by the main
// state, which stops it.
//
pub const RunningMcpServer = struct {
    // Holds the MCP server's tools and sessions.
    arena_state: std.heap.ArenaAllocator,
    // Tells the calls and the streams that are waiting that the server is closing.
    stopping: std.atomic.Value(bool),
    // What the HTTP server answers requests with, which points at the MCP server.
    routes: mcp.streamable_http.StreamableHttpRoutes,
    // The HTTP server.
    http_server: *HttpServer,

    //
    // Closes the server and frees it. The calls and the streams that are waiting are told first, so that closing the server, which waits
    // for the requests being answered, does not wait for a page that will never answer.
    //
    pub fn stop(self: *RunningMcpServer, state: *main_state.MainState) void {
        self.stopping.store(true, .release);
        self.http_server.close();
        state.mcp_bridge.port.store(0, .release);
        self.arena_state.deinit();
        server_allocator.destroy(self);
    }
};

//
// Starts the MCP server and returns it running. The server is not started in test mode on the fixed port, but on a free one, and the
// port it bound is kept in the bridge. A failure to listen (the port is taken, say) is returned, and the caller carries on without the
// server.
//
pub fn startMcpServer(state: *main_state.MainState, io: std.Io) !*RunningMcpServer {
    const running = try server_allocator.create(RunningMcpServer);
    errdefer server_allocator.destroy(running);
    running.arena_state = std.heap.ArenaAllocator.init(server_allocator);
    errdefer running.arena_state.deinit();
    running.stopping = .init(false);
    const server = try createMcpServer(running.arena_state.allocator(), state, &running.stopping);
    running.routes = .{
        .server = server,
        .stopping = &running.stopping,
    };
    running.http_server = try HttpServer.listen(server_allocator, io, MCP_HOST, requestedPort(), running.routes.requestHandler());
    errdefer running.http_server.close();
    const initialized = try std.fmt.allocPrint(running.arena_state.allocator(), "MCP server initialized on port {d}", .{running.http_server.port});
    state.mcp_bridge.port.store(running.http_server.port, .release);
    log.info(initialized);
    return running;
}
