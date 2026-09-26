const std = @import("std");
const utils = @import("utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const storage_zig = @import("storage-zig");
const serialization_zig = @import("serialization-zig");
const task_queue_zig = @import("task-queue-zig");
const bdb = @import("bdb-zig");
const api = @import("api-zig");
const media_file_database = @import("media-file-database.zig");
const retry_operations = @import("retry-operations.zig");
const verify_worker = @import("verify.worker.zig");
const errors = utils.errors;
const log = &utils.log.log;
const retry = utils.retry.retry;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const ProgressCallback = media_file_database.ProgressCallback;
const SortNode = merkle_tree_zig.merkle_tree.SortNode;
const traverseTreeAsync = merkle_tree_zig.traverse.traverseTreeAsync;
const IStorage = storage_zig.storage.IStorage;
const IDatabaseDescriptor = api.database_descriptor.IDatabaseDescriptor;
const TaskStatus = task_queue_zig.types.TaskStatus;
const TaskQueue = task_queue_zig.task_queue.TaskQueue;
const ITaskResult = task_queue_zig.types.ITaskResult;
const IVerifyFileResult = verify_worker.IVerifyFileResult;
const verifySerializedFile = serialization_zig.serialization.verify;
const IBsonCollection = bdb.collection.IBsonCollection;

//
// Options for verifying the media file database.
//
pub const IVerifyOptions = struct {
    //
    // Enables full verification where all files are re-hashed.
    //
    full: ?bool = null,

    //
    // Path filter to only verify files matching this path (file or directory).
    //
    pathFilter: ?[]const u8 = null,

};

//
// Result of the verification process.
//
pub const IVerifyResult = struct {
    //
    // The total number of files imported into the database.
    //
    totalImports: u64,

    //
    // The total number of files verified (including thumbnails, display, BSON, etc.).
    //
    totalFiles: u64,

    //
    // The total database size.
    //
    totalSize: u64,

    //
    // The number of files that were unmodified.
    //
    numUnmodified: u64,

    //
    // The number of files that failed to verify.
    //
    numFailures: u64,

    //
    // The list of files that were modified.
    //
    modified: []const []const u8,

    //
    // The list of new files that were added to the database.
    //
    new: []const []const u8,

    //
    // The list of files that were removed from the database.
    //
    removed: []const []const u8,

    //
    // The number of files that were processed from the file system.
    //
    filesProcessed: u64,

    //
    // The number of nodes processed in the merkle tree.
    //
    nodesProcessed: u64,

    //
    // Asset paths that have no database record or a record with the wrong id/hash.
    //
    recordMismatches: ?[]const []const u8 = null,
};

//
// Formats a progress message into a buffer (the messages are only valid during the progress callback).
// (No TypeScript counterpart: TypeScript uses template strings.)
//
fn reportProgress(progressCallback: ?ProgressCallback, comptime format: []const u8, args: anytype) void {
    const callback = progressCallback orelse {
        return;
    };
    var buffer: [1024]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, format, args) catch buffer[0..];
    callback.call(message);
}

//
// The state of a verification that the task completion callback and the tree traversal callback update.
// (No TypeScript counterpart: TypeScript closures capture the variables of verify. The lists grow here and are
// copied to the IVerifyResult at the end.)
//
const VerifyState = struct {
    // Allocates the lists and the file names copied from task results.
    allocator: std.mem.Allocator,

    // The counters of the result (the lists are kept below).
    result: IVerifyResult,

    // The files that were modified.
    modified: std.ArrayList([]const u8),

    // The files that were removed.
    removed: std.ArrayList([]const u8),

    // Asset paths without a matching database record.
    recordMismatches: std.ArrayList([]const u8),

    // The number of files in the tree.
    totalFiles: u64,

    // True when the database is a partial replica.
    isPartial: bool,

    // Reports progress.
    progressCallback: ?ProgressCallback,

    // The queue the verify-file tasks are added to.
    queue: *TaskQueue,

    // The normalized path filter.
    pathFilter: ?[]const u8,

    // Identifies the database for the tasks.
    storageDescriptor: IDatabaseDescriptor,

    // The verification options.
    options: ?IVerifyOptions,

    // Hash of each database record by record ID.
    recordIdToHash: *std.StringHashMapUnmanaged([]const u8),

    //
    // Registers a callback to integrate results as tasks complete.
    // (TypeScript: the arrow function passed to queue.onTaskComplete. Runs on the thread blocked in awaitAllTasks.)
    //
    fn onTaskComplete(context: ?*anyopaque, taskResult: ITaskResult) anyerror!void {
        const self: *VerifyState = @ptrCast(@alignCast(context.?));
        const allocator = self.allocator;

        self.result.filesProcessed += 1;

        if (taskResult.status == TaskStatus.Succeeded) {
            const fileResult = try std.json.parseFromValueLeaky(IVerifyFileResult, allocator, taskResult.outputs orelse .null, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });

            reportProgress(self.progressCallback, "Verified file {d} of {d}", .{ self.result.filesProcessed, self.totalFiles });

            if (fileResult.status == .removed) {
                // For partial databases, ignore missing files (they're expected to be missing)
                if (!self.isPartial) {
                    try self.removed.append(allocator, fileResult.fileName);

                    log.verbose(try std.fmt.allocPrint(allocator, "File {s} is missing.", .{fileResult.fileName}));
                }
                else {
                    // Count as unmodified since missing files are expected in partial databases
                    self.result.numUnmodified += 1;

                    log.verbose(try std.fmt.allocPrint(allocator, "File {s} is missing, but not an issue because this is a partial database.", .{fileResult.fileName}));
                }
            }
            else if (fileResult.status == .modified) {
                try self.modified.append(allocator, fileResult.fileName);

                log.verbose(try std.fmt.allocPrint(allocator, "File {s} is modified.", .{fileResult.fileName}));
            }
            else {
                self.result.numUnmodified += 1;

                //
                // Too noisy:
                //
                // log.verbose(`File ${fileResult.fileName} is not modified.`)
            }
        }
        else if (taskResult.status == TaskStatus.Failed) {
            const inputs = verify_worker.verifyFileDataFromJson(allocator, taskResult.inputs) catch null;
            const fileName = if (inputs != null and inputs.?.node.name != null) inputs.?.node.name.? else "unknown";
            const errorMessage = taskResult.errorMessage orelse "";
            const message = try std.fmt.allocPrint(allocator, "Failed to verify file \"{s}\": {s}", .{ fileName, errorMessage });
            if (taskResult.@"error") |taskError| {
                errors.recordError(taskError.name, "{s}", .{taskError.message});
                log.exception(message, error.Thrown);
            }
            else {
                log.@"error"(message);
            }
            self.result.numFailures += 1;
        }
    }

    //
    // Queues the verification of a node and checks asset records (TypeScript: the arrow function passed to
    // traverseTreeAsync).
    //
    fn visitNode(self: *VerifyState, node: *SortNode) anyerror!bool {
        const allocator = self.allocator;
        self.result.nodesProcessed += 1;

        if (node.name) |nodeName| {
            // Apply path filter before queuing the task
            if (self.pathFilter != null and !std.mem.startsWith(u8, nodeName, self.pathFilter.?)) {
                return true; // Skip this node
            }

            _ = try self.queue.addTask("verify-file", try verify_worker.verifyFileDataToJson(allocator, .{
                .node = node.*,
                .storageDescriptor = self.storageDescriptor,
                .options = .{
                    .full = if (self.options) |options| options.full else null,
                },
            }), null, null);

            // Check asset nodes have a database record with the correct id and hash.
            if (std.mem.startsWith(u8, nodeName, "asset/") and node.contentHash != null) {
                const assetId = nodeName["asset/".len..];
                const expectedHashHex = try std.fmt.allocPrint(allocator, "{x}", .{node.contentHash.?});
                const dbHash = self.recordIdToHash.get(assetId);
                if (dbHash == null) {
                    // Record is absent. For partial databases this is expected: BSON shard
                    // data may not have been copied yet. For full databases it is an error.
                    if (!self.isPartial) {
                        try self.recordMismatches.append(allocator, nodeName);
                        log.verbose(try std.fmt.allocPrint(allocator, "Record missing for {s}.", .{nodeName}));
                    }
                    else {
                        log.verbose(try std.fmt.allocPrint(allocator, "Record missing for {s}, but not an issue because this is a partial database.", .{nodeName}));
                    }
                }
                else if (!std.mem.eql(u8, dbHash.?, expectedHashHex)) {
                    // Record exists but its hash is wrong: always an error, even for partial databases.
                    try self.recordMismatches.append(allocator, nodeName);
                    log.verbose(try std.fmt.allocPrint(allocator, "Record mismatch for {s}. Expected hash {s}, found hash {s}.", .{ nodeName, expectedHashHex, dbHash.? }));
                }
            }
        }

        return true;
    }
};

//
// Verifies the media file database.
// Checks for missing files, modified files, and new files.
// If any files are corrupted, this will pick them up as modified.
// Also checks each asset in the merkle tree has a database record with the correct id and hash.
// (Zig: the TypeScript optional parameters are passed as null.)
//
pub fn verify(allocator: std.mem.Allocator, io: std.Io, storageDescriptor: IDatabaseDescriptor, databaseStorage: IStorage, uuidGenerator: IUuidGenerator, metadataCollection: *IBsonCollection, options: ?IVerifyOptions, progressCallback: ?ProgressCallback) !IVerifyResult {

    var pathFilter: ?[]const u8 = null;
    if (options != null and options.?.pathFilter != null and options.?.pathFilter.?.len > 0) {
        const normalized = try allocator.dupe(u8, options.?.pathFilter.?);
        std.mem.replaceScalar(u8, normalized, '\\', '/'); // Normalize path separators
        pathFilter = normalized;
    }

    // Load the merkle tree once and reuse it throughout the verification process
    var loadOperation: retry_operations.LoadMerkleTreeOperation("() => loadMerkleTree(databaseStorage)") = .{ .allocator = allocator, .storage = databaseStorage };
    const merkleTree = try retry(io, &loadOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwError("Failed to load merkle tree", .{});
    };

    const totalFiles: u64 = if (merkleTree.sort) |sort| sort.leafCount else 0;
    var recordIdToHash: std.StringHashMapUnmanaged([]const u8) = .empty;
    var state: VerifyState = .{
        .allocator = allocator,
        .result = .{
            .totalImports = media_file_database.getFilesImported(merkleTree.databaseMetadata),
            .totalFiles = totalFiles,
            .totalSize = if (merkleTree.sort) |sort| sort.size else 0,
            .numUnmodified = 0,
            .numFailures = 0,
            .modified = &.{},
            .new = &.{},
            .removed = &.{},
            .filesProcessed = 0,
            .nodesProcessed = 0,
            .recordMismatches = &.{},
        },
        .modified = .empty,
        .removed = .empty,
        .recordMismatches = .empty,
        .totalFiles = totalFiles,
        .isPartial = false,
        .progressCallback = progressCallback,
        .queue = undefined,
        .pathFilter = pathFilter,
        .storageDescriptor = storageDescriptor,
        .options = options,
        .recordIdToHash = &recordIdToHash,
    };

    //
    // Check the merkle tree to find files that have been removed.
    //
    if (progressCallback) |callback| {
        if (options != null and options.?.pathFilter != null and options.?.pathFilter.?.len > 0) {
            reportProgress(callback, "Verifying files matching: {s}", .{options.?.pathFilter.?});
        }
        else {
            callback.call("Verifying files...");
        }
    }

    //
    // Get the task queue from the provider (lazily created).
    // Handlers are registered in the worker file (apps/cli/src/lib/worker.ts).
    // maxWorkers is set in the provider constructor (defaults to number of CPUs).
    //
    const queue = try TaskQueue.init(allocator, io, uuidGenerator, storageDescriptor.databasePath);
    defer queue.deinit();
    state.queue = queue;

    //
    // Load details of database records so we can check them against the merkle tree.
    //
    var recordsLoaded: u64 = 0;
    var records = metadataCollection.iterateRecords();
    while (try records.next(io)) |record| { //todo: each shard could be loaded in a separate task.
        if (record.fields.get("hash")) |recordHash| {
            if (recordHash == .string) {
                try recordIdToHash.put(allocator, record._id, recordHash.string);
            }
        }
        recordsLoaded += 1;
        reportProgress(progressCallback, "Loaded database records... {d} loaded", .{recordsLoaded});
    }

    //
    // Registers a callback to integrate results as tasks complete.
    //
    _ = try queue.onTaskComplete(.{ .context = &state, .function = VerifyState.onTaskComplete });

    //
    // Check if database is partial - missing files should be ignored for partial databases
    //
    state.isPartial = media_file_database.isPartialDatabase(merkleTree.databaseMetadata);

    //
    // Queue up all verification tasks and check asset records against the database in a single traversal.
    // Pass the storage descriptor instead of the storage object (which can't be serialized).
    // Filter nodes by pathFilter before queuing tasks.
    //
    try traverseTreeAsync(SortNode, merkleTree.sort, &state, VerifyState.visitNode);

    //
    // Wait for all tasks to complete.
    //
    try queue.awaitAllTasks();

    state.result.modified = state.modified.items;
    state.result.removed = state.removed.items;
    state.result.recordMismatches = state.recordMismatches.items;
    return state.result;
}

//
// A file that failed verification (TypeScript: the anonymous `{ file: string; error: string }` type).
//
pub const IDatabaseFileVerifyError = struct {
    // The file that failed verification.
    file: []const u8,

    // Why the file failed verification.
    @"error": []const u8,
};

//
// Result from verifying database files.
//
pub const IDatabaseFileVerifyResult = struct {
    // The number of database files.
    totalFiles: u64,

    // The total size of the database files that were read.
    totalSize: u64,

    // The number of files that verified successfully.
    validFiles: u64,

    // The files that failed verification.
    invalidFiles: []const []const u8,

    // The errors of the files that failed verification.
    errors: []const IDatabaseFileVerifyError,
};

//
// The state of verifyDatabaseFiles that its helper functions update. (No TypeScript counterpart: TypeScript
// closures capture the variables of verifyDatabaseFiles.)
//
const DatabaseFileVerifyState = struct {
    // Allocates the lists.
    allocator: std.mem.Allocator,

    // The counters of the result.
    result: IDatabaseFileVerifyResult,

    // The files that failed verification.
    invalidFiles: std.ArrayList([]const u8),

    // The errors of the files that failed verification.
    errors: std.ArrayList(IDatabaseFileVerifyError),

    // The number of files verified so far.
    filesVerified: u64,

    // The number of files to verify.
    expectedTotal: u64,

    // Reports progress.
    progressCallback: ?ProgressCallback,

    //
    // Helper to add an error
    //
    fn addError(self: *DatabaseFileVerifyState, file: []const u8, fileError: []const u8) !void {
        try self.invalidFiles.append(self.allocator, file);
        try self.errors.append(self.allocator, .{ .file = file, .@"error" = try self.allocator.dupe(u8, fileError) });
    }

    //
    // Helper to report progress
    //
    fn reportProgress(self: *DatabaseFileVerifyState) void {
        self.filesVerified += 1;
        verify_reportProgress(self.progressCallback, "Verified database file {d} of {d}", .{ self.filesVerified, self.expectedTotal });
    }
};

//
// The module level reportProgress, named so that DatabaseFileVerifyState.reportProgress can call it.
//
const verify_reportProgress = reportProgress;

//
// Verifies all database files (merkle trees, metadata collection, sort indexes).
// Checks size and checksum for each file.
//
// @param assetStorage - Storage rooted at the asset storage root (database files live under .db/)
//
pub fn verifyDatabaseFiles(allocator: std.mem.Allocator, io: std.Io, assetStorage: IStorage, progressCallback: ?ProgressCallback) !IDatabaseFileVerifyResult {
    var state: DatabaseFileVerifyState = .{
        .allocator = allocator,
        .result = .{
            .totalFiles = 0,
            .totalSize = 0,
            .validFiles = 0,
            .invalidFiles = &.{},
            .errors = &.{},
        },
        .invalidFiles = .empty,
        .errors = .empty,
        .filesVerified = 0,
        .expectedTotal = 0,
        .progressCallback = progressCallback,
    };

    //
    // Phase 1: Count all files to verify
    //
    if (progressCallback) |callback| {
        callback.call("Verifying database files...");
    }

    var expectedTotal: u64 = 0;

    // Count files.dat (database merkle tree)
    if (try assetStorage.fileExists(allocator, io, ".db/files.dat")) {
        expectedTotal += 1;
    }

    // Count collection files (scan metadata/ subdirectory; v6: .db/bson/collections/)
    const metadataDirs = try assetStorage.listDirs(allocator, io, ".db/bson/collections", 1000, null);
    const collections = metadataDirs.names;
    for (collections) |collectionName| {
        const collectionDir = try std.fmt.allocPrint(allocator, ".db/bson/collections/{s}", .{collectionName});

        // Count collection.dat
        if (try assetStorage.fileExists(allocator, io, try std.fmt.allocPrint(allocator, "{s}/collection.dat", .{collectionDir}))) {
            expectedTotal += 1;
        }

        // Count all other files in the collection (v6: shards/ subdir)
        const collectionFiles = try assetStorage.listFiles(allocator, io, try std.fmt.allocPrint(allocator, "{s}/shards", .{collectionDir}), 10000, null);
        expectedTotal += collectionFiles.names.len;
    }

    // Count sort index files
    if (try assetStorage.dirExists(allocator, io, ".db/bson/indexes")) {
        const sortIndexCollections = try assetStorage.listDirs(allocator, io, ".db/bson/indexes", 1000, null);
        for (sortIndexCollections.names) |collectionName| {
            const sortIndexCollectionDir = try std.fmt.allocPrint(allocator, ".db/bson/indexes/{s}", .{collectionName});
            const indexDirs = try assetStorage.listDirs(allocator, io, sortIndexCollectionDir, 1000, null);

            for (indexDirs.names) |indexDirName| {
                const indexDir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sortIndexCollectionDir, indexDirName });
                const indexFiles = try assetStorage.listFiles(allocator, io, indexDir, 10000, null);
                // Exclude build.checkpoint files
                for (indexFiles.names) |fileName| {
                    if (!std.mem.eql(u8, fileName, "build.checkpoint")) {
                        expectedTotal += 1;
                    }
                }
            }
        }
    }

    // Helper to report progress
    state.expectedTotal = expectedTotal;

    //
    // Phase 2: Verify all files
    //

    // 1. Verify files.dat (database merkle tree)
    if (try assetStorage.fileExists(allocator, io, ".db/files.dat")) {
        log.verbose("Verifying .db/files.dat");
        state.result.totalFiles += 1;
        const verifyResult = try verifySerializedFile(allocator, io, assetStorage, ".db/files.dat");
        state.result.totalSize += verifyResult.size;
        if (verifyResult.valid) {
            state.result.validFiles += 1;
        }
        else {
            try state.addError(".db/files.dat", verifyResult.@"error" orelse "Unknown error");
        }
        state.reportProgress();
    }

    // 2. For each collection, verify all files
    for (collections) |collectionName| {
        const collectionDir = try std.fmt.allocPrint(allocator, ".db/bson/collections/{s}", .{collectionName});

        // 3a. Verify collection.dat (collection merkle tree - no checksum)
        const collectionDatPath = try std.fmt.allocPrint(allocator, "{s}/collection.dat", .{collectionDir});
        if (try assetStorage.fileExists(allocator, io, collectionDatPath)) {
            log.verbose(try std.fmt.allocPrint(allocator, "Verifying {s}", .{collectionDatPath}));
            state.result.totalFiles += 1;
            const verifyResult = try verifySerializedFile(allocator, io, assetStorage, collectionDatPath);
            state.result.totalSize += verifyResult.size;
            if (verifyResult.valid) {
                state.result.validFiles += 1;
            }
            else {
                try state.addError(collectionDatPath, verifyResult.@"error" orelse "Unknown error");
            }
            state.reportProgress();
        }
        // 3b. Get all files in the collection directory (v6: shards/ subdir)
        const collectionFiles = try assetStorage.listFiles(allocator, io, try std.fmt.allocPrint(allocator, "{s}/shards", .{collectionDir}), 10000, null);
        for (collectionFiles.names) |fileName| {
            const filePath = try std.fmt.allocPrint(allocator, "{s}/shards/{s}", .{ collectionDir, fileName });
            state.result.totalFiles += 1;
            if (std.mem.endsWith(u8, fileName, ".dat")) {
                // Shard merkle tree file (no checksum)
                log.verbose(try std.fmt.allocPrint(allocator, "Verifying {s}", .{filePath}));
                const verifyResult = try verifySerializedFile(allocator, io, assetStorage, filePath);
                state.result.totalSize += verifyResult.size;
                if (verifyResult.valid) {
                    state.result.validFiles += 1;
                }
                else {
                    try state.addError(filePath, verifyResult.@"error" orelse "Unknown error");
                }
                state.reportProgress();
            }
            else {
                // Shard data file (with checksum)
                log.verbose(try std.fmt.allocPrint(allocator, "Verifying {s}", .{filePath}));
                // (Zig: the TypeScript try/catch is a labeled block whose error is caught.)
                verifyShard: {
                    const verifyResult = verifySerializedFile(allocator, io, assetStorage, filePath) catch |err| {
                        try state.addError(filePath, errors.errorMessage(err));
                        break :verifyShard;
                    };
                    state.result.totalSize += verifyResult.size;
                    if (verifyResult.valid) {
                        state.result.validFiles += 1;
                    }
                    else {
                        try state.addError(filePath, verifyResult.@"error" orelse "Unknown error");
                    }
                }
                state.reportProgress();
            }
        }
    }

    // 4. Verify sort_indexes
    if (try assetStorage.dirExists(allocator, io, ".db/bson/indexes")) {
        const sortIndexCollections = try assetStorage.listDirs(allocator, io, ".db/bson/indexes", 1000, null);

        for (sortIndexCollections.names) |collectionName| {
            const sortIndexCollectionDir = try std.fmt.allocPrint(allocator, ".db/bson/indexes/{s}", .{collectionName});
            const indexDirs = try assetStorage.listDirs(allocator, io, sortIndexCollectionDir, 1000, null);

            for (indexDirs.names) |indexDirName| {
                const indexDir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sortIndexCollectionDir, indexDirName });

                // Get all files in the index directory
                const indexFiles = try assetStorage.listFiles(allocator, io, indexDir, 10000, null);

                for (indexFiles.names) |fileName| {
                    // Skip build.checkpoint files
                    if (std.mem.eql(u8, fileName, "build.checkpoint")) {
                        continue;
                    }

                    const filePath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ indexDir, fileName });
                    state.result.totalFiles += 1;

                    // files.dat and page files (all have checksum)
                    log.verbose(try std.fmt.allocPrint(allocator, "Verifying {s}", .{filePath}));
                    // (Zig: the TypeScript try/catch is a labeled block whose error is caught.)
                    verifyIndexFile: {
                        const verifyResult = verifySerializedFile(allocator, io, assetStorage, filePath) catch |err| {
                            try state.addError(filePath, errors.errorMessage(err));
                            break :verifyIndexFile;
                        };
                        state.result.totalSize += verifyResult.size;
                        if (verifyResult.valid) {
                            state.result.validFiles += 1;
                        }
                        else {
                            try state.addError(filePath, verifyResult.@"error" orelse "Unknown error");
                        }
                    }
                    state.reportProgress();
                }
            }
        }
    }

    // Ensure totalFiles reflects the expected total
    state.result.totalFiles = expectedTotal;

    state.result.invalidFiles = state.invalidFiles.items;
    state.result.errors = state.errors.items;
    return state.result;
}
