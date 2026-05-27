import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { textResult } from "../result";
import type { McpSendRequest } from "../sender";

//
// Registers the `list_media_files` tool: forwards to the renderer.
//
export function registerListMediaFilesTool(server: McpServer, sendRequest: McpSendRequest): void {
    server.registerTool(
        "list_media_files",
        {
            description: "List a page of media files (photos and videos) in the open Photosphere database, sorted by the date the photo or video was taken (newest first).",
            inputSchema: {
                limit: z.number().int().min(1).max(200).default(20),
                pageId: z.string().optional(),
            },
        },
        async (args) => textResult(await sendRequest("list_media_files", args)),
    );
}
