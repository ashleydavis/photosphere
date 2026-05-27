import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { textResult } from "../result";
import type { McpSendRequest } from "../sender";

//
// Registers the `get_database_summary` tool: forwards to the renderer.
//
export function registerGetDatabaseSummaryTool(server: McpServer, sendRequest: McpSendRequest): void {
    server.registerTool(
        "get_database_summary",
        {
            description: "Get a high-level summary of the open Photosphere database (file count, total size, hashes).",
            inputSchema: {},
        },
        async () => textResult(await sendRequest("get_database_summary", {})),
    );
}
