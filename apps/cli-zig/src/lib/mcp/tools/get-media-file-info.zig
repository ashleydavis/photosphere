const std = @import("std");
const serialization_zig = @import("serialization-zig");
const bdb = @import("bdb-zig");
const api = @import("api-zig");
const protocol = @import("../protocol.zig");
const result = @import("../result.zig");
const types = @import("../types.zig");
const BsonDocument = serialization_zig.bson.BsonDocument;
const McpServer = protocol.McpServer;
const CallToolResult = protocol.ICallToolResult;
const getAsset = api.asset_query.getAsset;
const jsonStringifyIndented = bdb.js_value.jsonStringifyIndented;
const requireDatabase = result.requireDatabase;
const textResult = result.textResult;
const IMcpToolContext = types.IMcpToolContext;

//
// Registers the `get_media_file_info` tool: returns the full metadata record for a single
// media file by ID.
//
pub fn registerGetMediaFileInfoTool(server: *McpServer, toolContext: *IMcpToolContext) !void {
    try server.registerTool(
        "get_media_file_info",
        .{
            .description = "Return detailed metadata for a single media file (photo or video).",
            .inputSchema = &.{
                .{
                    .name = "assetId",
                    .fieldType = .string,
                    .presence = .required,
                },
            },
        },
        toolContext,
        getMediaFileInfo,
    );
}

//
// The handler of `get_media_file_info` (TypeScript: the arrow function given to registerTool).
//
fn getMediaFileInfo(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, arguments: BsonDocument) !CallToolResult {
    const toolContext: *IMcpToolContext = @ptrCast(@alignCast(context.?));
    const database = switch (try requireDatabase(allocator, toolContext)) {
        .database => |database| database,
        .result => |noDatabase| {
            return noDatabase;
        },
    };
    const assetId = arguments.get("assetId").?.string;
    const asset = try getAsset(io, database.bsonDatabase, assetId) orelse {
        return textResult(allocator, try std.fmt.allocPrint(allocator, "Media file {s} not found.", .{assetId}));
    };
    return textResult(allocator, try jsonStringifyIndented(allocator, .{ .document = asset }));
}
