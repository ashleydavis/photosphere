import type { ITaskQueue } from "task-queue";
import { RandomUuidGenerator, TimestampProvider } from "utils";
import { TaskQueueProviderInline } from "./lib/task-queue-provider-inline";
import express from "express";
import { createServer } from "http";
import { WebSocketServer, type WebSocket } from "ws";
import { createAssetServer } from "rest-api";
import { exec } from "child_process";
import { promisify } from "util";
import { loadDesktopConfig, addRecentDatabase, removeRecentDatabase, updateLastFolder } from "node-utils";
import * as path from "path";

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
            else if (messageData.type === "remove-database") {
                // Handle database removal request
                await handleRemoveDatabase(ws, messageData.databasePath);
            }
            else if (messageData.type === "get-recent-databases") {
                // Handle request for recent databases list
                await handleGetRecentDatabases(ws);
            }
            else if (messageData.type === "add-recent-database") {
                // Handle request to add database to recent list
                await handleAddRecentDatabase(ws, messageData.databasePath);
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
        const config = await loadDesktopConfig();
        const databasePath = await showDirectoryDialog(config.lastFolder);

        if (databasePath) {
            // Save to recent databases and update last folder
            await addRecentDatabase(databasePath);
            const folderPath = path.dirname(databasePath);
            await updateLastFolder(folderPath);

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
// Handles database removal request from client.
//
async function handleRemoveDatabase(ws: WebSocket, databasePath: string): Promise<void> {
    try {
        await removeRecentDatabase(databasePath);
        ws.send(JSON.stringify({
            type: "database-removed",
            databasePath: databasePath,
        }));
    }
    catch (error: any) {
        console.error("Error removing database:", error);
        ws.send(JSON.stringify({
            type: "error",
            message: error instanceof Error ? error.message : "Unknown error removing database",
        }));
    }
}

//
// Handles request for recent databases list.
//
async function handleGetRecentDatabases(ws: WebSocket): Promise<void> {
    try {
        const config = await loadDesktopConfig();
        ws.send(JSON.stringify({
            type: "recent-databases",
            databases: config.recentDatabases || [],
        }));
    }
    catch (error: any) {
        console.error("Error getting recent databases:", error);
        ws.send(JSON.stringify({
            type: "error",
            message: error instanceof Error ? error.message : "Unknown error getting recent databases",
        }));
    }
}

//
// Handles request to add database to recent list.
//
async function handleAddRecentDatabase(ws: WebSocket, databasePath: string): Promise<void> {
    try {
        await addRecentDatabase(databasePath);
        ws.send(JSON.stringify({
            type: "database-added",
            databasePath: databasePath,
        }));
    }
    catch (error: any) {
        console.error("Error adding recent database:", error);
        ws.send(JSON.stringify({
            type: "error",
            message: error instanceof Error ? error.message : "Unknown error adding recent database",
        }));
    }
}

//
// Shows a directory picker dialog using platform-specific tools.
// Uses lastFolder if provided to set the initial directory.
//
async function showDirectoryDialog(lastFolder?: string): Promise<string | null> {
    const platform = process.platform;
    
    if (platform === "linux") {
        // Try zenity first (GNOME), then kdialog (KDE)
        try {
            let command = "zenity --file-selection --directory --title='Open Database'";
            if (lastFolder) {
                command += ` --filename="${lastFolder}"`;
            }
            const { stdout } = await execAsync(command);
            return stdout.trim() || null;
        }
        catch (error: any) {
            if (error.code === 1) {
                // User cancelled
                throw { code: 1, userCancelled: true };
            }
            // zenity not available, try kdialog
            try {
                let command = "kdialog --getexistingdirectory --title 'Open Database'";
                if (lastFolder) {
                    command += ` "${lastFolder}"`;
                }
                const { stdout } = await execAsync(command);
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
        let script = `
            tell application "System Events"
                activate
                set folderPath to choose folder with prompt "Open Database"
                return POSIX path of folderPath
            end tell
        `;
        // Note: osascript's choose folder doesn't support setting initial directory directly
        // We'd need to use a different approach, but for now just use the default
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
        const initialDir = lastFolder ? `$folderBrowser.SelectedPath = "${lastFolder.replace(/\\/g, "\\\\")}"` : "";
        const script = `
            Add-Type -AssemblyName System.Windows.Forms
            $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
            $folderBrowser.Description = "Open Database"
            $folderBrowser.ShowNewFolderButton = $false
            ${initialDir}
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

