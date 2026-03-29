//
// Electron utility process entry point
// Routes messages to the appropriate handler from shared packages
//
import { serializeError } from "serialize-error";
import { executeTaskHandler } from "task-queue";
import type { ITaskContext } from "task-queue";
import { type IWorkerOptions } from "./lib/worker-backend-electron-main";
import { initTaskHandlers } from "api";
import type { IWorkerMessage, IWorkerTaskCompletedMessage, IWorkerTaskMessage, IWorkerReadyMessage } from "./lib/worker-backend-electron-main";
import { RandomUuidGenerator, TimestampProvider, setLog, log } from "utils";
import { TestUuidGenerator, TestTimestampProvider } from "node-utils";
import { createWorkerLog } from "./lib/worker-log-electron";

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
// Post message function for Electron utility process
//
const parentPort = (process as any).parentPort;
if (!parentPort) {
    throw new Error('parentPort not available - this must run in an Electron utility process');
}

//
// Execute a task handler in the worker
//
async function executeTask(message: IWorkerMessage, taskContext: ITaskContext): Promise<void> {
    const { taskId, taskType, data } = message;

    try {
        // Execute the handler with task-specific context
        const outputs = await executeTaskHandler(taskType, data, taskContext);

        // Send success result back to main thread
        const successMessage: IWorkerTaskCompletedMessage = {
            type: "task-completed",
            taskId,
            result: {
                status: "succeeded",
                outputs: outputs
            }
        };
        parentPort.postMessage(successMessage);
    }
    catch (error: any) {
        // Send error result back to main thread as task-completed with status failed
        const errorMessage: IWorkerTaskCompletedMessage = {
            type: "task-completed",
            taskId,
            result: {
                status: "failed",
                error: serializeError(error)
            }
        };
        parentPort.postMessage(errorMessage);
    }
}

//
// Initialize IPC-based logging to send messages to main process
//
setLog(createWorkerLog(workerOptions.verbose, workerOptions.tools));

const uuidGenerator = process.env.NODE_ENV === "testing" ? new TestUuidGenerator() : new RandomUuidGenerator();
const timestampProvider = process.env.NODE_ENV === "testing" ? new TestTimestampProvider() : new TimestampProvider();
const sessionId = workerOptions.sessionId;

//
// Initialize the worker message listener
//
function initWorker(): void {
    parentPort.on('message', async (event: any) => {
        const message = event.data;

        if (message.type === 'execute') {
            const { taskId } = message;

            // Create a task-specific sendMessage function that captures the task ID in a closure
            // This ensures messages are correctly associated with the current task
            const taskSpecificSendMessage = (message: any): void => {
                const taskMessage: IWorkerTaskMessage = {
                    type: "task-message",
                    taskId,
                    message
                };
                parentPort.postMessage(taskMessage);
            };

            const taskContext: ITaskContext = {
                uuidGenerator,
                timestampProvider,
                sessionId,
                sendMessage: taskSpecificSendMessage,
            };

            await executeTask(message, taskContext);
        }
        else {
            throw new Error(`Unknown message type: ${message.type}`);
        }
    });
    
    // Send ready message to main thread to indicate worker is initialized and ready for tasks
    const readyMessage: IWorkerReadyMessage = { type: "worker-ready" };
    parentPort.postMessage(readyMessage);
}

//
// Initialize worker and message listener
//
try {
    initWorker();
}
catch (error: any) {
    log.exception('Failed to initialize worker', error);
    process.exit(1);
}

//
// Handle uncaught exceptions in the worker process
//
process.on('uncaughtException', (error) => {
    log.exception('Uncaught exception in worker process', error);
    process.exit(1);
});

//
// Handle unhandled promise rejections in the worker process
//
process.on('unhandledRejection', (reason, promise) => {
    const error = reason instanceof Error ? reason : new Error(String(reason));
    log.exception('Unhandled rejection in worker process', error);
    process.exit(1);
});
