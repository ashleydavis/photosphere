import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { streamAssetToFile } from "api";
import { requireDatabase, textResult } from "../result";
import type { IMcpToolContext } from "../types";

//
// Registers the `save_media_file` tool: streams the original, display, or thumbnail
// version of a media file to a path on disk.
//
export function registerSaveMediaFileTool(server: McpServer, toolContext: IMcpToolContext): void {
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
        async (args) => {
            const dbOrError = requireDatabase(toolContext);
            if ("content" in dbOrError) {
                return dbOrError;
            }
            const bytes = await streamAssetToFile(dbOrError.assetStorage, args.assetId, args.outputPath, args.type);
            return textResult(`Wrote ${bytes} bytes to ${args.outputPath}`);
        },
    );
}
