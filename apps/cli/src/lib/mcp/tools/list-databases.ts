import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { getDatabases } from "node-api";
import { textResult } from "../result";

//
// Registers the `list_databases` tool: returns every database configured in the local
// databases.toml registry. Available to the model even when no database is open.
//
export function registerListDatabasesTool(server: McpServer): void {
    server.registerTool(
        "list_databases",
        {
            description: "List databases configured in this Photosphere installation (from databases.toml).",
            inputSchema: {},
        },
        async () => {
            const databases = await getDatabases();
            if (databases.length === 0) {
                return textResult("No databases are configured. Use `psi dbs add <path>` to register one, or `psi init` to create a new one.");
            }
            const lines = databases.map(entry => {
                const parts = [`- ${entry.name} (${entry.path})`];
                if (entry.description) {
                    parts.push(`  ${entry.description}`);
                }
                return parts.join("\n");
            });
            return textResult(`Configured databases:\n${lines.join("\n")}`);
        },
    );
}
