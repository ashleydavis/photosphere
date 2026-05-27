import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { textResult } from "../result";
import type { McpSendRequest } from "../sender";

//
// Registers the `close_database` tool: forwards to the renderer.
//
export function registerCloseDatabaseTool(server: McpServer, sendRequest: McpSendRequest): void {
    server.registerTool(
        "close_database",
        {
            description: "Close the currently open database.",
            inputSchema: {},
        },
        async () => textResult(await sendRequest("close_database", {})),
    );
}
