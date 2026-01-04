import type { ITaskQueue } from "task-queue";
import { RandomUuidGenerator } from "utils";
import type { ITaskQueueProvider } from "task-queue";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { InlineTaskQueue } from "./inline-task-queue";
import { createStorage } from "storage";
import { createMediaFileDatabase, loadDatabase, streamAsset } from "api/src/lib/media-file-database";
import { TimestampProvider } from "utils";
import express from "express";
import type { Request, Response } from "express";
import { createServer } from "http";
import { WebSocketServer, type WebSocket } from "ws";

const PORT = 3001;

// Create a task queue provider for dev-server that executes tasks inline
class DevServerTaskQueueProvider implements ITaskQueueProvider {
    private uuidGenerator: RandomUuidGenerator;
    private maxConcurrent = 10;

    constructor(uuidGenerator: RandomUuidGenerator) {
        this.uuidGenerator = uuidGenerator;
    }

    async create(): Promise<ITaskQueue> {
        // Create a new queue for each WebSocket connection
        const baseWorkingDirectory = join(tmpdir(), "task-queue");
        return new InlineTaskQueue(
            this.maxConcurrent,
            baseWorkingDirectory,
            this.uuidGenerator,
            {
                verbose: true,
                sessionId: this.uuidGenerator.generate(),
            }
        );
    }
}

const taskQueueProvider = new DevServerTaskQueueProvider(new RandomUuidGenerator());

// Map of WebSocket connections to their task queues
const wsTaskQueues = new Map<WebSocket, ITaskQueue>();

//
// Helper function to load an asset and return it as a stream
//
async function loadAssetStream(assetId: string, assetType: string, databaseId: string): Promise<NodeJS.ReadableStream> {
    const uuidGenerator = new RandomUuidGenerator(); //todo: these should be passed in..
    const timestampProvider = new TimestampProvider();

    // Use hardcoded path to test database (relative to project root)
    // TODO: Resolve databaseId to actual database path
    const dbDir = resolve(import.meta.dir, "../../../test/dbs/50-assets");
    // const dbDir = resolve(import.meta.dir, "../../../test/dbs/1-asset");
    // const dbDir = resolve(import.meta.dir, "../../../test/dbs/v5");

    // Create storage without encryption
    const { storage: assetStorage } = createStorage(dbDir, undefined, undefined);
    
    // Create database instance
    const database = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);
    
    // Load the database
    await loadDatabase(assetStorage, database.metadataCollection);
    
    // Stream the asset
    return streamAsset(assetStorage, assetId, assetType);
}

// Create Express app for HTTP routes
const app = express();

// Enable CORS for all routes
app.use((req: Request, res: Response, next: express.NextFunction) => {
    res.header("Access-Control-Allow-Origin", "*");
    res.header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
    res.header("Access-Control-Allow-Headers", "Origin, X-Requested-With, Content-Type, Accept");
    if (req.method === "OPTIONS") {
        res.sendStatus(200);
        return;
    }
    next();
});

// Handle HTTP GET requests for assets
app.get("/asset", async (req: Request, res: Response) => {
    const assetId = req.query.id as string;
    const databaseId = req.query.db as string;
    const assetType = req.query.type as string;

    if (!assetId) {
        res.status(400).send("Missing 'id' parameter");
        return;
    }

    if (!databaseId) {
        res.status(400).send("Missing 'db' parameter");
        return;
    }

    if (!assetType) {
        res.status(400).send("Missing 'type' parameter");
        return;
    }

    console.log(`Loading asset stream ${assetId} of type ${assetType} from database ${databaseId}`);

    const assetStream = await loadAssetStream(assetId, assetType, databaseId);
    
    res.setHeader("Content-Type", "application/octet-stream");
    assetStream.pipe(res);
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

            if (messageData.type === "queue-task") {
                // Get or create task queue for this WebSocket connection
                let queue = wsTaskQueues.get(ws);
                if (!queue) {
                    queue = await taskQueueProvider.create();
                    wsTaskQueues.set(ws, queue);

                    // Set up task completion handler to send results back to client
                    queue.onTaskComplete(async (taskResult) => {
                        ws.send(JSON.stringify({
                            type: "task-completed",
                            taskId: taskResult.taskId,
                            result: taskResult,
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

