//
// Channel name for tool requests sent from the MCP worker to the renderer (via main process).
//
export const MCP_TOOL_REQUEST = "mcp-tool-request";

//
// Channel name for tool responses sent from the renderer back to the MCP worker.
//
export const MCP_TOOL_RESPONSE = "mcp-tool-response";

//
// Tool invocation forwarded from the MCP worker through the main process to the renderer.
//
export interface IMcpToolRequest {
    //
    // Unique identifier that pairs the request with its response.
    //
    requestId: string;

    //
    // MCP tool name (e.g. "list_assets", "get_asset_info").
    //
    tool: string;

    //
    // Tool arguments as a plain JSON object.
    //
    args: Record<string, unknown>;
}

//
// Response from the renderer to the MCP worker for a previously sent request.
//
export interface IMcpToolResponse {
    //
    // Matches the requestId of the originating request.
    //
    requestId: string;

    //
    // Text payload of the tool's result, present on success.
    //
    result?: string;

    //
    // Error message, present on failure.
    //
    error?: string;
}
