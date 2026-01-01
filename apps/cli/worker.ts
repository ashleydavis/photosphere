//
// Worker script for executing tasks
// This runs in a Bun worker context
// This is the entry point for all workers created by the CLI package
//

import { serializeError } from "serialize-error";
import { executeTaskHandler } from "task-queue/src/lib/worker";
import type { ITaskContext } from "task-queue";
import { initWorkerContext, setWorkerTaskId, type IWorkerContext, type IWorkerOptions } from "./src/lib/worker-init";
import type { WorkerMessage } from "./src/lib/task-queue";
import { initTaskHandlers } from "api";

//
// Register all task handlers
//
initTaskHandlers();

//
// Read worker options from environment variable
//
const workerOptionsJson = process.env.WORKER_OPTIONS;
if (!workerOptionsJson) {
    console.error("WORKER_OPTIONS environment variable is not set");
    process.exit(1);
}

let workerOptions: IWorkerOptions;
try {
    workerOptions = JSON.parse(workerOptionsJson);
} 
catch (error: any) {
    console.error(`Failed to parse WORKER_OPTIONS:`);
    console.error(error.stack || error.message || error);
    process.exit(1);
}

//
// Execute a task handler in the worker
//
async function executeTask(message: WorkerMessage, taskContext: ITaskContext): Promise<void> {
    const { taskId, taskType, data, workingDirectory } = message;

    try {
        // Set task ID for logging prefix and progress messages
        setWorkerTaskId(taskId);

        // Execute the handler with task-specific context
        const outputs = await executeTaskHandler(taskType, data, workingDirectory, taskContext);
        
        // Clear task ID from logging and progress
        setWorkerTaskId(null);
        
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
    }
    catch (error: any) {
        // Clear task ID from logging and progress
        setWorkerTaskId(null);
        
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
// workerContext: Worker context (uuidGenerator, timestampProvider, sessionId, etc.)
//
function initWorker(workerContext: IWorkerContext): void {
    self.onmessage = async (event: MessageEvent<WorkerMessage>) => {
        const message = event.data;

        if (message.type === "execute") {
            const { taskId } = message;

            // Create a task-specific sendMessage function that captures the task ID in a closure
            // This ensures messages are correctly associated with the current task
            const taskSpecificSendMessage = (message: any): void => {
                self.postMessage({
                    type: "message",
                    taskId,
                    message
                });
            };

            // Create a task-specific context with the task-specific sendMessage
            const taskContext: ITaskContext = {
                ...workerContext,
                sendMessage: taskSpecificSendMessage,
            };

            await executeTask(message, taskContext);
        }
    };
    
    // Send ready message to main thread to indicate worker is initialized and ready for tasks
    self.postMessage({ type: "ready" });
}

//
// Initialize worker context and message listener
//
try {
    const context = initWorkerContext(workerOptions);
    initWorker(context);
} 
catch (error: any) {
    console.error(`Failed to initialize worker:`);
    console.error(error.stack || error.message || error);
    process.exit(1);
}
