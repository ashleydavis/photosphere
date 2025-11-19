//
// Worker script for executing tasks
// This runs in a Bun worker context
// This is the entry point for all workers created by the CLI package
//

import { registerHandler, initWorker, getRegisteredHandlerTypes } from "task-queue";
import { verifyFileHandler } from "./src/lib/verify.worker";

//
// Register all task handlers
//
registerHandler("verify-file", verifyFileHandler);

// Print list of registered handlers
const registeredHandlers = getRegisteredHandlerTypes();

//
// Initialize the worker message listener
// This sets up the worker to receive and execute tasks from the main thread
//
initWorker();
