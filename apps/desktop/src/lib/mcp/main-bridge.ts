//
// Main-process side of the MCP integration. Manages the MCP utility process lifecycle
// (fork, ready handshake, restart-on-crash) and forwards tool requests/responses between
// the renderer and the worker.
//
// main.ts wires this in by:
//   1. calling installMcpHandlers() once during startup (registers ipcMain handlers)
//   2. calling initMcpServer() during app.whenReady() to spawn the worker
//   3. calling stopMcpServer() in before-quit
//
import { app, BrowserWindow, ipcMain, utilityProcess, type UtilityProcess } from "electron";
import { join } from "path";
import { MCP_TOOL_REQUEST, MCP_TOOL_RESPONSE } from "./ipc";
import type { IMcpToolResponse } from "./ipc";
import type { IMcpWorkerStartMessage, IMcpWorkerStopMessage } from "./worker";

//
// Fixed port for the embedded MCP server. Stable across launches so a single MCP client
// configuration keeps working without re-copying the address from the About page.
//
export const MCP_PORT = 3475;

//
// Read-only environment provided by main.ts so the bridge can locate the active main
// window, check shutdown state, and dispatch worker log messages without reaching into
// module-level globals.
//
export interface IMcpBridgeEnvironment {
    //
    // Returns the current main window, or null if one is not open.
    //
    getMainWindow(): BrowserWindow | null;

    //
    // True when the app is shutting down; the worker will not be restarted in this state.
    //
    isShuttingDown(): boolean;

    //
    // Forwards a worker log message into the existing file logger.
    //
    onWorkerLog(message: any): void;
}

//
// Active MCP utility process handle, or null between launches.
//
let mcpWorker: UtilityProcess | null = null;

//
// The environment supplied by installMcpHandlers/initMcpServer.
//
let env: IMcpBridgeEnvironment | undefined;

//
// Registers main-process IPC handlers used by the renderer and MCP worker. Idempotent
// (safe to call once during startup, before initMcpServer).
//
export function installMcpHandlers(environment: IMcpBridgeEnvironment): void {
    env = environment;

    //
    // IPC bridge: forward renderer responses back to the MCP worker.
    //
    ipcMain.on(MCP_TOOL_RESPONSE, (_event, response: IMcpToolResponse) => {
        if (mcpWorker) {
            mcpWorker.postMessage({ type: MCP_TOOL_RESPONSE, ...response });
        }
    });
}

//
// Forks the MCP utility process, waits for it to become ready, and wires the persistent
// message handler that forwards tool requests to the renderer. Restarts on non-zero exit
// unless the app is shutting down.
//
export async function initMcpServer(): Promise<void> {
    if (!env) {
        throw new Error("installMcpHandlers must be called before initMcpServer");
    }

    const serverPath = join(app.getAppPath(), "bundle/mcp/worker.js");
    const workerEnv: Record<string, string> = { ...process.env } as Record<string, string>;

    mcpWorker = utilityProcess.fork(serverPath, [], { env: workerEnv });

    mcpWorker.on("exit", async (code) => {
        if (code !== 0) {
            console.error(`MCP worker exited with code ${code}`);
        }
        mcpWorker = null;
        if (!env?.isShuttingDown()) {
            console.log("Restarting MCP worker...");
            try {
                await initMcpServer();
            }
            catch (error: any) {
                console.error("Failed to restart MCP worker:", error);
            }
        }
    });

    await new Promise<void>((resolve, reject) => {
        const timeout = setTimeout(() => {
            mcpWorker?.off("message", messageHandler);
            mcpWorker?.off("spawn", spawnHandler);
            reject(new Error("MCP server failed to start within timeout"));
        }, 10000);

        const messageHandler = (message: any) => {
            if (!message || typeof message !== "object") {
                return;
            }
            if (message.type === "server-ready") {
                clearTimeout(timeout);
                mcpWorker?.off("message", messageHandler);
                mcpWorker?.off("spawn", spawnHandler);
                console.log(`MCP server initialized in utility process on port ${MCP_PORT}`);
                resolve();
            }
            else if (message.type === "server-error") {
                clearTimeout(timeout);
                mcpWorker?.off("message", messageHandler);
                mcpWorker?.off("spawn", spawnHandler);
                console.error("MCP server error:", message.error);
                reject(new Error(`MCP server failed to start: ${message.error}`));
            }
        };

        const spawnHandler = () => {
            console.log("MCP utility process spawned");
            if (mcpWorker) {
                const startMessage: IMcpWorkerStartMessage = { type: "start", port: MCP_PORT };
                mcpWorker.postMessage(startMessage);
            }
        };

        if (!mcpWorker) {
            reject(new Error("Failed to fork MCP utility process"));
            return;
        }

        mcpWorker.on("message", messageHandler);
        mcpWorker.on("spawn", spawnHandler);
    });

    //
    // Persistent message handler: forwards tool requests to the renderer and routes
    // log messages into the host's logger.
    //
    mcpWorker.on("message", (message: any) => {
        if (!message || typeof message !== "object") {
            return;
        }
        if (message.type === MCP_TOOL_REQUEST) {
            const mainWindow = env?.getMainWindow();
            if (mainWindow) {
                mainWindow.webContents.send(MCP_TOOL_REQUEST, {
                    requestId: message.requestId,
                    tool: message.tool,
                    args: message.args,
                });
            }
        }
        else if (message.type === "log") {
            env?.onWorkerLog(message);
        }
    });
}

//
// Stops the MCP worker (call from before-quit). Sends a graceful stop and then kills.
//
export function stopMcpServer(): void {
    if (!mcpWorker) {
        return;
    }
    const stopMessage: IMcpWorkerStopMessage = { type: "stop" };
    mcpWorker.postMessage(stopMessage);
    mcpWorker.kill();
    mcpWorker = null;
}
