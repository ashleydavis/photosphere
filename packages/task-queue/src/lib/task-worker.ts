//
// Worker infrastructure for task execution
// This module provides the core worker functionality that can be imported
// by application-specific worker files
//

import { serializeError } from "serialize-error";

//
// Handler registry - handlers are stored in a Map
//
export type TaskHandler = (data: any, workingDirectory: string) => Promise<any>;

const handlers = new Map<string, TaskHandler>();

export function registerHandler(type: string, handler: TaskHandler): void {
    handlers.set(type, handler);
}

export function getHandler(type: string): TaskHandler | undefined {
    return handlers.get(type);
}

export function getRegisteredHandlerTypes(): string[] {
    return Array.from(handlers.keys());
}

export interface WorkerMessage {
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
        // Get handler (registered statically when worker module loads)
        const registeredTypes = getRegisteredHandlerTypes();
        const handler = getHandler(taskType);
        if (!handler) {
            throw new Error(`No handler registered for task type: ${taskType}. Available handlers: ${registeredTypes.join(", ")}`);
        }

        // Execute the handler
        const outputs = await handler(data, workingDirectory);
        
        // Send success result back to main thread
        self.postMessage({
            type: "result",
            taskId,
            result: {
                status: "completed",
                message: typeof outputs === "string" ? outputs : "Task completed successfully",
                outputs: outputs
            }
        });
    } catch (error: any) {
        // Send error result back to main thread
        self.postMessage({
            type: "error",
            taskId,
            error: serializeError(error)
        });
    }
}

//
// Initialize the worker message listener
// This should be called by application-specific worker files after registering handlers
//
export function initWorker(): void {
    self.onmessage = async (event: MessageEvent<WorkerMessage>) => {
        const message = event.data;

        if (message.type === "execute") {
            await executeTask(message);
        }
    };
    
    // Send ready message to main thread to indicate worker is initialized and ready for tasks
    self.postMessage({ type: "ready" });
}

