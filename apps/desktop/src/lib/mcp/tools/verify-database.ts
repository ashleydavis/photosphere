import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { textResult } from "../result";
import type { McpSendRequest } from "../sender";

//
// Registers the `verify_database` tool: forwards to the renderer.
//
export function registerVerifyDatabaseTool(server: McpServer, sendRequest: McpSendRequest): void {
    server.registerTool(
        "verify_database",
        {
            description: "Run a full integrity check over the open database.",
            inputSchema: {},
        },
        async () => textResult(await sendRequest("verify_database", {})),
    );
}
