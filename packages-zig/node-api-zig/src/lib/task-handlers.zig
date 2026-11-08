const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const ziggy = @import("ziggy");
const task_queue_zig = ziggy.task_queue;
const verify_worker = @import("verify.worker.zig");
const check_worker = @import("check.worker.zig");
const upload_asset_worker = @import("upload-asset.worker.zig");
const replicate_database_worker = @import("replicate-database.worker.zig");
const import_assets_worker = @import("import-assets.worker.zig");
const hash_file_worker = @import("hash-file.worker.zig");
const cleanup_sources_worker = @import("cleanup-sources.worker.zig");
const database_base_dir = @import("database-base-dir.zig");
const prefetch_database_worker = @import("prefetch-database.worker.zig");
const consolidate_database_worker = @import("consolidate-database.worker.zig");
const check_database_exists_worker = @import("check-database-exists.worker.zig");
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
const IHandlerEntry = task_queue_zig.worker.IHandlerEntry;
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
// Every task handler, by task type. A worker is given the list when it starts and finds the handler for each task it runs in it.
//
pub const handlers = [_]IHandlerEntry{
    // Does nothing but take a while, so the job manager can be driven from the developer section of the sidebar without staging a
    // database first.
    .{ .type = "test-job", .handler = testJobHandler },
    .{ .type = "verify-file", .handler = verifyFileHandler },
    .{ .type = "load-assets", .handler = loadAssetsHandler },
    .{ .type = "prefetch-database", .handler = prefetchDatabaseHandler },
    .{ .type = "sync-database", .handler = syncDatabaseHandler },
    .{ .type = "replicate-database", .handler = replicateDatabaseHandler },
    .{ .type = "save-asset", .handler = saveAssetHandler },
    .{ .type = "save-assets-batch", .handler = saveAssetsBatchHandler },
    .{ .type = "create-database", .handler = createDatabaseHandler },
    .{ .type = "create-default-database", .handler = createDefaultDatabaseHandler },
    .{ .type = "import-assets", .handler = importAssetsHandler },
    .{ .type = "get-database-summary", .handler = getDatabaseSummaryHandler },
    .{ .type = "get-import-record", .handler = getImportRecordHandler },
    .{ .type = "set-database-origin", .handler = setDatabaseOriginHandler },
    .{ .type = "move-assets", .handler = moveAssetsHandler },
    .{ .type = "receive-share", .handler = receiveShareHandler },
    .{ .type = "find-receiver", .handler = findReceiverHandler },
    .{ .type = "send-payload", .handler = sendPayloadHandler },
    .{ .type = "check-database-exists", .handler = checkDatabaseExistsHandler },
    .{ .type = "evict-originals", .handler = evictOriginalsHandler },
    .{ .type = "cleanup-sources", .handler = cleanupSourcesHandler },
    .{ .type = "consolidate-database", .handler = consolidateDatabaseHandler },
    .{ .type = "reset-app-storage", .handler = resetAppStorageHandler },
    .{ .type = "check-file", .handler = checkFileHandler },
    .{ .type = "upload-asset", .handler = uploadAssetHandler },
    .{ .type = "hash-file", .handler = hashFileHandler },
};

//
// Every handler in the form Ziggy's workers take them, for a program that runs the tasks. Each runs on its task's thread, where it first
// calls registerMediaSources with the task's context, so the media source builders the platform serves are registered on that thread.
// A handler that runs ImageMagick or FFmpeg calls the tools built into the program directly; the program starts them (see MediaTools)
// before any task runs.
//
pub fn taskEntries(comptime registerMediaSources: fn (context: task_queue_zig.types.ITaskContext) anyerror!void) [handlers.len]ziggy.task_runner.TaskHandlerEntry {
    var list: [handlers.len]ziggy.task_runner.TaskHandlerEntry = undefined;
    for (handlers, 0..) |entry, index| {
        list[index] = .{
            .name = entry.type,
            .handler = fromNodeApiHandler(withMediaSources(registerMediaSources, entry.handler)),
        };
    }
    return list;
}

//
// Turns a task queue handler into a task handler, as Ziggy's fromQueueHandler does, and also hands it the app's data directory, which
// Ziggy's TaskContext carries and its ITaskContext does not. runQueueHandler gives the handler only the context and the data, so the
// data directory goes in the data, under database_base_dir.TASK_DATA_DIR_KEY, where database_base_dir.taskDatabaseBaseDir reads it.
//
pub fn fromNodeApiHandler(comptime handler: task_queue_zig.types.TaskHandler) ziggy.task_runner.TaskHandler {
    return &struct {
        fn run(services: ziggy.task_runner.TaskServices, timers: ziggy.timers.Timers, io: std.Io, allocator: std.mem.Allocator, context: ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
            const with_data_dir = try database_base_dir.withTaskDataDir(allocator, data, context.data_dir);
            return try ziggy.task_runner.runQueueHandler(services, timers, io, allocator, context, handler, with_data_dir);
        }
    }.run;
}

//
// A handler that registers the media source builders on its thread, then runs the handler given.
//
fn withMediaSources(comptime registerMediaSources: fn (context: task_queue_zig.types.ITaskContext) anyerror!void, comptime handler: task_queue_zig.types.TaskHandler) task_queue_zig.types.TaskHandler {
    return &struct {
        fn run(allocator: std.mem.Allocator, io: std.Io, timers: ziggy.timers.Timers, log: ILog, data: std.json.Value, context: task_queue_zig.types.ITaskContext) anyerror!std.json.Value {
            try registerMediaSources(context);
            return try handler(allocator, io, timers, log, data, context);
        }
    }.run;
}

//
// Registers the folder media source builder on the calling thread.
//
pub fn registerMediaSourceBuilders() !void {
    try create_auto_import_scanner.registerFolderMediaSourceBuilder();
    try cleanup_sources_worker.registerFolderMediaSourceBuilder();
}
