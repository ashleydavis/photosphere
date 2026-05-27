import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { textResult } from "../result";
import type { McpSendRequest } from "../sender";

//
// Registers the `list_databases` tool: forwards to the renderer.
//
export function registerListDatabasesTool(server: McpServer, sendRequest: McpSendRequest): void {
    server.registerTool(
        "list_databases",
        {
            description: "List databases the host is aware of.",
            inputSchema: {},
        },
        async () => textResult(await sendRequest("list_databases", {})),
    );
}
