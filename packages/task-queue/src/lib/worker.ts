//
// Worker script for executing tasks
// This runs in a Bun worker context
//

import { getHandler } from "./handler-registry";

interface WorkerMessage {
    type: "execute";
    taskId: string;
    taskType: string;
    data: any;
    workingDirectory: string;
}

//
// Execute a task handler in the worker
//
async function executeTask(message: WorkerMessage): Promise<void> {
    const { taskId, taskType, data, workingDirectory } = message;

    try {
        // Get handler from registry
        const handler = getHandler(taskType);
        if (!handler) {
            throw new Error(`No handler registered for task type: ${taskType}`);
        }

        // Execute the handler
        const result = await handler(data, workingDirectory);

        // Send success result back to main thread
        self.postMessage({
            type: "result",
            taskId,
            result: {
                status: "completed" as const,
                message: result
            }
        });
    } catch (error: any) {
        // Send error result back to main thread
        self.postMessage({
            type: "error",
            taskId,
            error: {
                message: error.message || String(error),
                stack: error.stack
            }
        });
    }
}

//
// Listen for messages from the main thread
//
self.onmessage = async (event: MessageEvent<WorkerMessage>) => {
    const message = event.data;

    if (message.type === "execute") {
        await executeTask(message);
    }
};

