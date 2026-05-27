import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { version } from "config";
import { registerAllMcpTools } from "./tools";
import type { McpSendRequest } from "./sender";

//
// Server-level instructions describing what Photosphere is. Sent to MCP clients as part
// of the server's `Implementation` info so the model knows when to use these tools and
// doesn't fall back on filesystem/shell tools for photo/video questions.
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
    "- open_media_file: show a media file to the user in the Photosphere gallery viewer",
    "- save_media_file: save a media file (original, display, or thumbnail) to a path on disk",
    "- import_media_files: import photos/videos from files or directories into the open database",
    "- update_media_file: edit description, labels, date, or location",
    "- delete_media_file: remove a media file",
    "- get_database_summary / verify_database: inspect or check the database's integrity",
].join("\n");

//
// Creates a new McpServer with every Photosphere tool registered. Tools forward their
// arguments to the renderer via sendRequest and return whatever the renderer replies with.
//
export function createMcpServer(sendRequest: McpSendRequest): McpServer {
    const server = new McpServer(
        {
            name: "photosphere",
            version,
        },
        {
            instructions: PHOTOSPHERE_INSTRUCTIONS,
        },
    );
    registerAllMcpTools(server, sendRequest);
    return server;
}
