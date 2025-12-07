import { registerHandler } from "task-queue";
import { verifyFileHandler } from "./verify.worker";

//
// Register all task handlers
// This has to be called from the worker thread.
//
export function initTaskHandlers(): void {
    registerHandler("verify-file", verifyFileHandler);
}