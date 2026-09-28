const std = @import("std");
const serialization_zig = @import("serialization-zig");
const bdb = @import("bdb-zig");
const api = @import("api-zig");
const protocol = @import("../protocol.zig");
const result = @import("../result.zig");
const types = @import("../types.zig");
const BsonValue = serialization_zig.bson.BsonValue;
const BsonDocument = serialization_zig.bson.BsonDocument;
const McpServer = protocol.McpServer;
const CallToolResult = protocol.ICallToolResult;
const listAssetPage = api.asset_query.listAssetPage;
const jsonStringifyIndented = bdb.js_value.jsonStringifyIndented;
const requireDatabase = result.requireDatabase;
const textResult = result.textResult;
const toAssetSummary = result.toAssetSummary;
const IMcpToolContext = types.IMcpToolContext;

//
// Registers the `list_media_files` tool: returns a page of media files from the open
// database, sorted by the date the photo or video was taken (newest first).
//
pub fn registerListMediaFilesTool(server: *McpServer, toolContext: *IMcpToolContext) !void {
    try server.registerTool(
        "list_media_files",
        .{
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
                        .default = .{ .number = 20 },
                    },
                },
                .{
                    .name = "pageId",
                    .fieldType = .string,
                    .presence = .optional,
                },
            },
        },
        toolContext,
        listMediaFiles,
    );
}

//
// The handler of `list_media_files` (TypeScript: the arrow function given to registerTool).
//
fn listMediaFiles(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, arguments: BsonDocument) !CallToolResult {
    const toolContext: *IMcpToolContext = @ptrCast(@alignCast(context.?));
    const database = switch (try requireDatabase(allocator, toolContext)) {
        .database => |database| database,
        .result => |noDatabase| {
            return noDatabase;
        },
    };
    const limit: usize = @intFromFloat(arguments.get("limit").?.number);
    const pageId: ?[]const u8 = if (arguments.get("pageId")) |value| value.string else null;
    const page = try listAssetPage(io, database.bsonDatabase, limit, pageId);
    const mediaFiles = try allocator.alloc(BsonValue, page.assets.len);
    for (page.assets, 0..) |asset, assetIndex| {
        mediaFiles[assetIndex] = try toAssetSummary(allocator, asset);
    }
    var response: BsonDocument = .empty;
    try response.put(allocator, "mediaFiles", .{ .array = mediaFiles });
    try response.put(allocator, "nextPageId", if (page.nextPageId) |nextPageId| .{ .string = nextPageId } else .undefined);
    return textResult(allocator, try jsonStringifyIndented(allocator, .{ .document = response }));
}
