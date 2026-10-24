const std = @import("std");
const task_queue_zig = @import("ziggy").task_queue;
const node_api = @import("node-api-zig");

test "the handler list has the verify-file and replicate-database handlers" {
    try std.testing.expect(task_queue_zig.worker.getHandler(&node_api.task_handlers.handlers, "verify-file") == node_api.verify_worker.verifyFileHandler);
    try std.testing.expect(task_queue_zig.worker.getHandler(&node_api.task_handlers.handlers, "replicate-database") == node_api.replicate_database_worker.replicateDatabaseHandler);
}

test "the handler list has the handlers psi add runs" {
    try std.testing.expect(task_queue_zig.worker.getHandler(&node_api.task_handlers.handlers, "import-assets") == node_api.import_assets_worker.importAssetsHandler);
    try std.testing.expect(node_api.task_handlers.getToolHandler("hash-file") == node_api.hash_file_worker.hashFileHandler);
    try std.testing.expect(node_api.task_handlers.getToolHandler("upload-asset") == node_api.upload_asset_worker.uploadAssetHandler);
    try std.testing.expect(task_queue_zig.worker.getHandler(&node_api.task_handlers.handlers, "cleanup-sources") == node_api.cleanup_sources_worker.cleanupSourcesHandler);
}

test "the handler list has the handlers psi consolidate runs" {
    try std.testing.expect(task_queue_zig.worker.getHandler(&node_api.task_handlers.handlers, "consolidate-database") == node_api.consolidate_database_worker.consolidateDatabaseHandler);
    try std.testing.expect(task_queue_zig.worker.getHandler(&node_api.task_handlers.handlers, "prefetch-database") == node_api.prefetch_database_worker.prefetchDatabaseHandler);
}

test "the handler list has the handler psi check runs" {
    try std.testing.expect(node_api.task_handlers.getToolHandler("check-file") == node_api.check_worker.checkFileHandler);
}

test "the handler list has the check-database-exists handler" {
    try std.testing.expect(task_queue_zig.worker.getHandler(&node_api.task_handlers.handlers, "check-database-exists") == node_api.check_database_exists_worker.checkDatabaseExistsHandler);
}

test "registerMediaSourceBuilders registers the folder media source builder" {
    node_api.media_source_registry.clearMediaSourceBuilders();
    try node_api.task_handlers.registerMediaSourceBuilders();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var generator: @import("utils-zig").random_uuid_generator.RandomUuidGenerator = .{};

    const source = try node_api.media_source_registry.buildMediaSource(arena.allocator(), &.{.{
        .folder = .{
            .path = "/photos",
            .recurse = true,
        },
    }}, .{
        .sessionTempDir = "/tmp/session",
        .uuidGenerator = generator.uuidGenerator(),
        .nativeCaller = null,
    });

    const folderSource: *node_api.folder_media_source.FolderMediaSource = @ptrCast(@alignCast(source.ptr));
    try std.testing.expectEqualStrings("/photos", folderSource.folders[0].path);
}

test "the handler list has a handler for every task type of the application" {
    const taskTypes = [_][]const u8{
        "test-job",
        "verify-file",
        "check-file",
        "load-assets",
        "prefetch-database",
        "upload-asset",
        "sync-database",
        "replicate-database",
        "save-asset",
        "save-assets-batch",
        "create-database",
        "create-default-database",
        "import-assets",
        "hash-file",
        "get-database-summary",
        "get-import-record",
        "set-database-origin",
        "move-assets",
        "receive-share",
        "find-receiver",
        "send-payload",
        "check-database-exists",
        "evict-originals",
        "cleanup-sources",
        "consolidate-database",
        "reset-app-storage",
    };

    for (taskTypes) |taskType| {
        try std.testing.expect(task_queue_zig.worker.getHandler(&node_api.task_handlers.handlers, taskType) != null or node_api.task_handlers.getToolHandler(taskType) != null);
    }
    try std.testing.expect(task_queue_zig.worker.getHandler(&node_api.task_handlers.handlers, "test-job") == node_api.test_job_worker.testJobHandler);
    try std.testing.expect(task_queue_zig.worker.getHandler(&node_api.task_handlers.handlers, "receive-share") == node_api.lan_share_worker.receiveShareHandler);
    try std.testing.expect(task_queue_zig.worker.getHandler(&node_api.task_handlers.handlers, "find-receiver") == node_api.lan_share_worker.findReceiverHandler);
    try std.testing.expect(task_queue_zig.worker.getHandler(&node_api.task_handlers.handlers, "send-payload") == node_api.lan_share_worker.sendPayloadHandler);
    try std.testing.expect(task_queue_zig.worker.getHandler(&node_api.task_handlers.handlers, "reset-app-storage") == node_api.reset_app_storage_worker.resetAppStorageHandler);
}
