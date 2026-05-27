import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { textResult } from "../result";
import type { IMcpToolContext } from "../types";

//
// Registers the `close_database` tool: drops the currently open database handle for this
// MCP session. Does not unregister the database from databases.toml.
//
export function registerCloseDatabaseTool(server: McpServer, toolContext: IMcpToolContext): void {
    server.registerTool(
        "close_database",
        {
            description: "Close the currently open database (does not unregister it from databases.toml).",
            inputSchema: {},
        },
        async () => {
            const database = toolContext.getDatabase();
            if (!database) {
                return textResult("No database is currently open.");
            }
            const previousPath = database.databasePath;
            toolContext.clearDatabase();
            return textResult(`Closed database at ${previousPath}`);
        },
    );
}
