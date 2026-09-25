const task_queue_zig = @import("task-queue-zig");
const verify_worker = @import("verify.worker.zig");
const replicate_database_worker = @import("replicate-database.worker.zig");
const registerHandler = task_queue_zig.worker.registerHandler;
const verifyFileHandler = verify_worker.verifyFileHandler;
const replicateDatabaseHandler = replicate_database_worker.replicateDatabaseHandler;

//
// Register all task handlers
// This has to be called from the worker thread.
// (Zig: worker threads share the process-wide handler registry, so this is called once at startup.)
//
pub fn initTaskHandlers() !void {
    try registerHandler("verify-file", verifyFileHandler);
    // Not ported: check-file, load-assets, prefetch-database, upload-asset, sync-database (not used by psi replicate or psi verify).
    try registerHandler("replicate-database", replicateDatabaseHandler);
    // Not ported: save-asset, save-assets-batch, create-database, import-assets, hash-file, get-database-summary,
    // move-assets (not used by psi replicate or psi verify).
}
