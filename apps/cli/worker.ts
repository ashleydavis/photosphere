//
// Worker script for executing tasks
// This runs in a Bun worker context
// This is the entry point for all workers created by the CLI package
//

import { serializeError } from "serialize-error";
import { executeTaskHandler, TaskStatus } from "task-queue";
import type { ITaskContext } from "task-queue";
import { initWorkerContext, setWorkerTaskId, type IWorkerContext, type IWorkerOptions } from "./src/lib/worker-init";
import type { IWorkerMessage, IWorkerTaskCompletedMessage, IWorkerTaskMessage, IWorkerReadyMessage } from "./src/lib/worker-backend-bun";
import { initTaskHandlers } from "api";
import { log } from "utils";

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
async function executeTask(message: IWorkerMessage, taskContext: ITaskContext): Promise<void> {
    const { taskId, taskType, data } = message;

    try {
        // Set task ID for logging prefix and progress messages
        setWorkerTaskId(taskId);

        log.verbose(`Executing task ${taskId} with type ${taskType} and payload ${JSON.stringify(data, null, 2)}`);

        // Execute the handler with task-specific context
        const outputs = await executeTaskHandler(taskType, data, taskContext);

        log.verbose(`Task ${taskId} completed with outputs ${JSON.stringify(outputs, null, 2)}`);
        
        // Clear task ID from logging and progress
        setWorkerTaskId(null);
        
        // Send success result back to main thread
        const successMessage: IWorkerTaskCompletedMessage = {
            type: "task-completed",
            taskId,
            result: {
                taskId,
                status: TaskStatus.Succeeded,
                outputs: outputs
            }
        };
        self.postMessage(successMessage);
    }
    catch (error: any) {
        if (log.verboseEnabled) {
            log.verbose(`Task ${taskId} failed with error ${JSON.stringify(serializeError(error), null, 2)}`);
        }

        // Clear task ID from logging and progress
        setWorkerTaskId(null);
        
        // Send error result back to main thread as task-completed with status failed
        const errorMessage: IWorkerTaskCompletedMessage = {
            type: "task-completed",
            taskId,
            result: {
                taskId,
                status: TaskStatus.Failed,
                error: serializeError(error)
            }
        };
        self.postMessage(errorMessage);
    }
}

//
// Initialize the worker message listener
// workerContext: Worker context (uuidGenerator, timestampProvider, sessionId, etc.)
//
function initWorker(workerContext: IWorkerContext): void {
    self.onmessage = async (event: MessageEvent<IWorkerMessage>) => {
        const message = event.data;

        if (message.type === "execute") {
            const { taskId } = message;

            // Create a task-specific sendMessage function that captures the task ID in a closure
            // This ensures messages are correctly associated with the current task
            const taskSpecificSendMessage = (message: any): void => {
                const taskMessage: IWorkerTaskMessage = {
                    type: "task-message",
                    taskId,
                    message
                };
                self.postMessage(taskMessage);
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
    const readyMessage: IWorkerReadyMessage = { type: "worker-ready" };
    self.postMessage(readyMessage);
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
