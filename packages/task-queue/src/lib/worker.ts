//
// Worker script for executing tasks
// This runs in a Bun worker context
//

//
// Handler storage - shared between main thread and workers
//
export type TaskHandler = (data: any, workingDirectory: string) => Promise<any>;

const handlers = new Map<string, TaskHandler>();

export function registerHandler(type: string, handler: TaskHandler): void {
    handlers.set(type, handler);
}

export function getHandler(type: string): TaskHandler | undefined {
    return handlers.get(type);
}

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
        // Get handler from shared storage
        const handler = getHandler(taskType);
        if (!handler) {
            throw new Error(`No handler registered for task type: ${taskType}`);
        }

        // Execute the handler
        const outputs = await handler(data, workingDirectory);

        // Send success result back to main thread
        self.postMessage({
            type: "result",
            taskId,
            result: {
                status: "completed" as const,
                message: typeof outputs === "string" ? outputs : "Task completed successfully",
                outputs: outputs
            }
        });
    } catch (error: any) {
        // Send error result back to main thread
        self.postMessage({
            type: "error",
            taskId,
            error: {
                message: error.message || String(error),
                stack: error.stack,
                name: error.name
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

