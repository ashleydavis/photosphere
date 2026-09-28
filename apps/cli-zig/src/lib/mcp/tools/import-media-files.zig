const std = @import("std");
const serialization_zig = @import("serialization-zig");
const bdb = @import("bdb-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const protocol = @import("../protocol.zig");
const result = @import("../result.zig");
const types = @import("../types.zig");
const BsonDocument = serialization_zig.bson.BsonDocument;
const McpServer = protocol.McpServer;
const CallToolResult = protocol.ICallToolResult;
const IDatabaseDescriptor = api.database_descriptor.IDatabaseDescriptor;
const addPaths = node_api.import_module.addPaths;
const jsonStringifyIndented = bdb.js_value.jsonStringifyIndented;
const requireDatabase = result.requireDatabase;
const textResult = result.textResult;
const toJsValue = result.toJsValue;
const IMcpToolContext = types.IMcpToolContext;

//
// Registers the `import_media_files` tool: imports photos and videos from files or
// directories into the open database. dryRun previews without writing.
//
pub fn registerImportMediaFilesTool(server: *McpServer, toolContext: *IMcpToolContext) !void {
    try server.registerTool(
        "import_media_files",
        .{
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
                        .default = .{ .boolean = false },
                    },
                },
            },
        },
        toolContext,
        importMediaFiles,
    );
}

//
// The handler of `import_media_files` (TypeScript: the arrow function given to registerTool). The import runs with
// the context's allocator, because addPaths hands what it allocates to a termination callback that outlives the call.
//
fn importMediaFiles(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, arguments: BsonDocument) !CallToolResult {
    const toolContext: *IMcpToolContext = @ptrCast(@alignCast(context.?));
    const database = switch (try requireDatabase(allocator, toolContext)) {
        .database => |database| database,
        .result => |noDatabase| {
            return noDatabase;
        },
    };
    const storageDescriptor: IDatabaseDescriptor = .{
        .databasePath = database.databasePath,
        .encryptionKey = database.encryptionKey,
    };
    const pathValues = arguments.get("paths").?.array;
    const paths = try toolContext.allocator.alloc([]const u8, pathValues.len);
    for (pathValues, 0..) |pathValue, pathIndex| {
        paths[pathIndex] = try toolContext.allocator.dupe(u8, pathValue.string);
    }
    const summary = try addPaths(
        toolContext.allocator,
        io,
        toolContext.uuidGenerator,
        storageDescriptor,
        paths,
        null,
        toolContext.sessionId,
        arguments.get("dryRun").?.boolean,
        null,
        null,
    );
    return textResult(allocator, try jsonStringifyIndented(allocator, try toJsValue(allocator, summary)));
}
