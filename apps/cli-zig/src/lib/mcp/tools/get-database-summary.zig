const std = @import("std");
const serialization_zig = @import("serialization-zig");
const bdb = @import("bdb-zig");
const node_api = @import("node-api-zig");
const protocol = @import("../protocol.zig");
const result = @import("../result.zig");
const types = @import("../types.zig");
const BsonDocument = serialization_zig.bson.BsonDocument;
const McpServer = protocol.McpServer;
const CallToolResult = protocol.ICallToolResult;
const getDatabaseSummary = node_api.media_file_database.getDatabaseSummary;
const jsonStringifyIndented = bdb.js_value.jsonStringifyIndented;
const requireDatabase = result.requireDatabase;
const textResult = result.textResult;
const toJsValue = result.toJsValue;
const IMcpToolContext = types.IMcpToolContext;

//
// Registers the `get_database_summary` tool: returns the merkle-tree-derived summary
// (file count, total size, hashes, version) for the open database.
//
pub fn registerGetDatabaseSummaryTool(server: *McpServer, toolContext: *IMcpToolContext) !void {
    try server.registerTool(
        "get_database_summary",
        .{
            .description = "Return a summary of the open database (file count, total size, hashes).",
            .inputSchema = &.{},
        },
        toolContext,
        getDatabaseSummaryHandler,
    );
}

//
// The handler of `get_database_summary` (TypeScript: the arrow function given to registerTool).
//
fn getDatabaseSummaryHandler(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, arguments: BsonDocument) !CallToolResult {
    _ = arguments;
    const toolContext: *IMcpToolContext = @ptrCast(@alignCast(context.?));
    const database = switch (try requireDatabase(allocator, toolContext)) {
        .database => |database| database,
        .result => |noDatabase| {
            return noDatabase;
        },
    };
    const summary = try getDatabaseSummary(allocator, io, database.assetStorage);
    return textResult(allocator, try jsonStringifyIndented(allocator, try toJsValue(allocator, summary)));
}
