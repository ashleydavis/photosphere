const std = @import("std");
const serialization_zig = @import("serialization-zig");
const api = @import("api-zig");
const protocol = @import("../protocol.zig");
const result = @import("../result.zig");
const types = @import("../types.zig");
const BsonDocument = serialization_zig.bson.BsonDocument;
const McpServer = protocol.McpServer;
const CallToolResult = protocol.ICallToolResult;
const streamAssetToFile = api.asset_query.streamAssetToFile;
const requireDatabase = result.requireDatabase;
const textResult = result.textResult;
const IMcpToolContext = types.IMcpToolContext;

//
// Registers the `save_media_file` tool: streams the original, display, or thumbnail
// version of a media file to a path on disk.
//
pub fn registerSaveMediaFileTool(server: *McpServer, toolContext: *IMcpToolContext) !void {
    try server.registerTool(
        "save_media_file",
        .{
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
                        .default = .{ .string = "original" },
                    },
                },
            },
        },
        toolContext,
        saveMediaFile,
    );
}

//
// The handler of `save_media_file` (TypeScript: the arrow function given to registerTool).
//
fn saveMediaFile(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, arguments: BsonDocument) !CallToolResult {
    const toolContext: *IMcpToolContext = @ptrCast(@alignCast(context.?));
    const database = switch (try requireDatabase(allocator, toolContext)) {
        .database => |database| database,
        .result => |noDatabase| {
            return noDatabase;
        },
    };
    const outputPath = arguments.get("outputPath").?.string;
    const bytes = try streamAssetToFile(allocator, io, database.assetStorage, arguments.get("assetId").?.string, outputPath, arguments.get("type").?.string);
    return textResult(allocator, try std.fmt.allocPrint(allocator, "Wrote {d} bytes to {s}", .{ bytes, outputPath }));
}
