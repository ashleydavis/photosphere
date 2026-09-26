const std = @import("std");
const task_queue_zig = @import("task-queue-zig");
const node_api = @import("node-api-zig");

test "initTaskHandlers registers the verify-file and replicate-database handlers" {
    try node_api.task_handlers.initTaskHandlers();
    try std.testing.expect(task_queue_zig.worker.getHandler("verify-file") == node_api.verify_worker.verifyFileHandler);
    try std.testing.expect(task_queue_zig.worker.getHandler("replicate-database") == node_api.replicate_database_worker.replicateDatabaseHandler);
}
