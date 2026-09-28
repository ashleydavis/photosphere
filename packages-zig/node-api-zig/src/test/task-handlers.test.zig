const std = @import("std");
const task_queue_zig = @import("task-queue-zig");
const node_api = @import("node-api-zig");

test "initTaskHandlers registers the verify-file and replicate-database handlers" {
    try node_api.task_handlers.initTaskHandlers();
    try std.testing.expect(task_queue_zig.worker.getHandler("verify-file") == node_api.verify_worker.verifyFileHandler);
    try std.testing.expect(task_queue_zig.worker.getHandler("replicate-database") == node_api.replicate_database_worker.replicateDatabaseHandler);
}

test "initTaskHandlers registers the handlers psi add runs" {
    try node_api.task_handlers.initTaskHandlers();
    try std.testing.expect(task_queue_zig.worker.getHandler("import-assets") == node_api.import_assets_worker.importAssetsHandler);
    try std.testing.expect(task_queue_zig.worker.getHandler("hash-file") == node_api.hash_file_worker.hashFileHandler);
    try std.testing.expect(task_queue_zig.worker.getHandler("upload-asset") == node_api.upload_asset_worker.uploadAssetHandler);
    try std.testing.expect(task_queue_zig.worker.getHandler("cleanup-sources") == node_api.cleanup_sources_worker.cleanupSourcesHandler);
}

test "initTaskHandlers registers the handlers psi consolidate runs" {
    try node_api.task_handlers.initTaskHandlers();
    try std.testing.expect(task_queue_zig.worker.getHandler("consolidate-database") == node_api.consolidate_database_worker.consolidateDatabaseHandler);
    try std.testing.expect(task_queue_zig.worker.getHandler("prefetch-database") == node_api.prefetch_database_worker.prefetchDatabaseHandler);
}

test "initTaskHandlers registers the handler psi check runs" {
    try node_api.task_handlers.initTaskHandlers();
    try std.testing.expect(task_queue_zig.worker.getHandler("check-file") == node_api.check_worker.checkFileHandler);
}

test "initTaskHandlers registers the folder media source builder, as loading its modules does in TypeScript" {
    node_api.media_source_registry.clearMediaSourceBuilders();
    try node_api.task_handlers.initTaskHandlers();
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
    });

    const folderSource: *node_api.folder_media_source.FolderMediaSource = @ptrCast(@alignCast(source.ptr));
    try std.testing.expectEqualStrings("/photos", folderSource.folders[0].path);
}
