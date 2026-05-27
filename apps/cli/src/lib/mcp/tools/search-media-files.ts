import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { searchAssets } from "api";
import { requireDatabase, textResult, toAssetSummary } from "../result";
import type { IMcpToolContext } from "../types";

//
// Registers the `search_media_files` tool: filters media files by filename/location
// substring, content type prefix, and a date range over photoDate.
//
export function registerSearchMediaFilesTool(server: McpServer, toolContext: IMcpToolContext): void {
    server.registerTool(
        "search_media_files",
        {
            description: "Search photos and videos in the open Photosphere database by filename, location, content type, or photo date range.",
            inputSchema: {
                query: z.string().default(""),
                contentType: z.string().optional(),
                dateFrom: z.string().optional(),
                dateTo: z.string().optional(),
                limit: z.number().int().min(1).max(200).default(20),
            },
        },
        async (args) => {
            const dbOrError = requireDatabase(toolContext);
            if ("content" in dbOrError) {
                return dbOrError;
            }
            const assets = await searchAssets(dbOrError.bsonDatabase, args.query, args.contentType, args.dateFrom, args.dateTo, args.limit);
            return textResult(JSON.stringify(assets.map(toAssetSummary), null, 2));
        },
    );
}
