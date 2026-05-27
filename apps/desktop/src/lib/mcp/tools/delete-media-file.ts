import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { textResult } from "../result";
import type { McpSendRequest } from "../sender";

//
// Registers the `delete_media_file` tool: forwards to the renderer.
//
export function registerDeleteMediaFileTool(server: McpServer, sendRequest: McpSendRequest): void {
    server.registerTool(
        "delete_media_file",
        {
            description: "Delete a media file (photo or video) by id.",
            inputSchema: {
                assetId: z.string(),
            },
        },
        async (args) => textResult(await sendRequest("delete_media_file", args)),
    );
}
