import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { textResult } from "../result";
import type { McpSendRequest } from "../sender";

//
// Registers the `search_media_files` tool: forwards to the renderer.
//
export function registerSearchMediaFilesTool(server: McpServer, sendRequest: McpSendRequest): void {
    server.registerTool(
        "search_media_files",
        {
            description: "Search photos and videos in the open Photosphere database by filename, location, content type, or photo date range. The full result set is shown to the user in the gallery; `limit` controls only how many matches are returned to you (raise it when the user asks for more).",
            inputSchema: {
                query: z.string().default(""),
                contentType: z.string().optional(),
                dateFrom: z.string().optional(),
                dateTo: z.string().optional(),
                limit: z.number().int().min(1).max(200).default(10),
            },
        },
        async (args) => textResult(await sendRequest("search_media_files", args)),
    );
}
