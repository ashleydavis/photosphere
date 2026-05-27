import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { version } from "config";
import { IBaseCommandOptions, ICommandContext } from "../lib/init-cmd";
import { registerAllMcpTools } from "../lib/mcp/tools";
import type { ICurrentDatabase, IMcpToolContext } from "../lib/mcp/types";

//
// Options for the `psi mcp` command. No --db on purpose: the MCP client picks a
// database at runtime via the `list_databases` / `open_database` tools.
//
export interface IMcpCommandOptions extends IBaseCommandOptions {
}

//
// Server-level instructions describing what Photosphere is. Sent to MCP clients so the
// model knows when to use these tools and doesn't fall back on filesystem/shell tools
// for photo/video questions.
//
const PHOTOSPHERE_INSTRUCTIONS = [
    "Photosphere is a local-first photo and video management app (think Google Photos, but the user owns their data).",
    "It stores a database of media files (photos and videos) with metadata: filename, location, GPS coordinates, date taken, labels, description, content type, dimensions.",
    "",
    "Use these tools whenever the user asks about their photos, videos, image library, media collection, or photo database. Prefer these over filesystem tools (ls, find, Read) when the user is referring to media in their Photosphere library.",
    "",
    "Capabilities:",
    "- list_databases / open_database / close_database: choose which Photosphere database to work on",
    "- list_media_files: page through media files in the open database (newest first)",
    "- search_media_files: filter media files by filename, location, content type, or photo date range",
    "- get_media_file_info: full metadata for a single media file by id",
    "- save_media_file: save a media file (original, display, or thumbnail) to a path on disk",
    "- import_media_files: import photos/videos from files or directories into the open database",
    "- get_database_summary / verify_database: inspect or check the database's integrity",
].join("\n");

//
// Implements the `psi mcp` command: a stdio MCP server with no database open by default.
//
export async function mcpCommand(context: ICommandContext, options: IMcpCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;

    //
    // No database is open at startup; the MCP client opens one via the open_database tool.
    //
    let currentDatabase: ICurrentDatabase | undefined = undefined;

    const toolContext: IMcpToolContext = {
        getDatabase: () => currentDatabase,
        setDatabase: (database) => { currentDatabase = database; },
        clearDatabase: () => { currentDatabase = undefined; },
        uuidGenerator,
        timestampProvider,
        sessionId,
        options,
    };

    const server = new McpServer(
        {
            name: "photosphere",
            version,
        },
        {
            instructions: PHOTOSPHERE_INSTRUCTIONS,
        },
    );
    registerAllMcpTools(server, toolContext);

    //
    // Start the stdio transport. The MCP client owns this process's stdin/stdout.
    //
    const transport = new StdioServerTransport();
    await server.connect(transport);
    process.stderr.write("Photosphere MCP server running\n");

    //
    // Keep the process alive until stdin closes; then shut down cleanly.
    //
    await new Promise<void>(resolve => {
        process.stdin.on("end", () => resolve());
        process.stdin.on("close", () => resolve());
    });

    await server.close();
}
