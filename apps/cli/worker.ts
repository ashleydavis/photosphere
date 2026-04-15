//
// Bun worker script for executing background tasks.
//

import { serializeError } from "serialize-error";
import { executeTaskHandler, TaskStatus, TaskContext, setQueueBackend, WorkerQueueBackend } from "task-queue";
import type { ITaskContext } from "task-queue";
import { createWorkerLog, setWorkerTaskId } from "./src/lib/worker-log-bun";
import type { IWorkerOptions } from "./src/lib/worker-pool-bun";
import type { IWorkerMessage, IWorkerTaskCompletedMessage, IWorkerTaskMessage, IWorkerReadyMessage } from "./src/lib/worker-pool-bun";
import { initTaskHandlers } from "api";
import { RandomUuidGenerator, TimestampProvider, setLog, log } from "utils";
import { TestUuidGenerator, TestTimestampProvider } from "node-utils";

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

setLog(createWorkerLog(workerOptions.workerId, workerOptions.verbose || false, workerOptions.tools || false));

const uuidGenerator = process.env.NODE_ENV === "testing" ? new TestUuidGenerator() : new RandomUuidGenerator();
const timestampProvider = process.env.NODE_ENV === "testing" ? new TestTimestampProvider() : new TimestampProvider();
const sessionId = workerOptions.sessionId || uuidGenerator.generate();

//
// Worker-side queue backend — receives child task completions forwarded from the main thread.
//
const workerBackend = new WorkerQueueBackend((message) => self.postMessage(message));
setQueueBackend(workerBackend);

//
// Execute a task handler in the worker
//
async function executeTask(message: IWorkerMessage, taskContext: ITaskContext): Promise<void> {
    const { taskId, taskType, data } = message;

    try {
        // Set task ID for logging prefix and progress messages
        setWorkerTaskId(taskId);

        // log.verbose(`Executing task ${taskId} with type ${taskType} and payload ${JSON.stringify(data, null, 2)}`);

        // Execute the handler with task-specific context
        const outputs = await executeTaskHandler(taskType, data, taskContext);

        // log.verbose(`Task ${taskId} completed with outputs ${JSON.stringify(outputs, null, 2)}`);
        
        // Clear task ID from logging and progress
        setWorkerTaskId(null);
        
        // Send success result back to main thread
        const successMessage: IWorkerTaskCompletedMessage = {
            type: "task-completed",
            taskId,
            result: {
                taskId,
                type: taskType,
                inputs: data,
                status: TaskStatus.Succeeded,
                outputs,
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
                type: taskType,
                inputs: data,
                status: TaskStatus.Failed,
                error: serializeError(error),
                errorMessage: error instanceof Error ? error.message : String(error),
            }
        };
        self.postMessage(errorMessage);
    }
}

//
// The source tag of the currently executing task, null when idle.
//
let currentTaskSource: string | null = null;

//
// The currently executing task context, null when idle.
//
let currentTaskContext: TaskContext | null = null;

//
// Sends a message from the current task back to the caller via the main thread.
//
function sendMessageFn(msg: any): void {
    const taskMessage: IWorkerTaskMessage = {
        type: "task-message",
        taskId: currentTaskContext!.taskId,
        message: msg
    };
    self.postMessage(taskMessage);
}

//
// Initialize the worker message listener
//
function initWorker(): void {
    self.onmessage = async (event: MessageEvent<any>) => {
        const message = event.data;

        if (message.type === "execute") {
            const { taskId, source } = message as IWorkerMessage;
            currentTaskSource = source;
            currentTaskContext = new TaskContext(uuidGenerator, timestampProvider, sessionId, taskId, sendMessageFn);

            await executeTask(message, currentTaskContext);
            currentTaskContext = null;
            currentTaskSource = null;
        }
        else if (message.type === "cancel-tasks") {
            if (currentTaskSource === message.source) {
                currentTaskContext?.cancel();
            }
            workerBackend.cancelTasks(message.source);
        }
        else if (message.type === "task-completed") {
            const taskCompletedMessage = message as IWorkerTaskCompletedMessage;
            await workerBackend.notifyTaskCompleted(taskCompletedMessage.result);
        }
        else {
            throw new Error(`Unknown message type: ${message.type}`);
        }
    };
    
    // Send ready message to main thread to indicate worker is initialized and ready for tasks
    const readyMessage: IWorkerReadyMessage = { type: "worker-ready" };
    self.postMessage(readyMessage);
}

//
// Initialize worker message listener
//
try {
    initWorker();
}
catch (error: any) {
    log.exception(`Failed to initialize worker`, error);
    process.exit(1);
}

//
// Handle uncaught exceptions in the worker process
//
process.on('uncaughtException', (error) => {
    log.exception('Uncaught exception in worker', error);
    process.exit(1);
});

//
// Handle unhandled promise rejections in the worker process
//
process.on('unhandledRejection', (reason) => {
    const error = reason instanceof Error ? reason : new Error(String(reason));
    log.exception('Unhandled rejection in worker', error);
    process.exit(1);
});

