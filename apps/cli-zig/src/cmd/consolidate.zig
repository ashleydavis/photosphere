const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const task_queue_zig = @import("task-queue-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const pc = @import("../lib/picocolors.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const storage_helper = @import("../lib/storage-helper.zig");
const sync_cmd = @import("sync.zig");
const log = &utils.log.log;
const exit = node_utils.termination.exit;
const TaskQueue = task_queue_zig.task_queue.TaskQueue;
const TaskStatus = task_queue_zig.types.TaskStatus;
const loadDatabaseConfig = api.database_config.loadDatabaseConfig;
const updateDatabaseConfig = api.database_config.updateDatabaseConfig;
const merkleTreeExists = node_api.tree.merkleTreeExists;
const loadMerkleTree = node_api.tree.loadMerkleTree;
const replicateDatabase = node_api.replicate_database.replicateDatabase;
const ReplicateProgressCallback = node_api.replicate_database.ReplicateProgressCallback;
const IConsolidationResult = node_api.consolidate.IConsolidationResult;
const IConsolidateDatabaseData = node_api.consolidate_database_worker.IConsolidateDatabaseData;
const loadDatabase = init_cmd.loadDatabase;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const configureS3IfNeeded = init_cmd.configureS3IfNeeded;
const createStorageForPath = storage_helper.createStorageForPath;
const configOrigin = sync_cmd.configOrigin;

//
// Options for the connect command (TypeScript: IConsolidateCommandOptions extends IBaseCommandOptions).
// The base options are in `base`.
//
pub const IConsolidateCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},

    //
    // Path to the encryption key for the remote database.
    //
    destKey: ?[]const u8 = null,
};

//
// Logs a replication progress message (TypeScript: the `progress => { log.verbose(progress); }` arrow function).
//
fn onReplicateProgress(context: ?*anyopaque, progress: []const u8) void {
    _ = context;
    log.verbose(progress);
}

//
// Converts the consolidate-database task data to the JSON value that is queued.
// (No TypeScript counterpart: TypeScript queues the object itself.)
//
fn consolidateDatabaseDataToJson(allocator: std.mem.Allocator, data: IConsolidateDatabaseData) !std.json.Value {
    const text = try std.json.Stringify.valueAlloc(allocator, data, .{});
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

//
// Connects a local database to a remote one, whatever is already there.
//
// There are three cases and the command picks between them by looking, rather than making the user
// say which one they are in:
//
//   * Nothing at the remote path: the remote is created as a copy of the local database.
//   * A database that is not related to the local one: the two are consolidated, which pushes the
//     local content the remote does not have and makes the local database a partial replica of it.
//   * A database that is already related: the origin is simply recorded, because ordinary sync
//     already covers them.
//
pub fn consolidateCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, remotePath: []const u8, options: *IConsolidateCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;

    const nonInteractive = options.base.yes orelse false;

    const loaded = try loadDatabase(allocator, io, options.base.db, &options.base, uuidGenerator, timestampProvider, sessionId, false);
    const databaseDir = loaded.databaseDir;
    const localStorage = loaded.assetStorage;
    const localRawStorage = loaded.rawAssetStorage;

    if (std.mem.startsWith(u8, remotePath, "s3:")) {
        _ = try configureS3IfNeeded(allocator, io, nonInteractive);
    }

    const remoteStorage = (try createStorageForPath(allocator, io, remotePath, null)).storage;
    const remoteExists = try merkleTreeExists(allocator, io, remoteStorage);

    log.info(try pc.bold(allocator, "Connecting to a remote database."));
    log.info(try std.fmt.allocPrint(allocator, "  Database:  {s}", .{try pc.cyan(allocator, databaseDir)}));
    log.info(try std.fmt.allocPrint(allocator, "  Remote:    {s}", .{try pc.cyan(allocator, remotePath)}));
    log.info("");

    if (!remoteExists) {
        // Nothing there yet, so the remote becomes a copy of what is here. Replication carries the
        // database id across, which is what makes the two related and lets sync run afterwards.
        log.info("There is no database at the remote path, so it is being created as a copy of this one.");

        const progressCallback: ReplicateProgressCallback = .{
            .context = null,
            .function = onReplicateProgress,
        };
        _ = try replicateDatabase(allocator, io, uuidGenerator, .{
            .sourcePath = databaseDir,
            .destPath = remotePath,
            .sourceEncryptionKey = options.base.key,
            .destEncryptionKey = options.destKey,
            .destS3Key = null,
            .partial = false,
            .force = false,
            .pathFilter = null,
        }, &progressCallback);
        try updateDatabaseConfig(allocator, io, localRawStorage, .{
            .origin = remotePath,
        });

        log.info(try pc.green(allocator, "\u{2713} Created the remote database and set it as this database's origin."));
        exit(io, 0);
        return;
    }

    const localTree = try loadMerkleTree(allocator, io, localStorage);
    const remoteTree = try loadMerkleTree(allocator, io, remoteStorage);
    if (localTree == null or remoteTree == null) {
        log.@"error"(try pc.red(allocator, "\u{2717} Could not read the merkle tree of one of the databases."));
        exit(io, 1);
        return;
    }

    if (std.mem.eql(u8, localTree.?.id, remoteTree.?.id)) {
        // Already the same database, so nothing has to move: recording the origin is the whole job.
        const existingConfig = try loadDatabaseConfig(allocator, io, localRawStorage);
        const existingOrigin = configOrigin(existingConfig);
        if (existingOrigin != null and std.mem.eql(u8, existingOrigin.?, remotePath)) {
            log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "\u{2713} Already joined to {s}.", .{remotePath})));
        }
        else {
            try updateDatabaseConfig(allocator, io, localRawStorage, .{
                .origin = remotePath,
            });
            log.info(try pc.green(allocator, "\u{2713} The remote is the same database, so it has been set as this database's origin."));
        }
        exit(io, 0);
        return;
    }

    log.info("The remote holds a different database, so the two are being consolidated.");
    log.info("Content the remote already has is not pushed a second time.");
    log.info("");

    // (Zig: the block's defers are the TypeScript finally, which shuts the queue down before the exit below.)
    {
        const queue = try TaskQueue.init(allocator, io, uuidGenerator, try std.fmt.allocPrint(allocator, "consolidate-{s}", .{sessionId}));
        defer queue.deinit();
        defer queue.shutdown();

        const taskId = try queue.addTask("consolidate-database", try consolidateDatabaseDataToJson(allocator, .{
            .databasePath = databaseDir,
            .remotePath = remotePath,
            .sessionId = sessionId,
        }), null, null);
        const taskResult = try queue.awaitTask(taskId);

        if (taskResult == null or taskResult.?.status != TaskStatus.Succeeded) {
            const errorMessage = if (taskResult) |failedResult| failedResult.errorMessage orelse "the task did not finish" else "the task did not finish";
            log.@"error"(try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} Consolidation failed: {s}", .{errorMessage})));
            exit(io, 1);
            return;
        }

        const result = try std.json.parseFromValueLeaky(IConsolidationResult, allocator, taskResult.?.outputs orelse .null, .{ .ignore_unknown_fields = true });
        log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "\u{2713} Connected to {s}.", .{remotePath})));
        log.info(try std.fmt.allocPrint(allocator, "Assets pushed to the remote:      {d}", .{result.pushedCount}));
        log.info(try std.fmt.allocPrint(allocator, "Assets the remote already had:    {d}", .{result.alreadyPresentCount}));
        log.info("");
        log.info(try pc.bold(allocator, "Next steps:"));
        log.info("    # Bring down everything the remote has that this database does not");
        log.info(try std.fmt.allocPrint(allocator, "    psi sync --db {s}", .{databaseDir}));
    }

    exit(io, 0);
}
