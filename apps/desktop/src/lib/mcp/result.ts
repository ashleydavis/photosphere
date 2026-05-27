import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";

//
// Wraps a plain string as an MCP CallToolResult with a single text content block.
//
export function textResult(text: string): CallToolResult {
    return {
        content: [
            {
                type: "text",
                text,
            },
        ],
    };
}
