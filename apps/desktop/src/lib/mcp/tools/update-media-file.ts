import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { textResult } from "../result";
import type { McpSendRequest } from "../sender";

//
// Registers the `update_media_file` tool: forwards to the renderer.
//
export function registerUpdateMediaFileTool(server: McpServer, sendRequest: McpSendRequest): void {
    server.registerTool(
        "update_media_file",
        {
            description: "Update editable fields on a media file (description, labels, date taken, location).",
            inputSchema: {
                assetId: z.string(),
                description: z.string().optional(),
                labels: z.array(z.string()).optional(),
                photoDate: z.string().optional(),
                location: z.string().optional(),
            },
        },
        async (args) => textResult(await sendRequest("update_media_file", args)),
    );
}
