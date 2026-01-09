import type { ITaskQueue } from "task-queue";
import { RandomUuidGenerator, TimestampProvider } from "utils";
import { TaskQueueProviderInline } from "./task-queue-provider-inline";
import express from "express";
import { createServer } from "http";
import { WebSocketServer, type WebSocket } from "ws";
import { createAssetServer } from "rest-api";

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

// Start server
server.listen(PORT, () => {
    console.log(`Server running on http://localhost:${PORT} (HTTP) and ws://localhost:${PORT} (WebSocket)`);
});

