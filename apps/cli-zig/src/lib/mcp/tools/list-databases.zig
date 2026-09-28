const std = @import("std");
const serialization_zig = @import("serialization-zig");
const node_api = @import("node-api-zig");
const protocol = @import("../protocol.zig");
const result = @import("../result.zig");
const BsonDocument = serialization_zig.bson.BsonDocument;
const McpServer = protocol.McpServer;
const CallToolResult = protocol.ICallToolResult;
const getDatabases = node_api.databases_config.getDatabases;
const textResult = result.textResult;

//
// Registers the `list_databases` tool: returns every database configured in the local
// databases.toml registry. Available to the model even when no database is open.
//
pub fn registerListDatabasesTool(server: *McpServer) !void {
    try server.registerTool(
        "list_databases",
        .{
            .description = "List databases configured in this Photosphere installation (from databases.toml).",
            .inputSchema = &.{},
        },
        null,
        listDatabases,
    );
}

//
// The handler of `list_databases` (TypeScript: the arrow function given to registerTool).
//
fn listDatabases(context: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, arguments: BsonDocument) !CallToolResult {
    _ = context;
    _ = arguments;
    const databases = try getDatabases(allocator, io);
    if (databases.len == 0) {
        return textResult(allocator, "No databases are configured. Use `psi dbs add <path>` to register one, or `psi init` to create a new one.");
    }
    var lines: std.ArrayList([]const u8) = .empty;
    for (databases) |entry| {
        var parts: std.ArrayList([]const u8) = .empty;
        try parts.append(allocator, try std.fmt.allocPrint(allocator, "- {s} ({s})", .{ entry.name, entry.path }));
        if (entry.description.len > 0) {
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "  {s}", .{entry.description}));
        }
        try lines.append(allocator, try std.mem.join(allocator, "\n", parts.items));
    }
    return textResult(allocator, try std.fmt.allocPrint(allocator, "Configured databases:\n{s}", .{try std.mem.join(allocator, "\n", lines.items)}));
}
