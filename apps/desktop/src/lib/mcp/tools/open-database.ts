import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { textResult } from "../result";
import type { McpSendRequest } from "../sender";

//
// Registers the `open_database` tool: forwards to the renderer.
//
export function registerOpenDatabaseTool(server: McpServer, sendRequest: McpSendRequest): void {
    server.registerTool(
        "open_database",
        {
            description: "Open a database from disk.",
            inputSchema: {
                path: z.string(),
            },
        },
        async (args) => textResult(await sendRequest("open_database", args)),
    );
}
