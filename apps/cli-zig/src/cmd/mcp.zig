const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const config = @import("../lib/config.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const protocol = @import("../lib/mcp/protocol.zig");
const types = @import("../lib/mcp/types.zig");
const tools = @import("../lib/mcp/tools/index.zig");
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const McpServer = protocol.McpServer;
const IMcpToolContext = types.IMcpToolContext;
const registerAllMcpTools = tools.registerAllMcpTools;
const console = utils.console;
const standard_streams = utils.standard_streams;
const exit = node_utils.termination.exit;

//
// Options for the `psi mcp` command. No --db on purpose: the MCP client picks a
// database at runtime via the `list_databases` / `open_database` tools.
// (TypeScript: IMcpCommandOptions extends IBaseCommandOptions; the base options are in `base`.)
//
pub const IMcpCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},
};

//
// Server-level instructions describing what Photosphere is. Sent to MCP clients so the
// model knows when to use these tools and doesn't fall back on filesystem/shell tools
// for photo/video questions.
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
    "- save_media_file: save a media file (original, display, or thumbnail) to a path on disk\n" ++
    "- import_media_files: import photos/videos from files or directories into the open database\n" ++
    "- get_database_summary / verify_database: inspect or check the database's integrity";

//
// Creates the server of `psi mcp` with every tool registered against the tool context.
// (No TypeScript counterpart: the lines of mcpCommand that create the server, so that the tests can drive it without
// the standard streams.)
//
pub fn createMcpServer(allocator: std.mem.Allocator, toolContext: *IMcpToolContext) !*McpServer {
    const server = try allocator.create(McpServer);
    server.* = McpServer.init(
        allocator,
        .{
            .name = "photosphere",
            .version = config.version,
        },
        .{
            .instructions = PHOTOSPHERE_INSTRUCTIONS,
        },
    );
    try registerAllMcpTools(server, toolContext);
    return server;
}

//
// Implements the `psi mcp` command: a stdio MCP server with no database open by default.
// (Zig: when stdin closes the process ends through exit(), which runs the termination callbacks, so the worker pool
// is shut down and the session's temporary directory is removed.)
//
pub fn mcpCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IMcpCommandOptions) !void {
    //
    // No database is open at startup; the MCP client opens one via the open_database tool.
    //
    const toolContext = try allocator.create(IMcpToolContext);
    toolContext.* = .{
        .currentDatabase = null,
        .uuidGenerator = context.uuidGenerator,
        .timestampProvider = context.timestampProvider,
        .sessionId = context.sessionId,
        .options = options.base,
        .allocator = allocator,
    };

    const server = try createMcpServer(allocator, toolContext);

    //
    // Start the stdio transport. The MCP client owns this process's stdin/stdout.
    //
    var stdinBuffer: [64 * 1024]u8 = undefined;
    var stdinReader = standard_streams.stdin().readerStreaming(io, &stdinBuffer);
    console.@"error"("Photosphere MCP server running");

    //
    // Keep the process alive until stdin closes; then shut down cleanly.
    //
    try server.serve(io, &stdinReader.interface);

    exit(io, 0);
}
