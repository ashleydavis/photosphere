const std = @import("std");
const mcp_zig = @import("mcp-zig");
const protocol = mcp_zig.protocol;
const types = @import("../types.zig");
const McpServer = protocol.McpServer;
const IMcpToolContext = types.IMcpToolContext;
const registerListDatabasesTool = @import("list-databases.zig").registerListDatabasesTool;
const registerOpenDatabaseTool = @import("open-database.zig").registerOpenDatabaseTool;
const registerCloseDatabaseTool = @import("close-database.zig").registerCloseDatabaseTool;
const registerGetDatabaseSummaryTool = @import("get-database-summary.zig").registerGetDatabaseSummaryTool;
const registerListMediaFilesTool = @import("list-media-files.zig").registerListMediaFilesTool;
const registerGetMediaFileInfoTool = @import("get-media-file-info.zig").registerGetMediaFileInfoTool;
const registerSearchMediaFilesTool = @import("search-media-files.zig").registerSearchMediaFilesTool;
const registerSaveMediaFileTool = @import("save-media-file.zig").registerSaveMediaFileTool;
const registerImportMediaFilesTool = @import("import-media-files.zig").registerImportMediaFilesTool;
const registerVerifyDatabaseTool = @import("verify-database.zig").registerVerifyDatabaseTool;

//
// Registers every CLI MCP tool against the given server. Kept apart from the
// command entry point, which stays focused on transport, lifecycle, and state.
//
pub fn registerAllMcpTools(server: *McpServer, allocator: std.mem.Allocator, toolContext: *IMcpToolContext) !void {
    try registerListDatabasesTool(server, allocator);
    try registerOpenDatabaseTool(server, allocator, toolContext);
    try registerCloseDatabaseTool(server, allocator, toolContext);
    try registerGetDatabaseSummaryTool(server, allocator, toolContext);
    try registerListMediaFilesTool(server, allocator, toolContext);
    try registerGetMediaFileInfoTool(server, allocator, toolContext);
    try registerSearchMediaFilesTool(server, allocator, toolContext);
    try registerSaveMediaFileTool(server, allocator, toolContext);
    try registerImportMediaFilesTool(server, allocator, toolContext);
    try registerVerifyDatabaseTool(server, allocator, toolContext);
}
