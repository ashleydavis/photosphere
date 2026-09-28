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
const verify = node_api.verify.verify;
const verifyDatabaseFiles = node_api.verify.verifyDatabaseFiles;
const jsonStringifyIndented = bdb.js_value.jsonStringifyIndented;
const requireDatabase = result.requireDatabase;
const textResult = result.textResult;
const toJsValue = result.toJsValue;
const IMcpToolContext = types.IMcpToolContext;

//
// Registers the `verify_database` tool: runs the full database+asset integrity check and
// returns the combined summary as a JSON blob.
//
pub fn registerVerifyDatabaseTool(server: *McpServer, toolContext: *IMcpToolContext) !void {
    try server.registerTool(
        "verify_database",
        .{
            .description = "Run a full integrity check over the open database. Returns a summary of any issues.",
            .inputSchema = &.{},
        },
        toolContext,
        verifyDatabase,
    );
}

//
// The handler of `verify_database` (TypeScript: the arrow function given to registerTool). The verification runs
// with the context's allocator, because it hands what it allocates to the tasks of the worker pool.
//
fn verifyDatabase(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, arguments: BsonDocument) !CallToolResult {
    _ = arguments;
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
    const dbFileResult = try verifyDatabaseFiles(toolContext.allocator, io, database.assetStorage, null);
    const verifyResult = try verify(toolContext.allocator, io, storageDescriptor, database.assetStorage, toolContext.uuidGenerator, database.metadataCollection, null, null);
    var response: BsonDocument = .empty;
    try response.put(allocator, "databaseFiles", try toJsValue(allocator, dbFileResult));
    try response.put(allocator, "assets", try toJsValue(allocator, verifyResult));
    return textResult(allocator, try jsonStringifyIndented(allocator, .{ .document = response }));
}
