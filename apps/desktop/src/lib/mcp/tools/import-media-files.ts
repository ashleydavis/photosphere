import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { textResult } from "../result";
import type { McpSendRequest } from "../sender";

//
// Registers the `import_media_files` tool: forwards to the renderer.
//
export function registerImportMediaFilesTool(server: McpServer, sendRequest: McpSendRequest): void {
    server.registerTool(
        "import_media_files",
        {
            description: "Import photos and videos from files or directories into the open Photosphere database. Set dryRun to preview without writing.",
            inputSchema: {
                paths: z.array(z.string()),
                dryRun: z.boolean().default(false),
            },
        },
        async (args) => textResult(await sendRequest("import_media_files", args)),
    );
}
