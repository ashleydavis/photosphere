import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { getAsset } from "api";
import { requireDatabase, textResult } from "../result";
import type { IMcpToolContext } from "../types";

//
// Registers the `get_media_file_info` tool: returns the full metadata record for a single
// media file by ID.
//
export function registerGetMediaFileInfoTool(server: McpServer, toolContext: IMcpToolContext): void {
    server.registerTool(
        "get_media_file_info",
        {
            description: "Return detailed metadata for a single media file (photo or video).",
            inputSchema: {
                assetId: z.string(),
            },
        },
        async (args) => {
            const dbOrError = requireDatabase(toolContext);
            if ("content" in dbOrError) {
                return dbOrError;
            }
            const asset = await getAsset(dbOrError.bsonDatabase, args.assetId);
            if (!asset) {
                return textResult(`Media file ${args.assetId} not found.`);
            }
            return textResult(JSON.stringify(asset, null, 2));
        },
    );
}
