import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { listAssetPage } from "api";
import { requireDatabase, textResult, toAssetSummary } from "../result";
import type { IMcpToolContext } from "../types";

//
// Registers the `list_media_files` tool: returns a page of media files from the open
// database, sorted by the date the photo or video was taken (newest first).
//
export function registerListMediaFilesTool(server: McpServer, toolContext: IMcpToolContext): void {
    server.registerTool(
        "list_media_files",
        {
            description: "List a page of media files (photos and videos) in the open Photosphere database, sorted by the date the photo or video was taken (newest first).",
            inputSchema: {
                limit: z.number().int().min(1).max(200).default(20),
                pageId: z.string().optional(),
            },
        },
        async (args) => {
            const dbOrError = requireDatabase(toolContext);
            if ("content" in dbOrError) {
                return dbOrError;
            }
            const page = await listAssetPage(dbOrError.bsonDatabase, args.limit, args.pageId);
            return textResult(JSON.stringify({
                mediaFiles: page.assets.map(toAssetSummary),
                nextPageId: page.nextPageId,
            }, null, 2));
        },
    );
}
