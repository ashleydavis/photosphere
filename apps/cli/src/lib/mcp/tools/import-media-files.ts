import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { addPaths } from "api";
import type { IDatabaseDescriptor } from "api";
import { requireDatabase, textResult } from "../result";
import type { IMcpToolContext } from "../types";

//
// Registers the `import_media_files` tool: imports photos and videos from files or
// directories into the open database. dryRun previews without writing.
//
export function registerImportMediaFilesTool(server: McpServer, toolContext: IMcpToolContext): void {
    server.registerTool(
        "import_media_files",
        {
            description: "Import photos and videos from files or directories into the open Photosphere database. Set dryRun to preview without writing.",
            inputSchema: {
                paths: z.array(z.string()),
                dryRun: z.boolean().default(false),
            },
        },
        async (args) => {
            const dbOrError = requireDatabase(toolContext);
            if ("content" in dbOrError) {
                return dbOrError;
            }
            const storageDescriptor: IDatabaseDescriptor = {
                databasePath: dbOrError.databasePath,
                encryptionKey: dbOrError.encryptionKey,
            };
            const summary = await addPaths(
                toolContext.uuidGenerator,
                storageDescriptor,
                args.paths,
                undefined,
                toolContext.sessionId,
                args.dryRun,
            );
            return textResult(JSON.stringify(summary, null, 2));
        },
    );
}
