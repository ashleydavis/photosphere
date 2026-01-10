import { registerHandler } from "task-queue";
import { verifyFileHandler } from "./verify.worker";
import { checkFileHandler } from "./check.worker";
import { loadAssetsHandler } from "./load-assets.worker";
import { importFileHandler } from "./import.worker";

//
// Register all task handlers
// This has to be called from the worker thread.
//
export function initTaskHandlers(): void {
    registerHandler("verify-file", verifyFileHandler);
    registerHandler("check-file", checkFileHandler);
    registerHandler("load-assets", loadAssetsHandler);
    registerHandler("import-file", importFileHandler);
}
