import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import type { IAsset } from "api";
import type { ICurrentDatabase, IMcpToolContext } from "./types";

//
// Standard "no database open" message returned by every database-scoped tool.
//
export const NO_DATABASE_MESSAGE = "No database is currently open. Use list_databases / open_database first.";

//
// Wraps plain text as an MCP CallToolResult with a single text content block.
//
export function textResult(text: string): CallToolResult {
    return {
        content: [
            {
                type: "text",
                text,
            },
        ],
    };
}

//
// Returns the currently open database from the context, or a text-result error block when
// no database is open. Tool handlers can dispatch on the type to branch on the guard.
//
export function requireDatabase(toolContext: IMcpToolContext): ICurrentDatabase | CallToolResult {
    const database = toolContext.getDatabase();
    if (!database) {
        return textResult(NO_DATABASE_MESSAGE);
    }
    return database;
}

//
// Reduces a full IAsset to the slimmer summary returned by list/search tools.
//
export function toAssetSummary(asset: IAsset): Record<string, unknown> {
    return {
        _id: asset._id,
        origFileName: asset.origFileName,
        contentType: asset.contentType,
        photoDate: asset.photoDate,
        width: asset.width,
        height: asset.height,
        location: asset.location,
        coordinates: asset.coordinates,
    };
}
