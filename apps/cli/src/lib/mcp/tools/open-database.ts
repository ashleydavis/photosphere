import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { loadDatabase, type IBaseCommandOptions } from "../../init-cmd";
import { textResult } from "../result";
import type { IMcpToolContext } from "../types";

//
// Registers the `open_database` tool: resolves the requested name or path against the
// local registry (via loadDatabase) and stores the result as the active database for
// subsequent tools.
//
export function registerOpenDatabaseTool(server: McpServer, toolContext: IMcpToolContext): void {
    server.registerTool(
        "open_database",
        {
            description: "Open a database by name (from list_databases) or by path. Becomes the active database for subsequent tools.",
            inputSchema: {
                path: z.string(),
            },
        },
        async (args) => {
            const dbOptions: IBaseCommandOptions = { ...toolContext.options, db: args.path, yes: true };
            const result = await loadDatabase(
                args.path,
                dbOptions,
                toolContext.uuidGenerator,
                toolContext.timestampProvider,
                toolContext.sessionId,
            );
            toolContext.setDatabase({
                databasePath: result.databaseDir,
                encryptionKey: dbOptions.key,
                assetStorage: result.assetStorage,
                metadataCollection: result.metadataCollection,
                bsonDatabase: result.bsonDatabase,
            });
            return textResult(`Opened database at ${result.databaseDir}`);
        },
    );
}
