const std = @import("std");
const serialization_zig = @import("serialization-zig");
const protocol = @import("../protocol.zig");
const result = @import("../result.zig");
const types = @import("../types.zig");
const BsonDocument = serialization_zig.bson.BsonDocument;
const McpServer = protocol.McpServer;
const CallToolResult = protocol.ICallToolResult;
const textResult = result.textResult;
const IMcpToolContext = types.IMcpToolContext;

//
// Registers the `close_database` tool: drops the currently open database handle for this
// MCP session. Does not unregister the database from databases.toml.
//
pub fn registerCloseDatabaseTool(server: *McpServer, toolContext: *IMcpToolContext) !void {
    try server.registerTool(
        "close_database",
        .{
            .description = "Close the currently open database (does not unregister it from databases.toml).",
            .inputSchema = &.{},
        },
        toolContext,
        closeDatabase,
    );
}

//
// The handler of `close_database` (TypeScript: the arrow function given to registerTool).
//
fn closeDatabase(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, arguments: BsonDocument) !CallToolResult {
    _ = io;
    _ = arguments;
    const toolContext: *IMcpToolContext = @ptrCast(@alignCast(context.?));
    const database = toolContext.getDatabase() orelse {
        return textResult(allocator, "No database is currently open.");
    };
    const previousPath = database.databasePath;
    toolContext.clearDatabase();
    return textResult(allocator, try std.fmt.allocPrint(allocator, "Closed database at {s}", .{previousPath}));
}
