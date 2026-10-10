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
const check_database_exists_worker = @import("check-database-exists.worker.zig");
const asset_server_worker = @import("asset-server.worker.zig");
const test_job_worker = @import("test-job.worker.zig");
const load_assets_worker = @import("load-assets.worker.zig");
const sync_database_worker = @import("sync-database.worker.zig");
const save_asset_worker = @import("save-asset.worker.zig");
const save_assets_batch_worker = @import("save-assets-batch.worker.zig");
const create_database_worker = @import("create-database.worker.zig");
const create_default_database_worker = @import("create-default-database.worker.zig");
const get_database_summary_worker = @import("get-database-summary.worker.zig");
const get_import_record_worker = @import("get-import-record.worker.zig");
const set_database_origin_worker = @import("set-database-origin.worker.zig");
const move_assets_worker = @import("move-assets.worker.zig");
const lan_share_worker = @import("lan-share.worker.zig");
const evict_originals_worker = @import("evict-originals.worker.zig");
const reset_app_storage_worker = @import("reset-app-storage.worker.zig");
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
const checkDatabaseExistsHandler = check_database_exists_worker.checkDatabaseExistsHandler;
const assetServerHandler = asset_server_worker.assetServerHandler;
const testJobHandler = test_job_worker.testJobHandler;
const loadAssetsHandler = load_assets_worker.loadAssetsHandler;
const syncDatabaseHandler = sync_database_worker.syncDatabaseHandler;
const saveAssetHandler = save_asset_worker.saveAssetHandler;
const saveAssetsBatchHandler = save_assets_batch_worker.saveAssetsBatchHandler;
const createDatabaseHandler = create_database_worker.createDatabaseHandler;
const createDefaultDatabaseHandler = create_default_database_worker.createDefaultDatabaseHandler;
const getDatabaseSummaryHandler = get_database_summary_worker.getDatabaseSummaryHandler;
const getImportRecordHandler = get_import_record_worker.getImportRecordHandler;
const setDatabaseOriginHandler = set_database_origin_worker.setDatabaseOriginHandler;
const moveAssetsHandler = move_assets_worker.moveAssetsHandler;
const receiveShareHandler = lan_share_worker.receiveShareHandler;
const findReceiverHandler = lan_share_worker.findReceiverHandler;
const sendPayloadHandler = lan_share_worker.sendPayloadHandler;
const evictOriginalsHandler = evict_originals_worker.evictOriginalsHandler;
const resetAppStorageHandler = reset_app_storage_worker.resetAppStorageHandler;

//
// Register all task handlers
// This has to be called from the worker thread.
// (Zig: worker threads share the process-wide handler registry, so this is called once at startup. It also registers
// the folder media source builder.)
//
pub fn initTaskHandlers() !void {
    try create_auto_import_scanner.registerFolderMediaSourceBuilder();
    try cleanup_sources_worker.registerFolderMediaSourceBuilder();
    // Does nothing but take a while, so the job manager can be driven from the developer section of the sidebar without staging a
    // database first.
    try registerHandler("test-job", testJobHandler);
    try registerHandler("verify-file", verifyFileHandler);
    try registerHandler("check-file", checkFileHandler);
    try registerHandler("load-assets", loadAssetsHandler);
    try registerHandler("prefetch-database", prefetchDatabaseHandler);
    try registerHandler("upload-asset", uploadAssetHandler);
    try registerHandler("sync-database", syncDatabaseHandler);
    try registerHandler("replicate-database", replicateDatabaseHandler);
    try registerHandler("save-asset", saveAssetHandler);
    try registerHandler("save-assets-batch", saveAssetsBatchHandler);
    try registerHandler("create-database", createDatabaseHandler);
    try registerHandler("create-default-database", createDefaultDatabaseHandler);
    try registerHandler("import-assets", importAssetsHandler);
    try registerHandler("hash-file", hashFileHandler);
    try registerHandler("get-database-summary", getDatabaseSummaryHandler);
    try registerHandler("get-import-record", getImportRecordHandler);
    try registerHandler("set-database-origin", setDatabaseOriginHandler);
    try registerHandler("move-assets", moveAssetsHandler);
    try registerHandler("asset-server", assetServerHandler);
    try registerHandler("receive-share", receiveShareHandler);
    try registerHandler("find-receiver", findReceiverHandler);
    try registerHandler("send-payload", sendPayloadHandler);
    try registerHandler("check-database-exists", checkDatabaseExistsHandler);
    try registerHandler("evict-originals", evictOriginalsHandler);
    try registerHandler("cleanup-sources", cleanupSourcesHandler);
    try registerHandler("consolidate-database", consolidateDatabaseHandler);
    try registerHandler("reset-app-storage", resetAppStorageHandler);
}
