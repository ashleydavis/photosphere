const std = @import("std");
const utils = @import("utils-zig");
const task_queue_zig = @import("task-queue-zig");
const api = @import("api-zig");
const media_file_database = @import("media-file-database.zig");
const open_storage = @import("open-storage.zig");
const replicate_module = @import("replicate.zig");
const errors = utils.errors;
const log = &utils.log.log;
const ITaskContext = task_queue_zig.types.ITaskContext;
const IJobTag = task_queue_zig.types.IJobTag;
const sendJobProgress = task_queue_zig.job_progress.sendJobProgress;
const createMediaFileDatabase = media_file_database.createMediaFileDatabase;
const ProgressCallback = media_file_database.ProgressCallback;
const openStorage = open_storage.openStorage;
const replicate = replicate_module.replicate;
const IReplicationResult = replicate_module.IReplicationResult;
const IsCancelledCallback = replicate_module.IsCancelledCallback;
const IReplicateDatabaseData = api.replicate_database_types.IReplicateDatabaseData;

//
// Sends a replicate-progress task message (TypeScript: the progressCallback arrow function in
// replicateDatabaseHandler, which captures data and context).
//
const ProgressMessageSender = struct {
    // The task context used to send the message.
    context: ITaskContext,

    // The source database path put in each message.
    databasePath: []const u8,

    // The job the task belongs to (data.job).
    job: ?IJobTag,

    // When the handler started (runStartedAt).
    runStartedAt: i64,

    //
    // Sends one progress message.
    //
    fn send(callbackContext: ?*anyopaque, progress: ?[]const u8) void {
        const self: *ProgressMessageSender = @ptrCast(@alignCast(callbackContext.?));
        var buffer: [16 * 1024]u8 = undefined;
        var bufferAllocator = std.heap.FixedBufferAllocator.init(&buffer);
        const allocator = bufferAllocator.allocator();
        var message: std.json.ObjectMap = .empty;
        message.ensureTotalCapacity(allocator, 3) catch {
            return;
        };
        message.putAssumeCapacity("type", .{ .string = "replicate-progress" });
        message.putAssumeCapacity("databasePath", .{ .string = self.databasePath });
        message.putAssumeCapacity("progress", .{ .string = progress orelse "" });
        self.context.sendMessage(.{ .object = message });

        // The same line again, as the job the interface lists and can cancel, so a replication can
        // be watched after its dialog has been closed. Indeterminate: replicate() reports what it is
        // copying, not how much is left.
        sendJobProgress(allocator, self.context, self.job, self.runStartedAt, progress) catch {
            return;
        };
    }
};

//
// Answers whether the task has been cancelled (TypeScript: the `() => context.isCancelled()` arrow function).
//
fn isTaskCancelled(callbackContext: ?*anyopaque) bool {
    const context: *const ITaskContext = @ptrCast(@alignCast(callbackContext.?));
    return context.isCancelled();
}

//
// Converts the replication result to the JSON value returned as the task output.
// (No TypeScript counterpart: TypeScript returns the object itself.)
//
pub fn replicationResultToJson(allocator: std.mem.Allocator, result: IReplicationResult) !std.json.Value {
    const text = try std.json.Stringify.valueAlloc(allocator, result, .{});
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

//
// Background task handler that replicates a source database to a destination path.
// Wraps the pure replicate() function, opening source and destination storage via the unified
// openStorage helper. Forwards progress strings via replicate-progress task messages and returns
// the replication summary as task output.
// (Zig: the task data and output are JSON values holding IReplicateDatabaseData and IReplicationResult.)
//
pub fn replicateDatabaseHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    const data = try std.json.parseFromValueLeaky(IReplicateDatabaseData, allocator, taskData, .{ .ignore_unknown_fields = true });
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const runStartedAt = timestampProvider.now(io);

    if (data.sourcePath.len == 0) {
        return errors.throwError("sourcePath is required", .{});
    }

    if (data.destPath.len == 0) {
        return errors.throwError("destPath is required", .{});
    }

    //
    // Open source storage. When the source is registered in databases.json its credentials come
    // from there; otherwise data.sourceEncryptionKey (file path or vault name) supplies the key.
    //
    const source = try openStorage(allocator, io, data.sourcePath, data.sourceEncryptionKey, null);
    const sourceStorage = source.storage;
    const sourceDb = try createMediaFileDatabase(allocator, sourceStorage, uuidGenerator, timestampProvider);

    //
    // Open destination storage. The destination need not be registered in databases.json: the
    // caller passes destEncryptionKey (file path or vault name) and destS3Key (vault name) directly.
    //
    const dest = try openStorage(
        allocator,
        io,
        data.destPath,
        data.destEncryptionKey,
        data.destS3Key,
    );
    const destStorage = dest.storage;
    const destRawStorage = dest.rawStorage;
    const destPems = dest.encryptionKeyPems;

    log.info(try std.fmt.allocPrint(allocator, "Replication started from {s} to {s}", .{ data.sourcePath, data.destPath }));

    var progressMessageSender: ProgressMessageSender = .{ .context = context, .databasePath = data.sourcePath, .job = data.job, .runStartedAt = runStartedAt };
    const progressCallback: ProgressCallback = .{ .context = &progressMessageSender, .function = ProgressMessageSender.send };

    const result = try replicate(
        allocator,
        io,
        data.sourcePath,
        sourceStorage,
        sourceDb.bsonDatabase,
        uuidGenerator,
        timestampProvider,
        destStorage,
        destRawStorage,
        .{
            .force = data.force,
            .partial = data.partial,
            .pathFilter = data.pathFilter,
            .isCancelled = .{ .context = @constCast(&context), .function = isTaskCancelled },
        },
        progressCallback,
    );

    //
    // If the destination is encrypted, write the public key PEM so the database can be opened later.
    //
    if (destPems.len > 0) {
        try destRawStorage.write(allocator, io, ".db/encryption.pub", null, destPems[0].publicKeyPem);
    }

    log.info(try std.fmt.allocPrint(allocator, "Replication completed from {s} to {s}", .{ data.sourcePath, data.destPath }));

    return replicationResultToJson(allocator, result);
}
