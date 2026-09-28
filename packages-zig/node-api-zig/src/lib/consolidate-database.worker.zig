const std = @import("std");
const utils = @import("utils-zig");
const task_queue_zig = @import("task-queue-zig");
const media_file_database = @import("media-file-database.zig");
const open_storage = @import("open-storage.zig");
const tree = @import("tree.zig");
const consolidate = @import("consolidate.zig");
const prefetch_database_worker = @import("prefetch-database.worker.zig");
const errors = utils.errors;
const log = &utils.log.log;
const ITaskContext = task_queue_zig.types.ITaskContext;
const createMediaFileDatabase = media_file_database.createMediaFileDatabase;
const openStorage = open_storage.openStorage;
const merkleTreeExists = tree.merkleTreeExists;
const consolidateDatabases = consolidate.consolidateDatabases;
const IConsolidationResult = consolidate.IConsolidationResult;
const IConsolidationProgressCallback = consolidate.IConsolidationProgressCallback;
const prefetchDatabaseHandler = prefetch_database_worker.prefetchDatabaseHandler;

//
// Payload for the consolidate-database task.
// (The `= ""` defaults let std.json parse data that leaves keys out, which the checks below then refuse.)
//
pub const IConsolidateDatabaseData = struct {
    // Path of the standalone local database to join to the remote.
    databasePath: []const u8 = "",

    // Path or URI of the remote database to join it to.
    remotePath: []const u8 = "",

    // Identifies the session, used to take the write locks on both databases.
    sessionId: []const u8 = "",
};

//
// Streamed as consolidation pushes assets, so the user interface can show progress on what may be a
// long upload.
//
pub const IConsolidateProgressMessage = struct {
    // Discriminator matched by onTaskMessage("consolidate-progress").
    type: []const u8 = "consolidate-progress",

    // How many assets have been pushed to the remote so far.
    pushed: u64,

    // How many assets are being pushed in total.
    total: u64,
};

//
// Sends a consolidate-progress task message (TypeScript: the `(pushed, total) => { ... }` arrow function in
// consolidateDatabaseHandler, which captures context).
//
const ProgressMessageSender = struct {
    // The task context used to send the message.
    context: ITaskContext,

    //
    // Sends one progress message.
    //
    fn send(callbackContext: ?*anyopaque, pushed: u64, total: u64) void {
        const self: *ProgressMessageSender = @ptrCast(@alignCast(callbackContext.?));
        var buffer: [1024]u8 = undefined;
        var bufferAllocator = std.heap.FixedBufferAllocator.init(&buffer);
        const allocator = bufferAllocator.allocator();
        const message: IConsolidateProgressMessage = .{
            .pushed = pushed,
            .total = total,
        };
        const text = std.json.Stringify.valueAlloc(allocator, message, .{}) catch {
            return;
        };
        const value = std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{}) catch {
            return;
        };
        self.context.sendMessage(value);
    }
};

//
// Converts a JSON-serializable value to the JSON value a task handler returns or passes on.
// (No TypeScript counterpart: TypeScript passes the objects themselves.)
//
fn toJson(allocator: std.mem.Allocator, value: anytype) !std.json.Value {
    const text = try std.json.Stringify.valueAlloc(allocator, value, .{ .emit_null_optional_fields = false });
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

//
// Joins a standalone local database to a remote that already has content in it.
// (Zig: the task data and output are JSON values holding IConsolidateDatabaseData and IConsolidationResult.)
//
pub fn consolidateDatabaseHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    const data = try std.json.parseFromValueLeaky(IConsolidateDatabaseData, allocator, taskData, .{ .ignore_unknown_fields = true });
    if (data.databasePath.len == 0) {
        return errors.throwError("databasePath is required", .{});
    }
    if (data.remotePath.len == 0) {
        return errors.throwError("remotePath is required", .{});
    }

    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;

    const local = try openStorage(allocator, io, data.databasePath, null, null);
    const remote = try openStorage(allocator, io, data.remotePath, null, null);

    if (!try merkleTreeExists(allocator, io, remote.storage)) {
        return errors.throwError("There is no database at \"{s}\" to consolidate into.", .{data.remotePath});
    }

    const localDatabase = try createMediaFileDatabase(allocator, local.storage, uuidGenerator, timestampProvider);
    const remoteDatabase = try createMediaFileDatabase(allocator, remote.storage, uuidGenerator, timestampProvider);

    log.info(try std.fmt.allocPrint(allocator, "Consolidating \"{s}\" into \"{s}\".", .{ data.databasePath, data.remotePath }));

    var progressMessageSender: ProgressMessageSender = .{
        .context = context,
    };
    const result = try consolidateDatabases(
        allocator,
        io,
        data.databasePath,
        local.storage,
        local.rawStorage,
        localDatabase.bsonDatabase,
        data.remotePath,
        remote.storage,
        remote.rawStorage,
        remoteDatabase.bsonDatabase,
        data.sessionId,
        uuidGenerator,
        timestampProvider,
        IConsolidationProgressCallback{
            .context = &progressMessageSender,
            .function = ProgressMessageSender.send,
        },
    );

    // The local database is now a partial replica whose records and thumbnails live on the remote.
    // Pulling them down is what makes it usable: without it the gallery is empty until something
    // happens to read each file, and a machine that goes offline straight after connecting would
    // show nothing at all. This is the same prefetch a partial replica gets after replication.
    _ = try prefetchDatabaseHandler(allocator, io, try toJson(allocator, prefetch_database_worker.IPrefetchDatabaseData{
        .databasePath = data.databasePath,
    }), context);

    log.info(try std.fmt.allocPrint(allocator, "Consolidated \"{s}\" into \"{s}\": {d} pushed, {d} already there.", .{ data.databasePath, data.remotePath, result.pushedCount, result.alreadyPresentCount }));

    return toJson(allocator, result);
}
