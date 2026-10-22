const std = @import("std");
const utils = @import("utils-zig");
const task_queue_zig = @import("ziggy").task_queue;
const api = @import("api-zig");
const media_file_database = @import("media-file-database.zig");
const open_storage = @import("open-storage.zig");
const tree = @import("tree.zig");
const sync = @import("sync.zig");
const bson_json = @import("bson-json.zig");
const errors = utils.errors;
const log = &utils.log.log;
const ITaskContext = task_queue_zig.types.ITaskContext;
const IJobTag = task_queue_zig.types.IJobTag;
const sendJobProgress = task_queue_zig.job_progress.sendJobProgress;
const createMediaFileDatabase = media_file_database.createMediaFileDatabase;
const openStorage = open_storage.openStorage;
const merkleTreeExists = tree.merkleTreeExists;
const loadDatabaseConfig = api.database_config.loadDatabaseConfig;
const syncDatabases = sync.syncDatabases;
const SyncChangeCallback = sync.SyncChangeCallback;
const ISyncDatabaseData = api.sync_database_types.ISyncDatabaseData;
const ISyncChange = api.sync_database_types.ISyncChange;
const ISyncBatchEvent = api.sync_database_types.ISyncBatchEvent;
const ISyncSkippedEvent = api.sync_database_types.ISyncSkippedEvent;
const ISyncCompletedEvent = api.sync_database_types.ISyncCompletedEvent;

//
// Number of changes to accumulate before flushing a sync-batch message.
//
const SYNC_BATCH_SIZE = 50;

//
// Gets `config?.origin` when it is a non-empty string (null otherwise).
//
fn configOrigin(config: ?std.json.Value) ?[]const u8 {
    const value = config orelse {
        return null;
    };
    const object = switch (value) {
        .object => |object| object,
        else => {
            return null;
        },
    };
    const origin = object.get("origin") orelse {
        return null;
    };
    return switch (origin) {
        .string => |text| if (text.len > 0) text else null,
        else => null,
    };
}

//
// Converts a task event to the JSON value that is sent.
//
fn messageToJson(allocator: std.mem.Allocator, message: anytype) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, try std.json.Stringify.valueAlloc(allocator, message, .{}), .{});
}

//
// Accumulates changes and flushes them as sync-batch task events in groups of SYNC_BATCH_SIZE.
//
const SyncBatcher = struct {
    // Allocates the batches and their messages.
    allocator: std.mem.Allocator,

    // The context the messages are sent with.
    context: ITaskContext,

    // The path of the local database (data.databasePath).
    databasePath: []const u8,

    // The job the task belongs to (data.job).
    job: ?IJobTag,

    // When the handler started (runStartedAt).
    runStartedAt: i64,

    // How many records have moved so far, so the job row says more than that a sync is running.
    changesSynced: u64 = 0,

    // Accumulates changes and flushes them as sync-batch task events in groups of SYNC_BATCH_SIZE.
    pendingBatch: std.ArrayList(ISyncChange) = .empty,

    //
    // Sends the pending changes as one sync-batch message.
    //
    fn flushBatch(self: *SyncBatcher) !void {
        if (self.pendingBatch.items.len == 0) {
            return;
        }

        var added: std.ArrayList(std.json.Value) = .empty;
        var updated: std.ArrayList(std.json.Value) = .empty;
        var deletedIds: std.ArrayList([]const u8) = .empty;

        for (self.pendingBatch.items) |change| {
            if (change.type == .added and change.asset != null) {
                try added.append(self.allocator, .{ .object = try bson_json.bsonDocumentToJsonObject(self.allocator, change.asset.?) });
            }
            else if (change.type == .updated and change.asset != null) {
                try updated.append(self.allocator, .{ .object = try bson_json.bsonDocumentToJsonObject(self.allocator, change.asset.?) });
            }
            else if (change.type == .deleted and change.assetId != null and change.assetId.?.len > 0) {
                try deletedIds.append(self.allocator, change.assetId.?);
            }
        }

        const batchMessage: ISyncBatchEvent = .{
            .type = "sync-batch",
            .databasePath = self.databasePath,
            .added = added.items,
            .updated = updated.items,
            .deletedIds = deletedIds.items,
        };
        self.context.sendEvent(try messageToJson(self.allocator, batchMessage));

        self.changesSynced += added.items.len + updated.items.len + deletedIds.items.len;
        try sendJobProgress(self.allocator, self.context, self.job, self.runStartedAt, try std.fmt.allocPrint(self.allocator, "{d} changes synced", .{self.changesSynced}));

        self.pendingBatch = .empty;
    }

    //
    // Adds a change to the pending batch, flushing the batch when it is full.
    //
    fn onLocalChange(callbackContext: ?*anyopaque, change: ISyncChange) anyerror!void {
        const self: *SyncBatcher = @ptrCast(@alignCast(callbackContext.?));
        try self.pendingBatch.append(self.allocator, change);
        if (self.pendingBatch.items.len >= SYNC_BATCH_SIZE) {
            try self.flushBatch();
        }
    }
};

//
// Syncs the local database with its origin and sends the events about it.
// (Zig has no try block that can be left with return and still reach a catch, so this is a function of its own.)
//
fn syncDatabase(
    allocator: std.mem.Allocator,
    io: std.Io,
    data: ISyncDatabaseData,
    context: ITaskContext,
    runStartedAt: i64,
) anyerror!void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;

    const local = try openStorage(allocator, io, data.databasePath, null, null, context.hostRequester);
    const localStorage = local.storage;
    const localRawStorage = local.rawStorage;

    const config = try loadDatabaseConfig(allocator, io, localRawStorage);
    const origin = configOrigin(config) orelse {
        const reason = "no origin configured";
        log.info(try std.fmt.allocPrint(allocator, "Sync skipped for \"{s}\": {s}", .{ data.databasePath, reason }));
        const skippedMessage: ISyncSkippedEvent = .{
            .type = "sync-skipped",
            .databasePath = data.databasePath,
            .reason = reason,
        };
        context.sendEvent(try messageToJson(allocator, skippedMessage));
        return;
    };

    // Open the origin storage up-front so credentials, encryption keys, etc. are resolved via
    // the standard openStorage path. The connectivity check then runs against that storage,
    // which avoids false-negative skips when the origin needs credentials the worker would not
    // otherwise have (e.g. S3 origins registered in databases.toml with an s3_key).
    const originOpened = try openStorage(allocator, io, origin, null, null, context.hostRequester);
    const originStorage = originOpened.storage;
    const originRawStorage = originOpened.rawStorage;

    const connected = try merkleTreeExists(allocator, io, originStorage);
    if (!connected) {
        const reason = try std.fmt.allocPrint(allocator, "origin not accessible ({s})", .{origin});
        log.info(try std.fmt.allocPrint(allocator, "Sync skipped for \"{s}\": {s}", .{ data.databasePath, reason }));
        const skippedMessage: ISyncSkippedEvent = .{
            .type = "sync-skipped",
            .databasePath = data.databasePath,
            .reason = reason,
        };
        context.sendEvent(try messageToJson(allocator, skippedMessage));
        return;
    }

    log.info(try std.fmt.allocPrint(allocator, "Sync started for \"{s}\" (origin: {s})", .{ data.databasePath, origin }));

    context.sendEvent(try messageToJson(allocator, .{
        .type = "sync-started",
        .databasePath = data.databasePath,
    }));

    // The job the interface lists. Sent here rather than at the top of the handler so a sync
    // that returns early, having found no origin or an unreachable one, never puts a row up for
    // work it did not do.
    try sendJobProgress(allocator, context, data.job, runStartedAt, null);

    const localDb = try createMediaFileDatabase(allocator, localStorage, uuidGenerator, timestampProvider);

    const originDb = try createMediaFileDatabase(allocator, originStorage, uuidGenerator, timestampProvider);

    var batcher: SyncBatcher = .{
        .allocator = allocator,
        .context = context,
        .databasePath = data.databasePath,
        .job = data.job,
        .runStartedAt = runStartedAt,
    };

    // source = local, target = origin.
    // syncDatabases pulls target → source then pushes source → target.
    // So local receives origin changes, then origin receives local changes.
    // syncDatabases records lastSyncedAt and the content hash in both state files when it runs.
    const result = try syncDatabases(
        allocator,
        io,
        localStorage,
        localRawStorage,
        localDb.bsonDatabase,
        originStorage,
        originRawStorage,
        originDb.bsonDatabase,
        sessionId,
        SyncChangeCallback{
            .context = &batcher,
            .function = SyncBatcher.onLocalChange,
        },
    );

    // Flush any remaining changes that didn't fill a full batch.
    try batcher.flushBatch();

    if (result.synced) {
        log.info(try std.fmt.allocPrint(allocator, "Sync completed for \"{s}\"", .{data.databasePath}));
    }
    else {
        log.info(try std.fmt.allocPrint(allocator, "Sync skipped for \"{s}\": databases already identical", .{data.databasePath}));
    }

    const completedMessage: ISyncCompletedEvent = .{
        .type = "sync-completed",
        .databasePath = data.databasePath,
        .synced = result.synced,
    };
    context.sendEvent(try messageToJson(allocator, completedMessage));
}

//
// Background task handler that syncs a local database with its configured origin.
// Returns early (synced: false) if there is no origin or the origin is unreachable.
// Sends sync-started / sync-completed messages so the main process can relay them to the frontend.
// Sends incremental sync-batch messages as records are synced so the UI can update live.
// (Zig: the task data is a JSON value holding ISyncDatabaseData, and the output is JSON null.
// The work is done by syncDatabase, which this function calls so that its errors reach the log
// before they are thrown on.)
//
pub fn syncDatabaseHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    const data = try std.json.parseFromValueLeaky(ISyncDatabaseData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    });
    const timestampProvider = context.timestampProvider;
    const runStartedAt = timestampProvider.now(io);

    if (data.databasePath.len == 0) {
        return errors.throwError("databasePath is required", .{});
    }

    syncDatabase(allocator, io, data, context, runStartedAt) catch |err| {
        log.exception(try std.fmt.allocPrint(allocator, "Sync failed for \"{s}\"", .{data.databasePath}), err);
        return err;
    };
    return .null;
}
