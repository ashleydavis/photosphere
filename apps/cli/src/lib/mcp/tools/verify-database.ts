import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { verify, verifyDatabaseFiles } from "api";
import type { IDatabaseDescriptor } from "api";
import { requireDatabase, textResult } from "../result";
import type { IMcpToolContext } from "../types";

//
// Registers the `verify_database` tool: runs the full database+asset integrity check and
// returns the combined summary as a JSON blob.
//
export function registerVerifyDatabaseTool(server: McpServer, toolContext: IMcpToolContext): void {
    server.registerTool(
        "verify_database",
        {
            description: "Run a full integrity check over the open database. Returns a summary of any issues.",
            inputSchema: {},
        },
        async () => {
            const dbOrError = requireDatabase(toolContext);
            if ("content" in dbOrError) {
                return dbOrError;
            }
            const storageDescriptor: IDatabaseDescriptor = {
                databasePath: dbOrError.databasePath,
                encryptionKey: dbOrError.encryptionKey,
            };
            const dbFileResult = await verifyDatabaseFiles(dbOrError.assetStorage);
            const result = await verify(storageDescriptor, dbOrError.assetStorage, toolContext.uuidGenerator, dbOrError.metadataCollection);
            return textResult(JSON.stringify({
                databaseFiles: dbFileResult,
                assets: result,
            }, null, 2));
        },
    );
}
