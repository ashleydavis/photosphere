const std = @import("std");
const serialization_zig = @import("serialization-zig");
const init_cmd = @import("../../init-cmd.zig");
const protocol = @import("../protocol.zig");
const result = @import("../result.zig");
const types = @import("../types.zig");
const BsonDocument = serialization_zig.bson.BsonDocument;
const McpServer = protocol.McpServer;
const CallToolResult = protocol.ICallToolResult;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const loadDatabase = init_cmd.loadDatabase;
const textResult = result.textResult;
const IMcpToolContext = types.IMcpToolContext;

//
// Registers the `open_database` tool: resolves the requested name or path against the
// local registry (via loadDatabase) and stores the result as the active database for
// subsequent tools.
//
pub fn registerOpenDatabaseTool(server: *McpServer, toolContext: *IMcpToolContext) !void {
    try server.registerTool(
        "open_database",
        .{
            .description = "Open a database by name (from list_databases) or by path. Becomes the active database for subsequent tools.",
            .inputSchema = &.{
                .{
                    .name = "path",
                    .fieldType = .string,
                    .presence = .required,
                },
            },
        },
        toolContext,
        openDatabase,
    );
}

//
// The handler of `open_database` (TypeScript: the arrow function given to registerTool). The database is loaded
// with the context's allocator, because it stays open after the call.
//
fn openDatabase(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, arguments: BsonDocument) !CallToolResult {
    const toolContext: *IMcpToolContext = @ptrCast(@alignCast(context.?));
    const path = try toolContext.allocator.dupe(u8, arguments.get("path").?.string);
    var dbOptions: IBaseCommandOptions = toolContext.options;
    dbOptions.db = path;
    dbOptions.yes = true;
    const loaded = try loadDatabase(
        toolContext.allocator,
        io,
        path,
        &dbOptions,
        toolContext.uuidGenerator,
        toolContext.timestampProvider,
        toolContext.sessionId,
        false,
    );
    toolContext.setDatabase(.{
        .databasePath = loaded.databaseDir,
        .encryptionKey = dbOptions.key,
        .assetStorage = loaded.assetStorage,
        .metadataCollection = loaded.metadataCollection,
        .bsonDatabase = loaded.bsonDatabase,
    });
    return textResult(allocator, try std.fmt.allocPrint(allocator, "Opened database at {s}", .{loaded.databaseDir}));
}
