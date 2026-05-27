import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { textResult } from "../result";
import type { McpSendRequest } from "../sender";

//
// Registers the `open_media_file` tool: forwards to the renderer, which navigates the
// gallery to the given media file so the user sees it in the viewer.
//
export function registerOpenMediaFileTool(server: McpServer, sendRequest: McpSendRequest): void {
    server.registerTool(
        "open_media_file",
        {
            description: "Open a photo or video in the Photosphere gallery viewer so the user can see it.",
            inputSchema: {
                assetId: z.string(),
            },
        },
        async (args) => textResult(await sendRequest("open_media_file", args)),
    );
}
