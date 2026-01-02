import type { ITaskQueue } from "task-queue";
import { RandomUuidGenerator } from "utils";
import type { ITaskQueueProvider } from "task-queue";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { InlineTaskQueue } from "./inline-task-queue";

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
// Note: Using 'any' for WebSocket type because Bun's ServerWebSocket doesn't match browser WebSocket type
const wsTaskQueues = new Map<any, ITaskQueue>();

Bun.serve({
    port: PORT,
    fetch(req, server) {
        // Upgrade HTTP request to WebSocket
        if (server.upgrade(req)) {
            return; // WebSocket upgrade successful
        }
        return new Response("Expected WebSocket connection", { status: 400 });
    },
    websocket: {
        async message(ws, message) {
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
        },
        open(ws) {
            console.log("WebSocket connection opened");
        },
        close(ws) {
            console.log("WebSocket connection closed");
            // Clean up task queue for this connection
            const queue = wsTaskQueues.get(ws);
            if (queue) {
                queue.shutdown();
                wsTaskQueues.delete(ws);
            }
        },
    },
});

console.log(`WebSocket server running on ws://localhost:${PORT}`);

