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
const searchAssets = api.asset_query.searchAssets;
const jsonStringifyIndented = bdb.js_value.jsonStringifyIndented;
const requireDatabase = result.requireDatabase;
const textResult = result.textResult;
const toAssetSummary = result.toAssetSummary;
const IMcpToolContext = types.IMcpToolContext;

//
// Registers the `search_media_files` tool: filters media files by filename/location
// substring, content type prefix, and a date range over photoDate.
//
pub fn registerSearchMediaFilesTool(server: *McpServer, toolContext: *IMcpToolContext) !void {
    try server.registerTool(
        "search_media_files",
        .{
            .description = "Search photos and videos in the open Photosphere database by filename, location, content type, or photo date range.",
            .inputSchema = &.{
                .{
                    .name = "query",
                    .fieldType = .string,
                    .presence = .{
                        .default = .{ .string = "" },
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
                        .default = .{ .number = 20 },
                    },
                },
            },
        },
        toolContext,
        searchMediaFiles,
    );
}

//
// An optional string argument, null when it was left out.
//
fn optionalString(arguments: BsonDocument, name: []const u8) ?[]const u8 {
    const value = arguments.get(name) orelse {
        return null;
    };
    return value.string;
}

//
// The handler of `search_media_files` (TypeScript: the arrow function given to registerTool).
//
fn searchMediaFiles(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, arguments: BsonDocument) !CallToolResult {
    const toolContext: *IMcpToolContext = @ptrCast(@alignCast(context.?));
    const database = switch (try requireDatabase(allocator, toolContext)) {
        .database => |database| database,
        .result => |noDatabase| {
            return noDatabase;
        },
    };
    const assets = try searchAssets(
        allocator,
        io,
        database.bsonDatabase,
        arguments.get("query").?.string,
        optionalString(arguments, "contentType"),
        optionalString(arguments, "dateFrom"),
        optionalString(arguments, "dateTo"),
        @intFromFloat(arguments.get("limit").?.number),
    );
    const summaries = try allocator.alloc(BsonValue, assets.len);
    for (assets, 0..) |asset, assetIndex| {
        summaries[assetIndex] = try toAssetSummary(allocator, asset);
    }
    return textResult(allocator, try jsonStringifyIndented(allocator, .{ .array = summaries }));
}
