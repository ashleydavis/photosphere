//
// Electron utility process entry point for the embedded MCP server. Hosts a Streamable
// HTTP server. Each tool call is forwarded to the main process (and on to the renderer)
// via IPC; tool results travel back along the same path.
//
import express from "express";
import type { Request, Response } from "express";
import type { Server } from "node:http";
import { randomUUID } from "node:crypto";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { createMcpServer } from "./server";
import { MCP_TOOL_REQUEST, MCP_TOOL_RESPONSE } from "./ipc";
import type { IMcpToolRequest, IMcpToolResponse } from "./ipc";

//
// Sent by the main process to start the server on a given port.
//
export interface IMcpWorkerStartMessage {
    type: "start";
    port: number;
}

//
// Sent by the main process to stop the HTTP server.
//
export interface IMcpWorkerStopMessage {
    type: "stop";
}

//
// Sent for every renderer reply to a previously forwarded tool request.
//
export interface IMcpWorkerToolResponseMessage extends IMcpToolResponse {
    type: typeof MCP_TOOL_RESPONSE;
}

const parentPort = (process as any).parentPort;
if (!parentPort) {
    throw new Error("parentPort not available - mcp-worker must run as an Electron utility process");
}

//
// Pending tool requests, keyed by requestId. Resolved when the response arrives from
// the renderer.
//
const pendingRequests = new Map<string, (response: IMcpToolResponse) => void>();

//
// Sends a tool request to the main process and resolves with the renderer's reply.
//
function sendRequest(tool: string, args: Record<string, unknown>): Promise<string> {
    const requestId = randomUUID();
    return new Promise<string>((resolve, reject) => {
        pendingRequests.set(requestId, response => {
            pendingRequests.delete(requestId);
            if (response.error) {
                reject(new Error(response.error));
            }
            else {
                resolve(response.result ?? "");
            }
        });
        const message: IMcpToolRequest & { type: string } = {
            type: MCP_TOOL_REQUEST,
            requestId,
            tool,
            args,
        };
        parentPort.postMessage(message);
    });
}

let httpServer: Server | undefined;

//
// Starts the Streamable HTTP MCP server on the given port. Reports back to the main
// process when it is ready (or has failed).
//
async function startServer(port: number): Promise<void> {
    const app = express();
    app.use(express.json());

    //
    // Stateless: each request gets a fresh McpServer AND transport. The MCP SDK only
    // permits one transport per server instance, so a long-lived server reused across
    // requests fails with "Already connected to a transport" on the second call.
    //
    const handleRequest = async (req: Request, res: Response): Promise<void> => {
        const mcpServer = createMcpServer(sendRequest);
        const transport = new StreamableHTTPServerTransport({
            sessionIdGenerator: undefined,
        });
        res.on("close", () => {
            transport.close();
            void mcpServer.close();
        });
        try {
            await mcpServer.connect(transport);
            await transport.handleRequest(req, res, req.body);
        }
        catch (error) {
            if (!res.headersSent) {
                res.status(500).json({
                    jsonrpc: "2.0",
                    error: {
                        code: -32603,
                        message: error instanceof Error ? error.message : String(error),
                    },
                    id: null,
                });
            }
        }
    };

    app.post("/mcp", handleRequest);
    app.get("/mcp", handleRequest);

    await new Promise<void>((resolve, reject) => {
        httpServer = app.listen(port, "127.0.0.1", () => {
            parentPort.postMessage({ type: "server-ready", port });
            resolve();
        });
        httpServer.on("error", error => {
            parentPort.postMessage({ type: "server-error", error: error.message });
            reject(error);
        });
    });
}

//
// Closes the HTTP server.
//
function stopServer(): void {
    if (!httpServer) {
        parentPort.postMessage({ type: "server-stopped" });
        return;
    }
    httpServer.close(() => {
        parentPort.postMessage({ type: "server-stopped" });
    });
    httpServer = undefined;
}

parentPort.on("message", (event: { data: any }) => {
    const message = event.data;
    if (!message || typeof message !== "object") {
        return;
    }
    switch (message.type) {
        case "start": {
            const startMsg = message as IMcpWorkerStartMessage;
            void startServer(startMsg.port).catch(error => {
                parentPort.postMessage({ type: "server-error", error: error.message });
            });
            break;
        }
        case "stop":
            stopServer();
            break;
        case MCP_TOOL_RESPONSE: {
            const response = message as IMcpWorkerToolResponseMessage;
            const resolver = pendingRequests.get(response.requestId);
            if (resolver) {
                resolver(response);
            }
            break;
        }
    }
});

process.on("uncaughtException", error => {
    parentPort.postMessage({ type: "log", level: "exception", message: "Uncaught exception in mcp-worker", error: String(error) });
});

process.on("unhandledRejection", reason => {
    parentPort.postMessage({ type: "log", level: "exception", message: "Unhandled rejection in mcp-worker", error: String(reason) });
});
