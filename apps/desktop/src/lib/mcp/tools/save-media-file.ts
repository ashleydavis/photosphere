import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { textResult } from "../result";
import type { McpSendRequest } from "../sender";

//
// Registers the `save_media_file` tool: forwards to the renderer.
//
export function registerSaveMediaFileTool(server: McpServer, sendRequest: McpSendRequest): void {
    server.registerTool(
        "save_media_file",
        {
            description: "Save a media file (photo or video) to a chosen path on disk. Type may be 'original', 'display' or 'thumb'.",
            inputSchema: {
                assetId: z.string(),
                outputPath: z.string(),
                type: z.enum(["original", "display", "thumb"]).default("original"),
            },
        },
        async (args) => textResult(await sendRequest("save_media_file", args)),
    );
}
