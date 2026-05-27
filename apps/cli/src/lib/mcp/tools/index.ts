import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { registerListDatabasesTool } from "./list-databases";
import { registerOpenDatabaseTool } from "./open-database";
import { registerCloseDatabaseTool } from "./close-database";
import { registerGetDatabaseSummaryTool } from "./get-database-summary";
import { registerListMediaFilesTool } from "./list-media-files";
import { registerGetMediaFileInfoTool } from "./get-media-file-info";
import { registerSearchMediaFilesTool } from "./search-media-files";
import { registerSaveMediaFileTool } from "./save-media-file";
import { registerImportMediaFilesTool } from "./import-media-files";
import { registerVerifyDatabaseTool } from "./verify-database";
import type { IMcpToolContext } from "../types";

//
// Registers every CLI MCP tool against the given server. Pulled out of mcp.ts so the
// command entry point stays focused on transport, lifecycle, and state.
//
export function registerAllMcpTools(server: McpServer, toolContext: IMcpToolContext): void {
    registerListDatabasesTool(server);
    registerOpenDatabaseTool(server, toolContext);
    registerCloseDatabaseTool(server, toolContext);
    registerGetDatabaseSummaryTool(server, toolContext);
    registerListMediaFilesTool(server, toolContext);
    registerGetMediaFileInfoTool(server, toolContext);
    registerSearchMediaFilesTool(server, toolContext);
    registerSaveMediaFileTool(server, toolContext);
    registerImportMediaFilesTool(server, toolContext);
    registerVerifyDatabaseTool(server, toolContext);
}
