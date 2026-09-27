const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const api = @import("api-zig");
const task_queue_zig = @import("task-queue-zig");
const media_file_database = @import("media-file-database.zig");
const import_assets_worker = @import("import-assets.worker.zig");
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const registerTerminationCallback = node_utils.termination.registerTerminationCallback;
const IDatabaseDescriptor = api.database_descriptor.IDatabaseDescriptor;
const TaskQueue = task_queue_zig.task_queue.TaskQueue;
const ITaskMessageData = task_queue_zig.types.ITaskMessageData;
const IJobTag = task_queue_zig.types.IJobTag;
const IAddSummary = media_file_database.IAddSummary;
const IImportOptions = import_assets_worker.IImportOptions;

//
// Progress callback invoked after each file event during import, receiving the running summary.
// (Zig: a closure; `function` is called with `context`. The values are only valid during the call.)
//
pub const AddPathsProgressCallback = struct {
    // The state of the callback, passed to function.
    context: ?*anyopaque,

    // The callback function.
    function: *const fn (context: ?*anyopaque, currentlyScanning: ?[]const u8, summary: *const IAddSummary) void,
};

//
// What the callbacks addPaths registers share (TypeScript: the variables they close over).
//
const AddPathsState = struct {
    // Allocates the copy of the path being scanned.
    allocator: std.mem.Allocator,

    // The running summary.
    summary: IAddSummary,

    // What the import is scanning now.
    currentlyScanning: ?[]const u8,

    // Called after each file event.
    onProgress: ?AddPathsProgressCallback,

    // The queue the import runs on, shut down on Ctrl-C.
    queue: *TaskQueue,

    //
    // Counts one task message (TypeScript: the arrow function passed to queue.onAnyTaskMessage).
    //
    fn onAnyTaskMessage(context: ?*anyopaque, data: ITaskMessageData) anyerror!void {
        const self: *AddPathsState = @ptrCast(@alignCast(context.?));
        // (Zig: a message that is not an object has no type, as reading a property of a string or number gives
        // undefined in TypeScript.)
        const message: std.json.ObjectMap = if (data.message == .object) data.message.object else .empty;
        const messageTypeValue = message.get("type") orelse std.json.Value.null;
        const messageType: []const u8 = if (messageTypeValue == .string) messageTypeValue.string else "";

        if (std.mem.eql(u8, messageType, "import-success")) {
            self.summary.filesAdded += 1;
            self.summary.filesProcessed += 1;
        }
        else if (std.mem.eql(u8, messageType, "import-skipped")) {
            self.summary.filesAlreadyAdded += 1;
            self.summary.filesProcessed += 1;
        }
        else if (std.mem.eql(u8, messageType, "file-ignored")) {
            const count = message.get("count") orelse std.json.Value.null;
            self.summary.filesIgnored += switch (count) {
                .integer => |integer| @floatFromInt(integer),
                .float => |float| float,
                else => std.math.nan(f64),
            };
        }
        else if (std.mem.eql(u8, messageType, "import-failed")) {
            self.summary.filesFailed += 1;
            self.summary.filesProcessed += 1;
        }
        else if (std.mem.eql(u8, messageType, "scan-progress")) {
            const currentPath = message.get("currentPath") orelse std.json.Value.null;
            self.currentlyScanning = if (currentPath == .string) try self.allocator.dupe(u8, currentPath.string) else null;
        }
        else if (std.mem.eql(u8, messageType, "import-pending")) {
            // no-op: pending messages are informational only
            return;
        }

        if (self.onProgress) |onProgress| {
            onProgress.function(onProgress.context, self.currentlyScanning, &self.summary);
        }
    }

    //
    // Ctrl-C has to reach the task, not just this process (TypeScript: the arrow function passed to
    // registerTerminationCallback).
    //
    fn shutdownOnTermination(context: ?*anyopaque, io: std.Io, exitCode: u8) anyerror!void {
        _ = io;
        _ = exitCode;
        const self: *AddPathsState = @ptrCast(@alignCast(context.?));
        self.queue.shutdown();
    }
};

//
// Adds media to the database and waits for the import to finish.
//
// One import task does the work either way. Without `options.auto` it walks `paths` once and ends,
// which is `psi add`. With it, the same task is fed by a scanner that watches those places and
// imports what turns up, so it runs until it is cancelled: that is `psi add --watch`. Everything
// between the two is the same code, which is the point of it.
//
// Progress is reported via the optional onProgress callback.
// (Zig: the queue and the state the callbacks share are allocated with the allocator and are never freed, because
// the termination callback registered here can run at any time until the process exits, as in TypeScript.)
//
pub fn addPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    uuidGenerator: IUuidGenerator,
    storageDescriptor: IDatabaseDescriptor,
    paths: []const []const u8,
    googleApiKey: ?[]const u8,
    sessionId: []const u8,
    dryRun: bool,
    onProgress: ?AddPathsProgressCallback,
    options: ?IImportOptions,
) !IAddSummary {
    const queue = try TaskQueue.init(allocator, io, uuidGenerator, storageDescriptor.databasePath);

    const state = try allocator.create(AddPathsState);
    state.* = .{
        .allocator = allocator,
        .summary = .{
            .filesAdded = 0,
            .filesAlreadyAdded = 0,
            .filesIgnored = 0,
            .filesFailed = 0,
            .filesProcessed = 0,
            .totalSize = 0,
            .averageSize = 0,
        },
        .currentlyScanning = null,
        .onProgress = onProgress,
        .queue = queue,
    };

    _ = try queue.onAnyTaskMessage(.{
        .context = state,
        .function = AddPathsState.onAnyTaskMessage,
    });

    var taskData: std.json.ObjectMap = .empty;
    var pathValues: std.json.Array = .init(allocator);
    for (paths) |pathValue| {
        try pathValues.append(.{ .string = pathValue });
    }
    try taskData.put(allocator, "paths", .{ .array = pathValues });
    var descriptor: std.json.ObjectMap = .empty;
    try descriptor.put(allocator, "databasePath", .{ .string = storageDescriptor.databasePath });
    if (storageDescriptor.encryptionKey) |encryptionKey| {
        try descriptor.put(allocator, "encryptionKey", .{ .string = encryptionKey });
    }
    try taskData.put(allocator, "storageDescriptor", .{ .object = descriptor });
    if (googleApiKey) |key| {
        try taskData.put(allocator, "googleApiKey", .{ .string = key });
    }
    try taskData.put(allocator, "sessionId", .{ .string = sessionId });
    try taskData.put(allocator, "dryRun", .{ .bool = dryRun });
    if (options) |importOptions| {
        try taskData.put(allocator, "options", try importOptions.toJson(allocator));
    }
    // Tagged even though the CLI has no job list to show it in, so that the rule holds
    // everywhere: work a user would want to watch carries a job tag, and whatever is watching
    // decides what to do with it.
    var job: std.json.ObjectMap = .empty;
    try job.put(allocator, "id", .{ .string = sessionId });
    try job.put(allocator, "name", .{ .string = if (options != null and options.?.auto) "Automatic import" else "Importing photos" });
    try job.put(allocator, "cancelSource", .{ .string = storageDescriptor.databasePath });
    try taskData.put(allocator, "job", .{ .object = job });

    const taskId = try queue.addTask("import-assets", .{ .object = taskData }, null, null);

    // Ctrl-C has to reach the task, not just this process: the task is what holds the temporary
    // directory, and shutting the queue down is what tells it to stop. An automatic import only ends
    // this way; a one-shot import ends on its own and never needs it.
    try registerTerminationCallback(io, .{
        .context = state,
        .function = AddPathsState.shutdownOnTermination,
    });

    _ = try queue.awaitTask(taskId);

    queue.shutdown();

    state.summary.averageSize = if (state.summary.filesAdded > 0)
        @floor(state.summary.totalSize / state.summary.filesAdded)
    else
        0;

    return state.summary;
}
