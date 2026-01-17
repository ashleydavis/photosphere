import type { ITaskQueue } from "task-queue";
import { RandomUuidGenerator, TimestampProvider } from "utils";
import { TaskQueueProviderInline } from "./lib/task-queue-provider-inline";
import express from "express";
import { createServer } from "http";
import { WebSocketServer, type WebSocket } from "ws";
import { createAssetServer } from "rest-api";
import { exec } from "child_process";
import { promisify } from "util";

const execAsync = promisify(exec);

const PORT = 3001;

const uuidGenerator = new RandomUuidGenerator();
const timestampProvider = new TimestampProvider();
const sessionId = uuidGenerator.generate();
const taskQueueProvider = new TaskQueueProviderInline(uuidGenerator, timestampProvider, sessionId);

// Map of WebSocket connections to their task queues
const wsTaskQueues = new Map<WebSocket, ITaskQueue>();

// Create Express app for HTTP routes
const app = express();

// Enable CORS for all routes
app.use((req, res, next) => {
    res.header("Access-Control-Allow-Origin", "*");
    res.header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    res.header("Access-Control-Allow-Headers", "Origin, X-Requested-With, Content-Type, Accept");
    if (req.method === "OPTIONS") {
        res.sendStatus(200);
        return;
    }
    next();
});

// Attach asset server routes to existing Express app
await createAssetServer({
    app,
    uuidGenerator,
    timestampProvider,
});

// Create HTTP server from Express app
const server = createServer(app);

// Create WebSocket server attached to the same HTTP server
const wss = new WebSocketServer({ server });

wss.on("connection", (ws: WebSocket) => {
    console.log("WebSocket connection opened");

    ws.on("message", async (message: Buffer) => {
        try {
            const messageData = JSON.parse(message.toString());

            if (messageData.type === "add-task") {
                // Get or create task queue for this WebSocket connection
                let queue = wsTaskQueues.get(ws);
                if (!queue) {
                    queue = await taskQueueProvider.create();
                    wsTaskQueues.set(ws, queue);

                    // Set up task completion handler to send results back to client
                    queue.onTaskComplete(async (task, result) => {
                        ws.send(JSON.stringify({
                            type: "task-completed",
                            taskId: result.taskId,
                            task: {
                                id: task.id,
                                type: task.type,
                                status: task.status,
                                data: task.data,
                                createdAt: task.createdAt.toISOString(),
                                startedAt: task.startedAt?.toISOString(),
                                completedAt: task.completedAt?.toISOString(),
                            },
                            result: result,
                        }));
                    });

                    // Set up task message handler to send messages back to client
                    // Register for all message types
                    queue.onAnyTaskMessage(data => {
                        ws.send(JSON.stringify({
                            type: "task-message",
                            ...data, // TODO: might be better to just copy reference without spreading.
                        }));
                    });
                }

                // Queue the task using the client-provided task ID
                const taskId = queue.addTask(messageData.taskType, messageData.data, messageData.taskId);
                console.log(`Queued task ${taskId} of type ${messageData.taskType}`);
            }
            else if (messageData.type === "open-database") {
                // Handle database opening request
                await handleOpenDatabase(ws);
            }
        }
        catch (error) {
            console.error("Error handling WebSocket message:", error);
            ws.send(JSON.stringify({
                type: "error",
                message: error instanceof Error ? error.message : "Unknown error",
            }));
        }
    });

    ws.on("close", () => {
        console.log("WebSocket connection closed");
        // Clean up task queue for this connection
        const queue = wsTaskQueues.get(ws);
        if (queue) {
            queue.shutdown();
            wsTaskQueues.delete(ws);
        }
    });
});

//
// Handles database opening request from client.
//
async function handleOpenDatabase(ws: WebSocket): Promise<void> {
    try {
        const databasePath = await showDirectoryDialog();

        if (databasePath) {
            // Send database-opened message back to client
            ws.send(JSON.stringify({
                type: "database-opened",
                databasePath: databasePath,
            }));
        }
    }
    catch (error: any) {
        // User cancelled or error occurred
        if (error.code === 1 || error.userCancelled) {
            // User cancelled - don't send error, just return
            console.log("User cancelled database opening");
            return;
        }
        console.error("Error opening database:", error);
        ws.send(JSON.stringify({
            type: "error",
            message: error instanceof Error ? error.message : "Unknown error opening database",
        }));
    }
}

//
// Shows a directory picker dialog using platform-specific tools.
//
async function showDirectoryDialog(): Promise<string | null> {
    const platform = process.platform;
    
    if (platform === "linux") {
        // Try zenity first (GNOME), then kdialog (KDE)
        try {
            const { stdout } = await execAsync("zenity --file-selection --directory --title='Open Database'");
            return stdout.trim() || null;
        }
        catch (error: any) {
            if (error.code === 1) {
                // User cancelled
                throw { code: 1, userCancelled: true };
            }
            // zenity not available, try kdialog
            try {
                const { stdout } = await execAsync("kdialog --getexistingdirectory --title 'Open Database'");
                return stdout.trim() || null;
            }
            catch (kdialogError: any) {
                if (kdialogError.code === 1) {
                    // User cancelled
                    throw { code: 1, userCancelled: true };
                }
                throw new Error("Neither zenity nor kdialog is available. Please install one of them.");
            }
        }
    }
    else if (platform === "darwin") {
        // macOS - use osascript (AppleScript)
        const script = `
            tell application "System Events"
                activate
                set folderPath to choose folder with prompt "Open Database"
                return POSIX path of folderPath
            end tell
        `;
        try {
            const { stdout } = await execAsync(`osascript -e '${script}'`);
            return stdout.trim() || null;
        }
        catch (error: any) {
            if (error.code === 1 || error.stderr?.includes("User cancelled")) {
                throw { code: 1, userCancelled: true };
            }
            throw error;
        }
    }
    else if (platform === "win32") {
        // Windows - use PowerShell
        const script = `
            Add-Type -AssemblyName System.Windows.Forms
            $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
            $folderBrowser.Description = "Open Database"
            $folderBrowser.ShowNewFolderButton = $false
            if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                Write-Output $folderBrowser.SelectedPath
            }
        `;
        try {
            const { stdout } = await execAsync(`powershell -Command "${script.replace(/\n/g, "; ")}"`);
            return stdout.trim() || null;
        }
        catch (error: any) {
            if (error.code === 1) {
                throw { code: 1, userCancelled: true };
            }
            throw error;
        }
    }
    else {
        throw new Error(`Unsupported platform: ${platform}`);
    }
}

// Start server
server.listen(PORT, () => {
    console.log(`Server running on http://localhost:${PORT} (HTTP) and ws://localhost:${PORT} (WebSocket)`);
});

