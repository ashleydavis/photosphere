//
// Worker script for executing tasks
// This runs in a Bun worker context
// This is the entry point for all workers created by the CLI package
//

import { initWorker, initWorkerContext, type IWorkerOptions } from "task-queue";
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
