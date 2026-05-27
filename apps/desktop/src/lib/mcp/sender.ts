//
// Signature of the function each tool uses to forward a request from the MCP worker
// through the main process to the renderer (and to receive the renderer's reply).
// Provided by mcp-worker.ts.
//
export type McpSendRequest = (tool: string, args: Record<string, unknown>) => Promise<string>;
