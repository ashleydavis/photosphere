const std = @import("std");
const utils = @import("utils-zig");
const api = @import("api-zig");
const storage_zig = @import("storage-zig");
const task_queue_zig = @import("task-queue-zig");
const hash_cache = @import("hash-cache.zig");
const file_scanner = @import("file-scanner.zig");
const media_file_database = @import("media-file-database.zig");
const check_worker = @import("check.worker.zig");
const create_auto_import_scanner = @import("create-auto-import-scanner.zig");
const errors = utils.errors;
const log = &utils.log.log;
const retryOrLog = utils.retry_or_log.retryOrLog;
const swallowError = utils.swallow_error.swallowError;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const getHashCacheDir = hash_cache.getHashCacheDir;
const HashCache = hash_cache.HashCache;
const scanPaths = file_scanner.scanPaths;
const FileScannedResult = file_scanner.FileScannedResult;
const ScannerState = file_scanner.ScannerState;
const IAddSummary = media_file_database.IAddSummary;
const TaskStatus = task_queue_zig.types.TaskStatus;
const TaskQueue = task_queue_zig.task_queue.TaskQueue;
const ITaskResult = task_queue_zig.types.ITaskResult;
const ICheckFileData = check_worker.ICheckFileData;
const ICheckFileResult = check_worker.ICheckFileResult;
const IDatabaseDescriptor = api.database_descriptor.IDatabaseDescriptor;
const SaveHashCacheOperation = create_auto_import_scanner.SaveHashCacheOperation;
const parseISOString = storage_zig.storage.parseISOString;

//
// Progress callback for checkPaths that includes the current summary
// (Zig: a closure; `function` is called with `context`. The values are only valid during the call.)
//
pub const CheckPathsProgressCallback = struct {
    // The state of the callback, passed to function.
    context: ?*anyopaque,

    // The callback function.
    function: *const fn (context: ?*anyopaque, currentlyScanning: ?[]const u8, summary: *const IAddSummary) void,
};

//
// What the callbacks checkPaths registers share (TypeScript: the variables they close over).
//
const CheckPathsState = struct {
    // Allocates the task data and the parsed task results.
    allocator: std.mem.Allocator,

    // Saves the hash cache.
    io: std.Io,

    // The running summary.
    summary: IAddSummary,

    // The hash cache of the database, updated with the hashes the tasks compute.
    localHashCache: *HashCache,

    // How many hashes were added to the cache.
    filesAddedToCache: u64,

    // The queue the check-file tasks are added to.
    queue: *TaskQueue,

    // Identifies the database for the tasks.
    storageDescriptor: IDatabaseDescriptor,

    // The directory of the hash cache.
    hashCacheDir: []const u8,

    // Called as files are scanned.
    progressCallback: ?CheckPathsProgressCallback,

    //
    // Registers a callback to integrate results as tasks complete.
    // (TypeScript: the arrow function passed to queue.onTaskComplete.)
    //
    fn onTaskComplete(context: ?*anyopaque, result: ITaskResult) anyerror!void {
        const self: *CheckPathsState = @ptrCast(@alignCast(context.?));
        const allocator = self.allocator;
        const inputs = try std.json.parseFromValueLeaky(ICheckFileData, allocator, result.inputs, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });

        if (result.status == TaskStatus.Succeeded) {

            self.summary.filesProcessed += 1;

            const checkResult = try std.json.parseFromValueLeaky(ICheckFileResult, allocator, result.outputs.?, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });

            // Add hash to cache if computation was successful and hash wasn't already in cache
            if (checkResult.hashedFile) |hashedFile| {
                if (!checkResult.hashFromCache) {
                    var hash: [32]u8 = undefined;
                    _ = try std.fmt.hexToBytes(&hash, hashedFile.hash);
                    const lastModified = parseISOString(hashedFile.lastModified) orelse {
                        return errors.throwError("Invalid lastModified \"{s}\" in the result of check-file", .{hashedFile.lastModified});
                    };
                    try self.localHashCache.addHash(inputs.filePath, .{
                        .hash = &hash,
                        .lastModified = lastModified.epochMilliseconds,
                        .length = hashedFile.length,
                    });

                    self.filesAddedToCache += 1;

                    // Save cache periodically (every 100 files added to cache)
                    if (self.filesAddedToCache % 100 == 0) {

                        var saveOperation: SaveHashCacheOperation = .{
                            .cache = self.localHashCache,
                        };
                        _ = swallowError(self.io, &saveOperation);
                    }
                }

                // Use database lookup result from worker
                // Use logicalPath for display (always set)
                if (checkResult.matchingRecordsCount > 0) {
                    log.verbose(try std.fmt.allocPrint(allocator, "File \"{s}\" with hash \"{s}\", matches {d} existing records.", .{ inputs.logicalPath, hashedFile.hash, checkResult.matchingRecordsCount }));
                    self.summary.filesAlreadyAdded += 1;
                }
                else {
                    log.verbose(try std.fmt.allocPrint(allocator, "File \"{s}\" has not been added to the media file database.", .{inputs.logicalPath}));
                    self.summary.filesAdded += 1;
                    self.summary.totalSize += @floatFromInt(inputs.fileStat.length);
                }
            }
            else {
                log.@"error"(try std.fmt.allocPrint(allocator, "Failed to get hash for file {s}", .{inputs.logicalPath}));
                self.summary.filesFailed += 1;
            }
        }
        else if (result.status == TaskStatus.Failed) {
            const logicalPath = if (inputs.logicalPath.len > 0) inputs.logicalPath else "unknown";
            const errorMessage = result.errorMessage orelse "";
            const message = try std.fmt.allocPrint(allocator, "Failed to check file \"{s}\": {s}", .{ logicalPath, errorMessage });
            if (result.@"error") |taskError| {
                errors.recordError(taskError.name, "{s}", .{taskError.message});
                log.exception(message, error.Thrown);
            }
            else {
                log.@"error"(message);
            }
            self.summary.filesFailed += 1;
            self.summary.filesProcessed += 1;
        }
    }

    //
    // Queues a check-file task for a scanned file (TypeScript: the first arrow function passed to scanPaths).
    //
    fn visitFile(context: ?*anyopaque, result: FileScannedResult) anyerror!void {
        const self: *CheckPathsState = @ptrCast(@alignCast(context.?));
        const allocator = self.allocator;

        // Queue all files for worker processing (workers will check cache and database)
        const data: ICheckFileData = .{
            .filePath = result.filePath,
            .fileStat = result.fileStat,
            .contentType = result.contentType,
            .storageDescriptor = self.storageDescriptor,
            .hashCacheDir = self.hashCacheDir,
            .logicalPath = result.logicalPath,
        };
        const text = try std.json.Stringify.valueAlloc(allocator, data, .{
            .emit_null_optional_fields = false,
        });
        _ = try self.queue.addTask("check-file", try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{}), null, null);
    }

    //
    // Reports scanning progress (TypeScript: the second arrow function passed to scanPaths).
    //
    fn onScanProgress(context: ?*anyopaque, currentlyScanning: ?[]const u8, state: *const ScannerState) void {
        const self: *CheckPathsState = @ptrCast(@alignCast(context.?));
        self.summary.filesIgnored = @floatFromInt(state.numFilesIgnored);
        if (self.progressCallback) |progressCallback| {
            progressCallback.function(progressCallback.context, currentlyScanning, &self.summary);
        }
    }
};

//
// Checks a list of files or directories to find files already added to the media file database.
//
pub fn checkPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    storageDescriptor: IDatabaseDescriptor,
    paths: []const []const u8,
    progressCallback: ?CheckPathsProgressCallback,
    uuidGenerator: IUuidGenerator,
    sessionTempDir: []const u8,
) !IAddSummary {
    // Create hash cache for file hashing optimization
    const hashCacheDir = try getHashCacheDir(allocator, storageDescriptor.databasePath);
    var localHashCache = try HashCache.init(hashCacheDir, false);
    defer localHashCache.deinit();
    _ = try localHashCache.load(io);

    const queue = try TaskQueue.init(allocator, io, uuidGenerator, storageDescriptor.databasePath);
    defer queue.deinit();
    defer queue.shutdown();

    var state: CheckPathsState = .{
        .allocator = allocator,
        .io = io,
        .summary = .{
            .filesAdded = 0,
            .filesAlreadyAdded = 0,
            .filesIgnored = 0,
            .filesFailed = 0,
            .filesProcessed = 0,
            .totalSize = 0,
            .averageSize = 0,
        },
        .localHashCache = &localHashCache,
        .filesAddedToCache = 0,
        .queue = queue,
        .storageDescriptor = storageDescriptor,
        .hashCacheDir = hashCacheDir,
        .progressCallback = progressCallback,
    };

    //
    // Registers a callback to integrate results as tasks complete.
    //
    _ = try queue.onTaskComplete(.{
        .context = &state,
        .function = CheckPathsState.onTaskComplete,
    });

    //
    // Queue up all checking tasks as files are scanned.
    // All files are queued - workers will check cache and database.
    //
    try scanPaths(allocator, io, paths, .{
        .context = &state,
        .function = CheckPathsState.visitFile,
    }, .{
        .context = &state,
        .function = CheckPathsState.onScanProgress,
    }, .{
        .ignorePatterns = &.{".db"},
    }, sessionTempDir, uuidGenerator);

    //
    // Wait for all tasks to complete.
    //
    try queue.awaitAllTasks();

    // Final save of hash cache
    var saveOperation: SaveHashCacheOperation = .{
        .cache = &localHashCache,
    };
    _ = try retryOrLog(io, &saveOperation, "Failed to save hash cache", 3, 1000, 2);

    state.summary.averageSize = if (state.summary.filesAdded > 0) @floor(state.summary.totalSize / state.summary.filesAdded) else 0;
    return state.summary;
}
