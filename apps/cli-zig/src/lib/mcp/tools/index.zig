const protocol = @import("../protocol.zig");
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
// Registers every CLI MCP tool against the given server. Pulled out of mcp.ts so the
// command entry point stays focused on transport, lifecycle, and state.
//
pub fn registerAllMcpTools(server: *McpServer, toolContext: *IMcpToolContext) !void {
    try registerListDatabasesTool(server);
    try registerOpenDatabaseTool(server, toolContext);
    try registerCloseDatabaseTool(server, toolContext);
    try registerGetDatabaseSummaryTool(server, toolContext);
    try registerListMediaFilesTool(server, toolContext);
    try registerGetMediaFileInfoTool(server, toolContext);
    try registerSearchMediaFilesTool(server, toolContext);
    try registerSaveMediaFileTool(server, toolContext);
    try registerImportMediaFilesTool(server, toolContext);
    try registerVerifyDatabaseTool(server, toolContext);
}
