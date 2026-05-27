import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { textResult } from "../result";
import type { McpSendRequest } from "../sender";

//
// Registers the `get_media_file_info` tool: forwards to the renderer.
//
export function registerGetMediaFileInfoTool(server: McpServer, sendRequest: McpSendRequest): void {
    server.registerTool(
        "get_media_file_info",
        {
            description: "Return detailed metadata for a single media file (photo or video).",
            inputSchema: {
                assetId: z.string(),
            },
        },
        async (args) => textResult(await sendRequest("get_media_file_info", args)),
    );
}
