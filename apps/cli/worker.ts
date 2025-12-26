//
// Worker script for executing tasks
// This runs in a Bun worker context
// This is the entry point for all workers created by the CLI package
//

import { initWorker, initWorkerContext, IWorkerInput, registerHandler } from "task-queue";
import { initTaskHandlers } from "api";
import { testSleepHandler } from "./src/lib/test-debug.worker";
import { log } from "utils";

//
// Register all task handlers
//
initTaskHandlers();

//
// Register CLI-specific task handlers
//
registerHandler("test-sleep", testSleepHandler);

//
// Read worker options from environment variable
//
const workerOptionsJson = process.env.WORKER_OPTIONS;
if (!workerOptionsJson) {
    console.error("WORKER_OPTIONS environment variable is not set");
    process.exit(1);
}

let workerOptions: IWorkerInput;
try {
    workerOptions = JSON.parse(workerOptionsJson);
} 
catch (error: any) {
    console.error(`Failed to parse WORKER_OPTIONS:`);
    console.error(error.stack || error.message || error);
    process.exit(1);
}

const workerId = workerOptions.workerId;

process.on('uncaughtException', (error: any) => {
    log.exception(`Uncaught exception in worker ${workerId}`, error);
    process.exit(1);
});

process.on('unhandledRejection', (reason: any) => {
    log.exception(`Unhandled promise rejection in worker ${workerId}`, reason);
    process.exit(1);
});

//
// Initialize worker context and message listener
//
try {
    const context = initWorkerContext(workerOptions);
    initWorker(context);
} 
catch (error: any) {
    console.error(`Failed to initialize worker ${workerId}:`);
    console.error(error.stack || error.message || error);
    process.exit(1);
}
