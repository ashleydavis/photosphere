import { registerHandler } from "task-queue";
import { verifyFileHandler } from "./verify.worker";
import { checkFileHandler } from "./check.worker";
import { loadAssetsHandler } from "./load-assets.worker";
import { uploadAssetHandler } from "./upload-asset.worker";
import { prefetchDatabaseHandler } from "./prefetch-database.worker";
import { syncDatabaseHandler } from "./sync-database.worker";
import { saveAssetHandler } from "./save-asset.worker";
import { saveAssetsBatchHandler } from "./save-assets-batch.worker";
import { createDatabaseHandler } from "./create-database.worker";
import { importAssetsHandler } from "./import-assets.worker";
import { hashFileHandler } from "./hash-file.worker";

//
// Register all task handlers
// This has to be called from the worker thread.
//
export function initTaskHandlers(): void {
    registerHandler("verify-file", verifyFileHandler);
    registerHandler("check-file", checkFileHandler);
    registerHandler("load-assets", loadAssetsHandler);
    registerHandler("prefetch-database", prefetchDatabaseHandler);
    registerHandler("upload-asset", uploadAssetHandler);
    registerHandler("sync-database", syncDatabaseHandler);
    registerHandler("save-asset", saveAssetHandler);
    registerHandler("save-assets-batch", saveAssetsBatchHandler);
    registerHandler("create-database", createDatabaseHandler);
    registerHandler("import-assets", importAssetsHandler);
    registerHandler("hash-file", hashFileHandler);
}
