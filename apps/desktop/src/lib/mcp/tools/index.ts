import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { McpSendRequest } from "../sender";
import { registerGetDatabaseSummaryTool } from "./get-database-summary";
import { registerListMediaFilesTool } from "./list-media-files";
import { registerGetMediaFileInfoTool } from "./get-media-file-info";
import { registerSearchMediaFilesTool } from "./search-media-files";
import { registerSaveMediaFileTool } from "./save-media-file";
import { registerOpenMediaFileTool } from "./open-media-file";
import { registerImportMediaFilesTool } from "./import-media-files";
import { registerOpenDatabaseTool } from "./open-database";
import { registerCloseDatabaseTool } from "./close-database";
import { registerListDatabasesTool } from "./list-databases";
import { registerDeleteMediaFileTool } from "./delete-media-file";
import { registerUpdateMediaFileTool } from "./update-media-file";
import { registerVerifyDatabaseTool } from "./verify-database";

//
// Registers every Photosphere MCP tool on the given server. Each tool forwards its call
// to the renderer via sendRequest; the renderer dispatcher holds the real logic.
//
export function registerAllMcpTools(server: McpServer, sendRequest: McpSendRequest): void {
    registerGetDatabaseSummaryTool(server, sendRequest);
    registerListMediaFilesTool(server, sendRequest);
    registerGetMediaFileInfoTool(server, sendRequest);
    registerSearchMediaFilesTool(server, sendRequest);
    registerSaveMediaFileTool(server, sendRequest);
    registerOpenMediaFileTool(server, sendRequest);
    registerImportMediaFilesTool(server, sendRequest);
    registerOpenDatabaseTool(server, sendRequest);
    registerCloseDatabaseTool(server, sendRequest);
    registerListDatabasesTool(server, sendRequest);
    registerDeleteMediaFileTool(server, sendRequest);
    registerUpdateMediaFileTool(server, sendRequest);
    registerVerifyDatabaseTool(server, sendRequest);
}
