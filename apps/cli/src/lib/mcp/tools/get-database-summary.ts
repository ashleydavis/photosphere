import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { getDatabaseSummary } from "node-api";
import { requireDatabase, textResult } from "../result";
import type { IMcpToolContext } from "../types";

//
// Registers the `get_database_summary` tool: returns the merkle-tree-derived summary
// (file count, total size, hashes, version) for the open database.
//
export function registerGetDatabaseSummaryTool(server: McpServer, toolContext: IMcpToolContext): void {
    server.registerTool(
        "get_database_summary",
        {
            description: "Return a summary of the open database (file count, total size, hashes).",
            inputSchema: {},
        },
        async () => {
            const dbOrError = requireDatabase(toolContext);
            if ("content" in dbOrError) {
                return dbOrError;
            }
            const summary = await getDatabaseSummary(dbOrError.assetStorage);
            return textResult(JSON.stringify(summary, null, 2));
        },
    );
}
