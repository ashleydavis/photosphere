const task_queue_zig = @import("task-queue-zig");
const verify_worker = @import("verify.worker.zig");
const check_worker = @import("check.worker.zig");
const upload_asset_worker = @import("upload-asset.worker.zig");
const replicate_database_worker = @import("replicate-database.worker.zig");
const import_assets_worker = @import("import-assets.worker.zig");
const hash_file_worker = @import("hash-file.worker.zig");
const cleanup_sources_worker = @import("cleanup-sources.worker.zig");
const prefetch_database_worker = @import("prefetch-database.worker.zig");
const consolidate_database_worker = @import("consolidate-database.worker.zig");
const create_auto_import_scanner = @import("create-auto-import-scanner.zig");
const registerHandler = task_queue_zig.worker.registerHandler;
const verifyFileHandler = verify_worker.verifyFileHandler;
const checkFileHandler = check_worker.checkFileHandler;
const uploadAssetHandler = upload_asset_worker.uploadAssetHandler;
const replicateDatabaseHandler = replicate_database_worker.replicateDatabaseHandler;
const importAssetsHandler = import_assets_worker.importAssetsHandler;
const hashFileHandler = hash_file_worker.hashFileHandler;
const cleanupSourcesHandler = cleanup_sources_worker.cleanupSourcesHandler;
const prefetchDatabaseHandler = prefetch_database_worker.prefetchDatabaseHandler;
const consolidateDatabaseHandler = consolidate_database_worker.consolidateDatabaseHandler;

//
// Register all task handlers
// This has to be called from the worker thread.
// (Zig: worker threads share the process-wide handler registry, so this is called once at startup. It also makes
// the registrations the imported TypeScript modules make when they load: create-auto-import-scanner and
// cleanup-sources.worker each register the folder media source builder.)
//
pub fn initTaskHandlers() !void {
    try create_auto_import_scanner.registerFolderMediaSourceBuilder();
    try cleanup_sources_worker.registerFolderMediaSourceBuilder();
    // Not ported: test-job (not reached by the CLI).
    try registerHandler("verify-file", verifyFileHandler);
    try registerHandler("check-file", checkFileHandler);
    // Not ported: load-assets (not reached by the CLI).
    try registerHandler("prefetch-database", prefetchDatabaseHandler);
    try registerHandler("upload-asset", uploadAssetHandler);
    // Not ported: sync-database (not reached by the CLI).
    try registerHandler("replicate-database", replicateDatabaseHandler);
    // Not ported: save-asset, save-assets-batch, create-database, create-default-database (not used by psi add,
    // psi replicate or psi verify).
    try registerHandler("import-assets", importAssetsHandler);
    try registerHandler("hash-file", hashFileHandler);
    // Not ported: get-database-summary, get-import-record, set-database-origin, move-assets, asset-server,
    // receive-share, find-receiver, send-payload, check-database-exists, evict-originals (not used by psi add,
    // psi replicate or psi verify).
    try registerHandler("cleanup-sources", cleanupSourcesHandler);
    try registerHandler("consolidate-database", consolidateDatabaseHandler);
    // Not ported: reset-app-storage (not reached by the CLI).
}
