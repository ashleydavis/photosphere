const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const api = @import("api-zig");
const task_queue_zig = @import("task-queue-zig");
const serialization_zig = @import("serialization-zig");
const storage_zig = @import("storage-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const import_assets_worker = node_api.import_assets_worker;
const importAssetsHandler = import_assets_worker.importAssetsHandler;
const describeImportProgress = import_assets_worker.describeImportProgress;
const IImportAssetsData = import_assets_worker.IImportAssetsData;
const IHashFileData = node_api.hash_file_worker.IHashFileData;
const IUploadAssetData = node_api.upload_asset_worker.IUploadAssetData;
const encodeAssetRecord = node_api.upload_asset_worker.encodeAssetRecord;
const HashCache = node_api.hash_cache.HashCache;
const getHashCacheDir = node_api.hash_cache.getHashCacheDir;
const getImportRecordPath = node_api.database_cache_dir.getImportRecordPath;
const loadImportRecord = node_api.import_record_storage.loadImportRecord;
const registerFolderMediaSourceBuilder = node_api.create_auto_import_scanner.registerFolderMediaSourceBuilder;
const TaskContext = task_queue_zig.task_context.TaskContext;
const TaskStatus = task_queue_zig.types.TaskStatus;
const TaskPriority = task_queue_zig.types.TaskPriority;
const ITaskResult = task_queue_zig.types.ITaskResult;
const IQueueBackend = task_queue_zig.queue_backend.IQueueBackend;
const WorkerTaskCompletionCallback = task_queue_zig.types.WorkerTaskCompletionCallback;
const TaskMessageCallback = task_queue_zig.types.TaskMessageCallback;
const TaskAddedCallback = task_queue_zig.types.TaskAddedCallback;
const TasksCancelledCallback = task_queue_zig.types.TasksCancelledCallback;
const UnsubscribeFn = task_queue_zig.types.UnsubscribeFn;
const setQueueBackend = task_queue_zig.queue_backend.setQueueBackend;
const BsonDocument = serialization_zig.bson.BsonDocument;
const TestUuidGenerator = node_utils.test_uuid_generator.TestUuidGenerator;
const TestTimestampProvider = node_utils.test_timestamp_provider.TestTimestampProvider;
const path = node_utils.path;
const errors = utils.errors;

//
// (Zig: TypeScript mocks the file scanner, storage, the database, the hash cache, the tree, the merkle tree and the
// import record. The Zig port has no modules to mock, so these tests run the handler over real files, a real
// database and a real hash cache in the test's own directory, and check what it did to them. The queue backend is
// replaced by a MockBackend, as TypeScript does at the same seam.)
//

//
// Thread-safe allocator for the backend's state.
//
const backend_allocator = std.heap.smp_allocator;

//
// What a task added to the backend was.
//
const IAddedTask = struct {
    // The task type.
    type: []const u8,

    // The task data, as JSON text.
    data: []const u8,

    // The source tag.
    source: []const u8,

    // The task ID.
    taskId: []const u8,
};

//
// What a result factory says a task did.
//
const IMockResult = struct {
    // Whether the task succeeded.
    status: TaskStatus,

    // The outputs, as JSON text, or null.
    outputs: ?[]const u8 = null,

    // The error message of a failed task.
    errorMessage: ?[]const u8 = null,
};

//
// Makes the result of a task from its type and data. Null leaves the task running forever.
//
const ResultFactory = *const fn (backend: *MockBackend, allocator: std.mem.Allocator, taskType: []const u8, data: std.json.Value) anyerror!?IMockResult;

//
// Minimal mock IQueueBackend that records addTask calls, fires onTaskAdded callbacks,
// and completes tasks via a result factory.
//
// (Zig: a completion fires on the backend's own thread once no task has been added for `idleMs`, which is what
// TypeScript's completeAfterTimeout does: the import gets to queue what it wants before anything completes, so the
// concurrency tests measure the limit rather than a backend that completes everything at once.)
//
const MockBackend = struct {
    // Guards the backend's state.
    mutex: std.Io.Mutex = .init,

    // Wakes the completion thread.
    condition: std.Io.Condition = .init,

    // The tasks added so far.
    addedTasks: std.ArrayList(IAddedTask) = .empty,

    // The onTaskAdded registrations.
    taskAddedCallbacks: std.ArrayList(TaskAddedCallback) = .empty,

    // The onTaskComplete registrations (null once unsubscribed).
    completionCallbacks: std.ArrayList(?WorkerTaskCompletionCallback) = .empty,

    // Makes the result of each task.
    resultFactory: ResultFactory,

    // Test-specific state the factory reads.
    factoryState: ?*anyopaque = null,

    // Tasks added and not completed.
    inFlight: usize = 0,

    // The most tasks there have ever been in flight at once.
    peakTasksInFlight: usize = 0,

    // How often cancelTasks was called.
    cancelCount: usize = 0,

    // Completions waiting to fire, as JSON text of the ITaskResult.
    pendingCompletions: std.ArrayList([]const u8) = .empty,

    // When the last task was added.
    lastAddedAt: i64 = 0,

    // How long the backend waits after the last addTask before completing tasks.
    idleMs: i64 = 0,

    // Set when the completion thread has to exit.
    stopping: bool = false,

    // The completion thread.
    thread: ?std.Thread = null,

    //
    // Starts the completion thread.
    //
    fn start(self: *MockBackend) !void {
        self.thread = try std.Thread.spawn(.{}, completionThreadMain, .{self});
    }

    //
    // Stops the completion thread and frees the backend's state.
    //
    fn deinit(self: *MockBackend) void {
        const io = std.testing.io;
        self.mutex.lockUncancelable(io);
        self.stopping = true;
        self.condition.broadcast(io);
        self.mutex.unlock(io);
        if (self.thread) |thread| {
            thread.join();
        }
        for (self.addedTasks.items) |task| {
            backend_allocator.free(task.type);
            backend_allocator.free(task.data);
            backend_allocator.free(task.source);
            backend_allocator.free(task.taskId);
        }
        self.addedTasks.deinit(backend_allocator);
        self.taskAddedCallbacks.deinit(backend_allocator);
        self.completionCallbacks.deinit(backend_allocator);
        for (self.pendingCompletions.items) |completion| {
            backend_allocator.free(completion);
        }
        self.pendingCompletions.deinit(backend_allocator);
    }

    //
    // Fires the completions once the import has stopped adding tasks for a while.
    //
    fn completionThreadMain(self: *MockBackend) void {
        const io = std.testing.io;
        while (true) {
            self.mutex.lockUncancelable(io);
            while (!self.stopping and self.pendingCompletions.items.len == 0) {
                self.condition.waitUncancelable(io, &self.mutex);
            }
            if (self.stopping) {
                self.mutex.unlock(io);
                return;
            }
            const idleFor = std.Io.Clock.real.now(io).toMilliseconds() - self.lastAddedAt;
            if (idleFor < self.idleMs) {
                self.mutex.unlock(io);
                utils.sleep.sleep(io, @intCast(self.idleMs - idleFor)) catch {};
                continue;
            }
            const completion = self.pendingCompletions.orderedRemove(0);
            self.inFlight -= 1;
            const callbacks = backend_allocator.dupe(?WorkerTaskCompletionCallback, self.completionCallbacks.items) catch {
                self.mutex.unlock(io);
                return;
            };
            self.mutex.unlock(io);
            defer backend_allocator.free(callbacks);
            defer backend_allocator.free(completion);

            var arena = std.heap.ArenaAllocator.init(backend_allocator);
            defer arena.deinit();
            const result = std.json.parseFromSliceLeaky(ITaskResult, arena.allocator(), completion, .{}) catch {
                return;
            };
            for (callbacks) |registration| {
                if (registration) |callback| {
                    callback.call(result) catch {};
                }
            }
        }
    }

    //
    // Gets the IQueueBackend interface of this backend.
    //
    fn queueBackend(self: *MockBackend) IQueueBackend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // The IQueueBackend functions of this backend.
    //
    const vtable: IQueueBackend.VTable = .{
        .addTask = addTask,
        .onTaskAdded = onTaskAdded,
        .onTaskComplete = onTaskComplete,
        .onTaskMessage = onTaskMessage,
        .onAnyTaskMessage = onAnyTaskMessage,
        .cancelTasks = cancelTasks,
        .onTasksCancelled = onTasksCancelled,
        .shutdown = shutdown,
    };

    //
    // Records the task, tells the queue it was added, and schedules its completion.
    //
    fn addTask(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, taskType: []const u8, data: std.json.Value, source: []const u8, taskId: ?[]const u8, priority: ?TaskPriority) anyerror![]const u8 {
        _ = priority;
        const self: *MockBackend = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(io);
        const id = if (taskId) |given| try backend_allocator.dupe(u8, given) else try std.fmt.allocPrint(backend_allocator, "{s}-{d}", .{ taskType, self.addedTasks.items.len });
        const dataText = try std.json.Stringify.valueAlloc(backend_allocator, data, .{});
        try self.addedTasks.append(backend_allocator, .{
            .type = try backend_allocator.dupe(u8, taskType),
            .data = dataText,
            .source = try backend_allocator.dupe(u8, source),
            .taskId = id,
        });
        self.inFlight += 1;
        self.peakTasksInFlight = @max(self.peakTasksInFlight, self.inFlight);
        self.lastAddedAt = std.Io.Clock.real.now(io).toMilliseconds();
        const addedCallbacks = try backend_allocator.dupe(TaskAddedCallback, self.taskAddedCallbacks.items);
        defer backend_allocator.free(addedCallbacks);
        self.mutex.unlock(io);

        for (addedCallbacks) |callback| {
            callback.call(id);
        }

        var arena = std.heap.ArenaAllocator.init(backend_allocator);
        defer arena.deinit();
        const mockResult = try self.resultFactory(self, arena.allocator(), taskType, data) orelse {
            return allocator.dupe(u8, id);
        };
        const outputs: ?std.json.Value = if (mockResult.outputs) |text| try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), text, .{}) else null;
        const result: ITaskResult = .{
            .taskId = id,
            .status = mockResult.status,
            .errorMessage = mockResult.errorMessage,
            .outputs = outputs,
            .type = taskType,
            .inputs = data,
        };
        const resultText = try std.json.Stringify.valueAlloc(backend_allocator, result, .{ .emit_null_optional_fields = false });
        self.mutex.lockUncancelable(io);
        try self.pendingCompletions.append(backend_allocator, resultText);
        self.condition.broadcast(io);
        self.mutex.unlock(io);
        return allocator.dupe(u8, id);
    }

    //
    // Registers a callback for added tasks.
    //
    fn onTaskAdded(ptr: *anyopaque, source: []const u8, callback: TaskAddedCallback) anyerror!UnsubscribeFn {
        _ = source;
        const self: *MockBackend = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        try self.taskAddedCallbacks.append(backend_allocator, callback);
        return noUnsubscribe();
    }

    //
    // Registers a completion callback.
    //
    fn onTaskComplete(ptr: *anyopaque, callback: WorkerTaskCompletionCallback) anyerror!UnsubscribeFn {
        const self: *MockBackend = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        try self.completionCallbacks.append(backend_allocator, callback);
        return .{
            .context = self,
            .key = self.completionCallbacks.items.len - 1,
            .function = unsubscribeCompletion,
        };
    }

    //
    // Removes a completion callback.
    //
    fn unsubscribeCompletion(context: ?*anyopaque, key: usize) void {
        const self: *MockBackend = @ptrCast(@alignCast(context.?));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.completionCallbacks.items[key] = null;
    }

    //
    // Messages are not sent by the mock's tasks.
    //
    fn onTaskMessage(ptr: *anyopaque, messageType: []const u8, callback: TaskMessageCallback) anyerror!UnsubscribeFn {
        _ = ptr;
        _ = messageType;
        _ = callback;
        return noUnsubscribe();
    }

    //
    // Messages are not sent by the mock's tasks.
    //
    fn onAnyTaskMessage(ptr: *anyopaque, callback: TaskMessageCallback) anyerror!UnsubscribeFn {
        _ = ptr;
        _ = callback;
        return noUnsubscribe();
    }

    //
    // Counts the cancellation.
    //
    fn cancelTasks(ptr: *anyopaque, source: []const u8) void {
        _ = source;
        const self: *MockBackend = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.cancelCount += 1;
    }

    //
    // Cancellation callbacks are never fired by the mock.
    //
    fn onTasksCancelled(ptr: *anyopaque, source: []const u8, callback: TasksCancelledCallback) anyerror!UnsubscribeFn {
        _ = ptr;
        _ = source;
        _ = callback;
        return noUnsubscribe();
    }

    //
    // Nothing to shut down.
    //
    fn shutdown(ptr: *anyopaque) void {
        _ = ptr;
    }

    //
    // The tasks added of one type.
    //
    fn tasksOfType(self: *MockBackend, allocator: std.mem.Allocator, taskType: []const u8) ![]std.json.Value {
        var tasks: std.ArrayList(std.json.Value) = .empty;
        for (self.addedTasks.items) |task| {
            if (std.mem.eql(u8, task.type, taskType)) {
                try tasks.append(allocator, try std.json.parseFromSliceLeaky(std.json.Value, allocator, task.data, .{}));
            }
        }
        return tasks.items;
    }
};

//
// An unsubscribe function that does nothing.
//
fn noUnsubscribe() UnsubscribeFn {
    return .{
        .context = null,
        .key = 0,
        .function = ignoreUnsubscribe,
    };
}

//
// Does nothing.
//
fn ignoreUnsubscribe(context: ?*anyopaque, key: usize) void {
    _ = context;
    _ = key;
}

//
// A 32-byte hash, hex encoded, made of one repeated byte.
//
fn repeatedHash(comptime byteHex: []const u8) []const u8 {
    return byteHex ** 32;
}

//
// The hash every hash-file task reports unless a test says otherwise, and which the database holds by default,
// so a run with no upload results finishes.
//
const DEFAULT_HASH = repeatedHash("00");

//
// A different hash for the files a test wants to be new.
//
const NEW_HASH = repeatedHash("aa");

//
// Hash-file reports the default hash (TypeScript: the beforeEach result factory).
//
fn hashFileReportsDefault(backend: *MockBackend, allocator: std.mem.Allocator, taskType: []const u8, data: std.json.Value) anyerror!?IMockResult {
    _ = backend;
    _ = data;
    if (std.mem.eql(u8, taskType, "hash-file")) {
        return .{
            .status = .Succeeded,
            .outputs = try std.fmt.allocPrint(allocator, "{{\"hash\":\"{s}\",\"hashFromCache\":false,\"hashMs\":0,\"cacheLookupMs\":0,\"taskMs\":0,\"cacheLoadMs\":0,\"bytesHashed\":0}}", .{DEFAULT_HASH}),
        };
    }
    return null;
}

//
// The outputs of a hash-file task reporting a hash.
//
fn hashOutputs(allocator: std.mem.Allocator, hash: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"hash\":\"{s}\",\"hashFromCache\":false,\"hashMs\":0,\"cacheLookupMs\":0,\"taskMs\":0,\"cacheLoadMs\":0,\"bytesHashed\":0}}", .{hash});
}

//
// The outputs of an upload-asset task that succeeded for the asset id it was given.
//
fn uploadOutputs(allocator: std.mem.Allocator, data: std.json.Value) ![]const u8 {
    const assetId = data.object.get("assetId").?.string;
    const assetRecord = try BsonDocument.fromFields(allocator, &.{.{
        .key = "_id",
        .value = .{ .string = assetId },
    }});
    return std.fmt.allocPrint(allocator, "{{\"assetData\":{{\"assetId\":\"{s}\",\"assetPath\":\"asset/{s}\",\"assetHash\":\"{s}\",\"assetLength\":1000,\"assetLastModified\":1704067200000,\"assetRecord\":\"{s}\"}},\"totalSize\":1000,\"taskMs\":0,\"metadataMs\":0,\"microMs\":0,\"thumbnailMs\":0,\"displayMs\":0,\"uploadMs\":0,\"geocodeMs\":0,\"dominantColorMs\":0,\"otherMs\":0,\"openStorageMs\":0,\"probeMs\":0,\"isVideo\":false}}", .{ assetId, assetId, NEW_HASH, try encodeAssetRecord(allocator, assetRecord) });
}

//
// Hash-file reports a new file and upload-asset succeeds (TypeScript: hashFileReportsNewFile and uploadSucceeds).
//
fn newFileUploads(backend: *MockBackend, allocator: std.mem.Allocator, taskType: []const u8, data: std.json.Value) anyerror!?IMockResult {
    _ = backend;
    if (std.mem.eql(u8, taskType, "hash-file")) {
        return .{
            .status = .Succeeded,
            .outputs = try hashOutputs(allocator, NEW_HASH),
        };
    }
    if (std.mem.eql(u8, taskType, "upload-asset")) {
        return .{
            .status = .Succeeded,
            .outputs = try uploadOutputs(allocator, data),
        };
    }
    return null;
}

//
// Every file is new, each with its own hash, and every upload succeeds.
//
fn everyFileNew(backend: *MockBackend, allocator: std.mem.Allocator, taskType: []const u8, data: std.json.Value) anyerror!?IMockResult {
    _ = backend;
    if (std.mem.eql(u8, taskType, "hash-file")) {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data.object.get("logicalPath").?.string, &digest, .{});
        return .{
            .status = .Succeeded,
            .outputs = try hashOutputs(allocator, &std.fmt.bytesToHex(digest, .lower)),
        };
    }
    if (std.mem.eql(u8, taskType, "upload-asset")) {
        return .{
            .status = .Succeeded,
            .outputs = try uploadOutputs(allocator, data),
        };
    }
    return null;
}

//
// Every hash-file task reports the same new hash, and uploads fail (TypeScript: the duplicate-hash test's factories).
//
fn sameNewHashUploadFails(backend: *MockBackend, allocator: std.mem.Allocator, taskType: []const u8, data: std.json.Value) anyerror!?IMockResult {
    _ = backend;
    _ = data;
    if (std.mem.eql(u8, taskType, "hash-file")) {
        return .{
            .status = .Succeeded,
            .outputs = try hashOutputs(allocator, NEW_HASH),
        };
    }
    if (std.mem.eql(u8, taskType, "upload-asset")) {
        return .{
            .status = .Failed,
            .errorMessage = "test-skip",
        };
    }
    return null;
}

//
// Records the messages the import sends.
//
const MessageRecorder = struct {
    // Guards the messages (the throttled writer sends from its own thread).
    mutex: std.Io.Mutex = .init,

    // The messages, as JSON text.
    messages: std.ArrayList([]const u8) = .empty,

    //
    // Records one message.
    //
    fn send(context: ?*anyopaque, message: std.json.Value) void {
        const self: *MessageRecorder = @ptrCast(@alignCast(context.?));
        const text = std.json.Stringify.valueAlloc(backend_allocator, message, .{}) catch {
            return;
        };
        self.mutex.lockUncancelable(std.testing.io);
        defer self.mutex.unlock(std.testing.io);
        self.messages.append(backend_allocator, text) catch {};
    }

    //
    // The messages of one type, parsed.
    //
    fn ofType(self: *MessageRecorder, allocator: std.mem.Allocator, messageType: []const u8) ![]std.json.ObjectMap {
        var found: std.ArrayList(std.json.ObjectMap) = .empty;
        for (self.messages.items) |text| {
            const message = try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
            const typeValue = message.object.get("type") orelse {
                continue;
            };
            if (std.mem.eql(u8, typeValue.string, messageType)) {
                try found.append(allocator, message.object);
            }
        }
        return found.items;
    }

    //
    // Frees the messages.
    //
    fn deinit(self: *MessageRecorder) void {
        for (self.messages.items) |text| {
            backend_allocator.free(text);
        }
        self.messages.deinit(backend_allocator);
    }
};

//
// The state each test starts from (TypeScript: the beforeEach of the describe block).
//
const ImportTest = struct {
    // Holds the test's allocations.
    arena: std.heap.ArenaAllocator,

    // The directory of the test.
    tempDir: []const u8,

    // The folder of photos that is imported.
    photosDir: []const u8,

    // The database imported into.
    databaseDir: []const u8,

    // The database.
    database: node_api.media_file_database.IMediaFileDatabase,

    // Generates ids.
    uuidGenerator: TestUuidGenerator,

    // Provides the time.
    timestampProvider: TestTimestampProvider,

    // Records the messages.
    messages: MessageRecorder,

    // The task context.
    context: TaskContext,

    // The queue backend.
    backend: MockBackend,

    //
    // Makes the directories and the database, and installs the backend.
    //
    fn init(self: *ImportTest, resultFactory: ResultFactory) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const allocator = self.arena.allocator();
        const io = std.testing.io;
        _ = try helpers.setupEnvironment(io);
        try registerFolderMediaSourceBuilder();
        self.tempDir = try helpers.makeTempDir(allocator, io, "import-assets-worker");
        self.photosDir = try path.join(allocator, &.{ self.tempDir, "photos" });
        try std.Io.Dir.cwd().createDirPath(io, self.photosDir);
        try helpers.setEnv("PHOTOSPHERE_TMP_DIR", try path.join(allocator, &.{ self.tempDir, "scratch" }));
        try helpers.setEnv("PHOTOSPHERE_CACHE_DIR", try path.join(allocator, &.{ self.tempDir, "cache" }));

        self.uuidGenerator = try TestUuidGenerator.init(allocator);
        self.timestampProvider = .{};
        self.databaseDir = try path.join(allocator, &.{ self.tempDir, "db" });
        const created = try storage_zig.storage_factory.createStorage(allocator, io, self.databaseDir, null, null);
        self.database = try node_api.media_file_database.createMediaFileDatabase(allocator, created.storage, self.uuidGenerator.uuidGenerator(), self.timestampProvider.timestampProvider());
        try node_api.media_file_database.createDatabase(allocator, io, created.storage, created.rawStorage, self.uuidGenerator.uuidGenerator(), self.database.metadataCollection, null);

        // The default hash-file result reports DEFAULT_HASH, and the database already holds it, so no upload is
        // queued and the run can finish.
        try self.holdInDatabase("b0b0b0b0-0000-4000-8000-000000000000", DEFAULT_HASH);

        self.messages = .{};
        self.context = TaskContext.init(self.uuidGenerator.uuidGenerator(), self.timestampProvider.timestampProvider(), "session-1", "orchestrator-task-id", .{
            .context = &self.messages,
            .function = MessageRecorder.send,
        }, 10);
        self.backend = .{
            .resultFactory = resultFactory,
        };
        try self.backend.start();
        setQueueBackend(self.backend.queueBackend());
    }

    //
    // Puts the environment back and removes the directory.
    //
    fn deinit(self: *ImportTest) void {
        helpers.restoreQueueBackend();
        self.backend.deinit();
        self.messages.deinit();
        helpers.restoreTmpDir() catch {};
        helpers.setEnv("PHOTOSPHERE_CACHE_DIR", null) catch {};
        helpers.removeTempDir(std.testing.io, self.tempDir);
        self.arena.deinit();
    }

    //
    // Puts an asset holding a hash in the database.
    //
    fn holdInDatabase(self: *ImportTest, assetId: []const u8, hash: []const u8) !void {
        var record = try BsonDocument.fromFields(self.arena.allocator(), &.{
            .{
                .key = "_id",
                .value = .{ .string = assetId },
            },
            .{
                .key = "hash",
                .value = .{ .string = hash },
            },
        });
        try self.database.metadataCollection.insertOne(std.testing.io, &record, null);
        try self.database.bsonDatabase.commit(std.testing.io);
    }

    //
    // Writes a photo into the folder that is imported.
    //
    fn writePhoto(self: *ImportTest, fileName: []const u8) ![]const u8 {
        const filePath = try path.join(self.arena.allocator(), &.{ self.photosDir, fileName });
        try helpers.writeFile(std.testing.io, filePath, fileName);
        return filePath;
    }

    //
    // Builds the task data of a manual import of the photos folder.
    //
    fn makeData(self: *ImportTest, dryRun: bool) !std.json.Value {
        const allocator = self.arena.allocator();
        var data: std.json.ObjectMap = .empty;
        var paths: std.json.Array = .init(allocator);
        try paths.append(.{ .string = self.photosDir });
        try data.put(allocator, "paths", .{ .array = paths });
        var descriptor: std.json.ObjectMap = .empty;
        try descriptor.put(allocator, "databasePath", .{ .string = self.databaseDir });
        try data.put(allocator, "storageDescriptor", .{ .object = descriptor });
        try data.put(allocator, "sessionId", .{ .string = "session-1" });
        try data.put(allocator, "dryRun", .{ .bool = dryRun });
        return .{ .object = data };
    }

    //
    // Builds the task data of an automatic import of the photos folder.
    //
    fn autoImportData(self: *ImportTest) !std.json.Value {
        const allocator = self.arena.allocator();
        var data = try self.makeData(false);
        data.object.getPtr("paths").?.* = .{ .array = .init(allocator) };
        var options: std.json.ObjectMap = .empty;
        try options.put(allocator, "auto", .{ .bool = true });
        var sources: std.json.Array = .init(allocator);
        var folder: std.json.ObjectMap = .empty;
        try folder.put(allocator, "type", .{ .string = "folder" });
        try folder.put(allocator, "path", .{ .string = self.photosDir });
        try folder.put(allocator, "recurse", .{ .bool = true });
        try sources.append(.{ .object = folder });
        try options.put(allocator, "sources", .{ .array = sources });
        try data.object.put(allocator, "options", .{ .object = options });
        return data;
    }

    //
    // Adds a job tag to task data.
    //
    fn withJob(self: *ImportTest, data: std.json.Value, id: []const u8, name: []const u8, cancelSource: []const u8) !std.json.Value {
        const allocator = self.arena.allocator();
        var job: std.json.ObjectMap = .empty;
        try job.put(allocator, "id", .{ .string = id });
        try job.put(allocator, "name", .{ .string = name });
        try job.put(allocator, "cancelSource", .{ .string = cancelSource });
        var tagged = data;
        try tagged.object.put(allocator, "job", .{ .object = job });
        return tagged;
    }

    //
    // Runs the handler and returns its output.
    //
    fn run(self: *ImportTest, data: std.json.Value) !std.json.Value {
        return importAssetsHandler(self.arena.allocator(), std.testing.io, data, self.context.taskContext());
    }

    //
    // The hash cache of the database, loaded from disk.
    //
    fn loadHashCache(self: *ImportTest) !HashCache {
        var cache = try HashCache.init(try getHashCacheDir(self.arena.allocator(), self.databaseDir), true);
        _ = try cache.load(std.testing.io);
        return cache;
    }
};

test "says what has been imported and what was already there" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("12 imported, 3 already there", try describeImportProgress(arena.allocator(), 12, 3, 0));
}

test "mentions failures only once there are some" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("12 imported, 3 already there, 2 failed", try describeImportProgress(arena.allocator(), 12, 3, 2));
}

test "no more child tasks than the configured limit are in flight at once, and every file is still hashed" {
    var context: ImportTest = undefined;
    try context.init(everyFileNew);
    defer context.deinit();
    const allocator = context.arena.allocator();
    const fileCount = 20;
    const limit = 3;
    context.backend.idleMs = 50;
    context.context.maxConcurrentChildTasks = limit;

    // Every file is new, so each one needs an upload after its hash: both kinds of child task
    // count against the same limit, because both hold a worker.
    var fileNumber: usize = 0;
    while (fileNumber < fileCount) : (fileNumber += 1) {
        _ = try context.writePhoto(try std.fmt.allocPrint(allocator, "img{d}.jpg", .{fileNumber}));
    }

    _ = try context.run(try context.makeData(false));

    try std.testing.expect(context.backend.peakTasksInFlight <= limit);
    try std.testing.expectEqual(@as(usize, fileCount), (try context.backend.tasksOfType(allocator, "hash-file")).len);
}

test "the limit is read from the task data, so a different caller gets a different limit" {
    var context: ImportTest = undefined;
    try context.init(hashFileReportsDefault);
    defer context.deinit();
    const allocator = context.arena.allocator();
    const fileCount = 20;
    context.backend.idleMs = 50;
    var fileNumber: usize = 0;
    while (fileNumber < fileCount) : (fileNumber += 1) {
        _ = try context.writePhoto(try std.fmt.allocPrint(allocator, "img{d}.jpg", .{fileNumber}));
    }

    context.context.maxConcurrentChildTasks = 2;
    _ = try context.run(try context.makeData(false));
    try std.testing.expect(context.backend.peakTasksInFlight <= 2);

    var secondBackend: MockBackend = .{
        .resultFactory = hashFileReportsDefault,
        .idleMs = 50,
    };
    try secondBackend.start();
    defer secondBackend.deinit();
    setQueueBackend(secondBackend.queueBackend());

    context.context.maxConcurrentChildTasks = 8;
    _ = try context.run(try context.makeData(false));
    try std.testing.expect(secondBackend.peakTasksInFlight > 2);
    try std.testing.expect(secondBackend.peakTasksInFlight <= 8);
}

test "a missing or nonsensical concurrency limit fails loudly rather than importing unbounded" {
    var context: ImportTest = undefined;
    try context.init(hashFileReportsDefault);
    defer context.deinit();
    context.context.maxConcurrentChildTasks = 0;

    try std.testing.expectError(error.Thrown, context.run(try context.makeData(false)));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "maxConcurrentChildTasks") != null);
}

// Not ported: "childQueue.shutdown is called in the finally block even when scanPaths throws" (TypeScript makes
// the scan throw by mocking scanPaths; a real scan of a real folder does not throw).

//
// Releases the write lock another owner holds, a while after the import has started waiting for it.
//
fn releaseLockLater(rawStorage: storage_zig.storage.IStorage) void {
    const io = std.testing.io;
    utils.sleep.sleep(io, 1500) catch {};
    var arena = std.heap.ArenaAllocator.init(backend_allocator);
    defer arena.deinit();
    rawStorage.releaseWriteLock(arena.allocator(), io, ".db/write.lock") catch {};
}

test "when acquireWriteLock returns false, retries until lock is acquired and sleep is called" {
    var context: ImportTest = undefined;
    try context.init(newFileUploads);
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    _ = try context.writePhoto("img1.jpg");
    // (Zig: another owner holds the lock when the import first asks for it, and lets go of it a while later.)
    const created = try storage_zig.storage_factory.createStorage(allocator, io, context.databaseDir, null, null);
    try std.testing.expect(try created.rawStorage.acquireWriteLock(allocator, io, ".db/write.lock", "other-owner"));
    const releaser = try std.Thread.spawn(.{}, releaseLockLater, .{created.rawStorage});
    defer releaser.join();

    const startedAt = std.Io.Clock.real.now(io).toMilliseconds();
    const output = try context.run(try context.makeData(true));

    // The import waited for the lock rather than giving up.
    try std.testing.expect(std.Io.Clock.real.now(io).toMilliseconds() - startedAt >= 1000);
    try std.testing.expectEqual(@as(usize, 1), output.object.get("imported").?.array.items.len);
}

test "localHashCache.save is called after all tasks complete" {
    var context: ImportTest = undefined;
    try context.init(newFileUploads);
    defer context.deinit();
    const allocator = context.arena.allocator();
    const filePath = try context.writePhoto("img1.jpg");

    _ = try context.run(try context.makeData(false));

    // What the run learnt is on disk for the next run.
    var cache = try context.loadHashCache();
    defer cache.deinit();
    try std.testing.expect(try cache.getHash(allocator, filePath) != null);
}

test "after a successful upload, merkle-tree.addItem and metadataCollection.insertOne are called" {
    var context: ImportTest = undefined;
    try context.init(newFileUploads);
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    _ = try context.writePhoto("img1.jpg");

    const output = try context.run(try context.makeData(false));

    const assetId = output.object.get("imported").?.array.items[0].object.get("assetId").?.string;
    const storage = try helpers.directoryStorage(allocator, io, context.databaseDir);
    const filesTree = (try node_api.tree.loadMerkleTree(allocator, io, storage)).?;
    try std.testing.expect(node_api.media_file_database.getFilesImported(filesTree.databaseMetadata) == 1);
    try std.testing.expect(@import("merkle-tree-zig").merkle_tree.findItemInTree(filesTree.sort, try std.fmt.allocPrint(allocator, "asset/{s}", .{assetId})) != null);

    const reopened = try node_api.media_file_database.createMediaFileDatabase(allocator, storage, context.uuidGenerator.uuidGenerator(), context.timestampProvider.timestampProvider());
    var found = false;
    var next: ?[]const u8 = null;
    while (true) {
        const page = try reopened.metadataCollection.getAll(io, next);
        for (page.records) |record| {
            if (std.mem.eql(u8, record.get("_id").?.string, assetId)) {
                found = true;
            }
        }
        next = page.next;
        if (next == null) {
            break;
        }
    }
    try std.testing.expect(found);
}

test "sends import-success when hash-file reports a new file and upload-asset succeeds" {
    var context: ImportTest = undefined;
    try context.init(newFileUploads);
    defer context.deinit();
    _ = try context.writePhoto("img1.jpg");

    _ = try context.run(try context.makeData(true));

    try std.testing.expectEqual(@as(usize, 1), (try context.messages.ofType(context.arena.allocator(), "import-success")).len);
}

test "queues a hash-file task for each file found by scanPaths" {
    var context: ImportTest = undefined;
    try context.init(hashFileReportsDefault);
    defer context.deinit();
    const allocator = context.arena.allocator();
    const firstPath = try context.writePhoto("img1.jpg");
    const secondPath = try context.writePhoto("img2.jpg");

    _ = try context.run(try context.makeData(false));

    const hashFileTasks = try context.backend.tasksOfType(allocator, "hash-file");
    try std.testing.expectEqual(@as(usize, 2), hashFileTasks.len);
    try std.testing.expectEqualStrings(firstPath, hashFileTasks[0].object.get("filePath").?.string);
    try std.testing.expectEqualStrings("image/jpeg", hashFileTasks[0].object.get("contentType").?.string);
    try std.testing.expectEqualStrings(context.databaseDir, hashFileTasks[0].object.get("storageDescriptor").?.object.get("databasePath").?.string);
    try std.testing.expectEqualStrings("session-1", hashFileTasks[0].object.get("sessionId").?.string);
    try std.testing.expectEqual(false, hashFileTasks[0].object.get("dryRun").?.bool);
    try std.testing.expectEqualStrings(secondPath, hashFileTasks[1].object.get("filePath").?.string);
}

test "sends scan-progress messages during scanning" {
    var context: ImportTest = undefined;
    try context.init(hashFileReportsDefault);
    defer context.deinit();

    _ = try context.run(try context.makeData(false));

    const scanProgress = try context.messages.ofType(context.arena.allocator(), "scan-progress");
    try std.testing.expect(scanProgress.len > 0);
    try std.testing.expectEqualStrings("photos", scanProgress[0].get("currentPath").?.string);
}

test "reports its job as it scans, carrying the tag it was queued with" {
    var context: ImportTest = undefined;
    try context.init(hashFileReportsDefault);
    defer context.deinit();
    const allocator = context.arena.allocator();

    _ = try context.run(try context.withJob(try context.makeData(false), "session-1", "Importing photos", "session-1"));

    const jobMessages = try context.messages.ofType(allocator, "job-progress");
    try std.testing.expect(jobMessages.len > 0);
    const job = jobMessages[0].get("job").?.object;
    try std.testing.expectEqualStrings("session-1", job.get("id").?.string);
    try std.testing.expectEqualStrings("Importing photos", job.get("name").?.string);
    // The session id the import was queued under, so Cancel stops this import's tasks.
    try std.testing.expectEqualStrings("session-1", job.get("cancelSource").?.string);
    try std.testing.expectEqualStrings("0 imported, 0 already there", jobMessages[0].get("progressMessage").?.string);
}

test "reports no job when the import was queued without a tag" {
    var context: ImportTest = undefined;
    try context.init(hashFileReportsDefault);
    defer context.deinit();

    _ = try context.run(try context.makeData(false));

    try std.testing.expectEqual(@as(usize, 0), (try context.messages.ofType(context.arena.allocator(), "job-progress")).len);
}

test "sends file-ignored messages when files are ignored" {
    var context: ImportTest = undefined;
    try context.init(hashFileReportsDefault);
    defer context.deinit();
    const allocator = context.arena.allocator();
    // (Zig: two files that are not media, and a photo after them, so the scan reports progress once both have
    // been ignored.)
    _ = try context.writePhoto("a.txt");
    _ = try context.writePhoto("b.txt");
    _ = try context.writePhoto("c.jpg");

    _ = try context.run(try context.makeData(false));

    const ignoredMessages = try context.messages.ofType(allocator, "file-ignored");
    var ignored: i64 = 0;
    for (ignoredMessages) |message| {
        ignored += message.get("count").?.integer;
    }
    try std.testing.expectEqual(@as(i64, 2), ignored);
}

test "stops queuing tasks when cancelled" {
    var context: ImportTest = undefined;
    try context.init(hashFileReportsDefault);
    defer context.deinit();
    _ = try context.writePhoto("img1.jpg");
    context.context.cancel();

    _ = try context.run(try context.makeData(false));

    try std.testing.expectEqual(@as(usize, 0), (try context.backend.tasksOfType(context.arena.allocator(), "hash-file")).len);
}

test "skips duplicate hashes discovered in the same scan" {
    var context: ImportTest = undefined;
    try context.init(sameNewHashUploadFails);
    defer context.deinit();
    // Both files return the same hash: the second should be skipped.
    _ = try context.writePhoto("img1.jpg");
    _ = try context.writePhoto("img2.jpg");

    _ = try context.run(try context.makeData(false));

    // Only one upload-asset task should be queued (duplicate skipped).
    try std.testing.expectEqual(@as(usize, 1), (try context.backend.tasksOfType(context.arena.allocator(), "upload-asset")).len);
}

test "sends import-skipped message when hash already in database" {
    var context: ImportTest = undefined;
    try context.init(newFileUploads);
    defer context.deinit();
    // The database already holds this hash. The import loads that once at the start of a run,
    // rather than asking per file, so this is where a photo becomes already-imported.
    try context.holdInDatabase("c0c0c0c0-0000-4000-8000-000000000000", NEW_HASH);
    _ = try context.writePhoto("img1.jpg");

    _ = try context.run(try context.makeData(false));

    try std.testing.expectEqual(@as(usize, 1), (try context.messages.ofType(context.arena.allocator(), "import-skipped")).len);
}

test "hands each hash-file task the identity supplied for its path" {
    var context: ImportTest = undefined;
    try context.init(newFileUploads);
    defer context.deinit();
    const allocator = context.arena.allocator();
    const filePath = try context.writePhoto("img1.jpg");

    _ = try context.run(try context.autoImportData());

    const hashFileTask = (try context.backend.tasksOfType(allocator, "hash-file"))[0];
    const identity = hashFileTask.object.get("cacheIdentity").?.object;
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, filePath, .{});
    try std.testing.expectEqualStrings(filePath, identity.get("key").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(stat.size)), identity.get("length").?.integer);
}

test "reports an automatic import as a job under its own name" {
    var context: ImportTest = undefined;
    try context.init(newFileUploads);
    defer context.deinit();
    _ = try context.writePhoto("img1.jpg");

    _ = try context.run(try context.withJob(try context.autoImportData(), "auto-import:/test/db", "Automatic import", "auto-import"));

    // Automatic import is a job like any other. It runs the same handler as a manual import, so
    // the only thing separating them in the list is what the row is called.
    const jobMessages = try context.messages.ofType(context.arena.allocator(), "job-progress");
    try std.testing.expect(jobMessages.len > 0);
    try std.testing.expectEqualStrings("Automatic import", jobMessages[0].get("job").?.object.get("name").?.string);
}

test "hands an ordinary file no identity at all, which is what keeps manual import unchanged" {
    var context: ImportTest = undefined;
    try context.init(newFileUploads);
    defer context.deinit();
    _ = try context.writePhoto("img1.jpg");

    _ = try context.run(try context.makeData(false));

    const hashFileTask = (try context.backend.tasksOfType(context.arena.allocator(), "hash-file"))[0];
    try std.testing.expect(hashFileTask.object.get("cacheIdentity") == null);
}

test "files a photo library item under its source id, against the size and time the library reported" {
    var context: ImportTest = undefined;
    try context.init(newFileUploads);
    defer context.deinit();
    const allocator = context.arena.allocator();
    const filePath = try context.writePhoto("img1.jpg");
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, filePath, .{});

    _ = try context.run(try context.autoImportData());

    var cache = try context.loadHashCache();
    defer cache.deinit();
    const listing = try cache.getAllEntries(allocator);
    try std.testing.expectEqual(@as(usize, 1), listing.len);
    try std.testing.expectEqual(true, listing[0].keyedBySourceId);
    try std.testing.expectEqual(@as(u64, stat.size), listing[0].size);
    try std.testing.expectEqual(@as(i64, @intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_ms))), listing[0].lastModified);
}

test "files an ordinary file under its own path and its own stat" {
    var context: ImportTest = undefined;
    try context.init(newFileUploads);
    defer context.deinit();
    const allocator = context.arena.allocator();
    const filePath = try context.writePhoto("img1.jpg");
    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, filePath, .{});

    _ = try context.run(try context.makeData(false));

    var cache = try context.loadHashCache();
    defer cache.deinit();
    const listing = try cache.getAllEntries(allocator);
    try std.testing.expectEqual(@as(usize, 1), listing.len);
    try std.testing.expectEqual(false, listing[0].keyedBySourceId);
    try std.testing.expectEqual(@as(u64, stat.size), listing[0].size);
    const entry = (try cache.getHash(allocator, filePath)).?;
    try std.testing.expectEqualStrings(NEW_HASH, &std.fmt.bytesToHex(entry.hash[0..32].*, .lower));
}

test "records the asset id against the cache entry once the database write has landed" {
    var context: ImportTest = undefined;
    try context.init(newFileUploads);
    defer context.deinit();
    const allocator = context.arena.allocator();
    const filePath = try context.writePhoto("img1.jpg");

    const output = try context.run(try context.autoImportData());

    // Under the source id, because that is what the entry is filed under, and with the id the
    // upload reported rather than anything invented here.
    const assetId = output.object.get("imported").?.array.items[0].object.get("assetId").?.string;
    var cache = try context.loadHashCache();
    defer cache.deinit();
    try std.testing.expectEqualStrings(assetId, (try cache.getHash(allocator, filePath)).?.assetId.?);
}

test "records the id of an asset the database already held, so it is not looked up again" {
    var context: ImportTest = undefined;
    try context.init(newFileUploads);
    defer context.deinit();
    const allocator = context.arena.allocator();
    // The database holds this hash, which is what makes it already-imported. The import reads
    // that from the map it builds when the run starts, not from the task result.
    try context.holdInDatabase("d0d0d0d0-0000-4000-8000-000000000000", NEW_HASH);
    const filePath = try context.writePhoto("img1.jpg");

    _ = try context.run(try context.autoImportData());

    var cache = try context.loadHashCache();
    defer cache.deinit();
    try std.testing.expectEqualStrings("d0d0d0d0-0000-4000-8000-000000000000", (try cache.getHash(allocator, filePath)).?.assetId.?);
}

// Not ported: "writes the import record part way through a long import, not only at the end" (TypeScript counts
// the calls to its mocked recordImports; how many writes made the record is not visible in the record).

test "writes the import record once at the end of a short import" {
    var context: ImportTest = undefined;
    try context.init(hashFileReportsDefault);
    defer context.deinit();
    _ = try context.writePhoto("img1.jpg");

    _ = try context.run(try context.makeData(false));

    const record = try loadImportRecord(context.arena.allocator(), std.testing.io, context.databaseDir);
    try std.testing.expectEqual(@as(usize, 1), record.entries.len);
}

test "records against the database path, not the database's storage" {
    var context: ImportTest = undefined;
    try context.init(hashFileReportsDefault);
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.writePhoto("img1.jpg");

    _ = try context.run(try context.makeData(false));

    // The record is a local file worked out from the database path. Handing the record a storage
    // is what used to put it inside the database, where several machines overwrote each other's.
    try std.testing.expect(helpers.fileExists(std.testing.io, try getImportRecordPath(allocator, context.databaseDir)));
    try std.testing.expect(!std.mem.startsWith(u8, try getImportRecordPath(allocator, context.databaseDir), context.databaseDir));
}

test "a dry run records nothing, because it changed nothing" {
    var context: ImportTest = undefined;
    try context.init(hashFileReportsDefault);
    defer context.deinit();
    _ = try context.writePhoto("img1.jpg");

    _ = try context.run(try context.makeData(true));

    try std.testing.expect(!helpers.fileExists(std.testing.io, try getImportRecordPath(context.arena.allocator(), context.databaseDir)));
}

// Not ported: "releases each file once the import has finished with it" and "releases a file the database already
// held" (TypeScript mocks the automatic scanner to see release; the scanner of a folder releases nothing).

test "reports what an automatic import is doing, so the panel has something to show" {
    var context: ImportTest = undefined;
    try context.init(newFileUploads);
    defer context.deinit();
    _ = try context.writePhoto("img1.jpg");

    _ = try context.run(try context.autoImportData());

    try std.testing.expect((try context.messages.ofType(context.arena.allocator(), "import-progress")).len > 0);
}

test "says how much of what it skipped was recognised without opening the file" {
    var context: ImportTest = undefined;
    try context.init(newFileUploads);
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    // (Zig: the first photo of the folder is recorded in the hash cache as already imported, so the scanner
    // recognises it without opening it, as TypeScript's mocked scanner reports.)
    const skippedPath = try context.writePhoto("a.jpg");
    _ = try context.writePhoto("b.jpg");
    const stat = try std.Io.Dir.cwd().statFile(io, skippedPath, .{});
    var cache = try HashCache.init(try getHashCacheDir(allocator, context.databaseDir), false);
    _ = try cache.load(io);
    var hash: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&hash, DEFAULT_HASH);
    try cache.addSourceHash(skippedPath, .{
        .hash = &hash,
        .length = stat.size,
        .lastModified = @intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_ms)),
    });
    _ = try cache.setAssetId(skippedPath, "b0b0b0b0-0000-4000-8000-000000000000");
    try cache.save(io);
    cache.deinit();

    _ = try context.run(try context.autoImportData());

    const progressMessages = try context.messages.ofType(allocator, "import-progress");
    try std.testing.expect(progressMessages.len > 0);
    for (progressMessages) |message| {
        try std.testing.expectEqual(@as(i64, 1), message.get("skippedBeforeOpening").?.integer);
        try std.testing.expectEqual(@as(i64, 1), message.get("skipped").?.integer);
    }
}

test "reports what a manual import is doing, through the very same message" {
    var context: ImportTest = undefined;
    try context.init(newFileUploads);
    defer context.deinit();
    const allocator = context.arena.allocator();
    _ = try context.writePhoto("img1.jpg");

    _ = try context.run(try context.makeData(false));

    // One kind of progress message, sent by both kinds of import. The panel shows either without
    // knowing which it is watching.
    try std.testing.expect((try context.messages.ofType(allocator, "import-progress")).len > 0);
    // It does not badge what the user imported by hand as something that arrived on its own.
    for (try context.messages.ofType(allocator, "import-success")) |message| {
        try std.testing.expectEqualStrings("manual", message.get("source").?.string);
    }
}

test "names the database an automatic arrival landed in, which the gallery needs" {
    var context: ImportTest = undefined;
    try context.init(newFileUploads);
    defer context.deinit();
    // Automatic import writes to the default database, which is not necessarily the one on
    // screen. An arrival in another database is not that gallery's to show.
    _ = try context.writePhoto("img1.jpg");

    _ = try context.run(try context.autoImportData());

    const arrivals = try context.messages.ofType(context.arena.allocator(), "import-success");
    try std.testing.expectEqual(@as(usize, 1), arrivals.len);
    try std.testing.expectEqualStrings(context.databaseDir, arrivals[0].get("databasePath").?.string);
    try std.testing.expectEqualStrings("automatic", arrivals[0].get("source").?.string);
}

// Not ported: "saves the hash cache as soon as the scanner has nothing left to import" and "does not save the hash
// cache while the scanner still has work to hand over" (TypeScript counts the calls to its mocked save; a run
// saves at its end as well, so the file on disk cannot tell the two apart).

test "writes fewer assets than a batch holds rather than stranding them" {
    var context: ImportTest = undefined;
    try context.init(newFileUploads);
    defer context.deinit();
    const allocator = context.arena.allocator();
    const io = std.testing.io;
    // Assets are held back until a batch is worth committing, because every batch pays for a
    // full database commit whatever its size. What that must never do is strand the last few:
    // a run that took in fewer than a batch's worth has to write them anyway, and a phone
    // taking in one photo is exactly that run.
    _ = try context.writePhoto("img1.jpg");

    const output = try context.run(try context.autoImportData());

    try std.testing.expectEqual(@as(usize, 1), output.object.get("imported").?.array.items.len);
    const storage = try helpers.directoryStorage(allocator, io, context.databaseDir);
    const filesTree = (try node_api.tree.loadMerkleTree(allocator, io, storage)).?;
    try std.testing.expectEqual(@as(u64, 1), node_api.media_file_database.getFilesImported(filesTree.databaseMetadata));
}

// Not ported: "does not give every photo its own database commit once the scanner is caught up", "drops the
// database's cached pages when the database was last written by something else" and "keeps the database's cached
// pages when nothing has written to it" (TypeScript counts the calls to its mocked commit and flush; the Zig
// database has no seam to count them at).
