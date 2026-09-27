const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const api = @import("api-zig");
const storage_zig = @import("storage-zig");
const bdb = @import("bdb-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const serialization_zig = @import("serialization-zig");
const task_queue_zig = @import("task-queue-zig");
const resolve_storage_credentials = @import("resolve-storage-credentials.zig");
const tree = @import("tree.zig");
const hash_cache = @import("hash-cache.zig");
const import_scanner = @import("import-scanner.zig");
const manual_import_scanner = @import("manual-import-scanner.zig");
const create_auto_import_scanner = @import("create-auto-import-scanner.zig");
const auto_import_scanner = @import("auto-import-scanner.zig");
const hash_file_worker = @import("hash-file.worker.zig");
const upload_asset_worker = @import("upload-asset.worker.zig");
const import_record_storage = @import("import-record-storage.zig");
const file_scanner = @import("file-scanner.zig");
const retry_operations = @import("retry-operations.zig");
const throttle_module = @import("third-party/lodash/throttle.zig");
const debounce_module = @import("third-party/lodash/debounce.zig");
const errors = utils.errors;
const log = &utils.log.log;
const retry = utils.retry.retry;
const retryOrLog = utils.retry_or_log.retryOrLog;
const sleep = utils.sleep.sleep;
const swallowError = utils.swallow_error.swallowError;
const path = node_utils.path;
const ensureDir = node_utils.fs.ensureDir;
const remove = node_utils.fs.remove;
const getProcessTmpDir = node_utils.fs.getProcessTmpDir;
const IDatabaseDescriptor = api.database_descriptor.IDatabaseDescriptor;
const IAutoImportSource = api.auto_import_settings.IAutoImportSource;
const acquireWriteLock = api.write_lock.acquireWriteLock;
const releaseWriteLock = api.write_lock.releaseWriteLock;
const loadDatabaseState = api.database_state.loadDatabaseState;
const IImportedAsset = api.import_assets_types.IImportedAsset;
const ISkippedImport = api.import_assets_types.ISkippedImport;
const IImportAssetsResult = api.import_assets_types.IImportAssetsResult;
const IImportRecordEntry = api.import_record.IImportRecordEntry;
const ImportSource = api.import_record.ImportSource;
const createStorage = storage_zig.storage_factory.createStorage;
const loadEncryptionKeysFromPem = @import("encryption-zig").key_utils.loadEncryptionKeysFromPem;
const IStorage = storage_zig.storage.IStorage;
const BsonDatabase = bdb.database.BsonDatabase;
const IBsonCollection = bdb.collection.IBsonCollection;
const addItem = merkle_tree_zig.merkle_tree.addItem;
const IMerkleTree = merkle_tree_zig.merkle_tree.IMerkleTree;
const BufferSet = merkle_tree_zig.buffer_set.BufferSet;
const BsonDocument = serialization_zig.bson.BsonDocument;
const BsonValue = serialization_zig.bson.BsonValue;
const TaskQueue = task_queue_zig.task_queue.TaskQueue;
const TaskStatus = task_queue_zig.types.TaskStatus;
const ITaskContext = task_queue_zig.types.ITaskContext;
const ITaskResult = task_queue_zig.types.ITaskResult;
const IJobTag = task_queue_zig.types.IJobTag;
const sendJobProgress = task_queue_zig.job_progress.sendJobProgress;
const resolveStorageCredentials = resolve_storage_credentials.resolveStorageCredentials;
const stampDatabaseModified = tree.stampDatabaseModified;
const getHashCacheDir = hash_cache.getHashCacheDir;
const HashCache = hash_cache.HashCache;
const IImportScanner = import_scanner.IImportScanner;
const IScannedImportFile = import_scanner.IScannedImportFile;
const ManualImportScanner = manual_import_scanner.ManualImportScanner;
const createAutoImportScanner = create_auto_import_scanner.createAutoImportScanner;
const SaveHashCacheOperation = create_auto_import_scanner.SaveHashCacheOperation;
const IAutoImportScannerProgress = auto_import_scanner.IAutoImportScannerProgress;
const IHashFileData = hash_file_worker.IHashFileData;
const IHashFileResult = hash_file_worker.IHashFileResult;
const IUploadAssetData = upload_asset_worker.IUploadAssetData;
const IUploadAssetResult = upload_asset_worker.IUploadAssetResult;
const IAssetDatabaseData = upload_asset_worker.IAssetDatabaseData;
const decodeAssetRecord = upload_asset_worker.decodeAssetRecord;
const encodeAssetRecord = upload_asset_worker.encodeAssetRecord;
const recordImports = import_record_storage.recordImports;
const ScannerState = file_scanner.ScannerState;
const LoadMerkleTreeOperation = retry_operations.LoadMerkleTreeOperation;
const SaveMerkleTreeOperation = retry_operations.SaveMerkleTreeOperation;
const throttle = throttle_module.throttle;
const Debounced = debounce_module.Debounced;

//
// How many import record entries pile up before they are written out.
//
// One hundred, the same as the hash cache, and for the same reason: each flush is a full
// read-modify-write of one file, so flushing per file would make a long import mostly writing.
//
pub const IMPORT_RECORD_FLUSH_SIZE = 100;

//
// How many freshly hashed files pile up before the hash cache is written out.
//
pub const CACHE_FLUSH_SIZE = 100;

//
// How many finished assets pile up before they are written to the database as one batch.
//
// Every batch pays for a full database commit, and that commit costs more as the database grows:
// measured on a Pixel 6 it went from 6.4 seconds for the first batch to 10.2 seconds by the fifth,
// against an item count that did not change. So the cost is per commit and per database size, not
// per asset, and the way to reduce it is fewer commits.
//
// A hundred was measured over a seventy minute import of a real library rather than the ten minute
// passes the earlier numbers came from: 1,416 photos taken in against 1,061 for fifty, with commit
// falling from 51% of the import to 39%. Two hundred and fifty was tried at the same time and was
// ahead for seventy minutes before stopping dead, which was put down to a commit of that many
// records holding the write lock long enough for every upload to queue behind it. That was wrong: a
// hundred stops dead in the same way, and the cause was the caught-up escape in
// shouldWriteDatabaseBatch giving every remaining photo a commit of its own. With that fixed, two
// hundred and fifty took a full import from 55 minutes to 50 and held a steady rate to the end.
//
// The cost is that a photo waits longer to appear in the gallery during a bulk backfill, and that a
// run interrupted before a batch fills loses the assets in it from the database, having already paid
// to upload and process them. That is the right trade for a first backup of a whole library, which
// is what this number is for; the scanner's caught-up escape means a phone that has finished
// backfilling still writes a photo it has just taken without waiting for the rest of a batch.
//
pub const DATABASE_BATCH_SIZE = 250;

//
// Whether the assets waiting to go into the database should be written now.
//
// A batch's worth is the usual answer, because every write pays for a full database commit whatever
// its size, and a commit rewrites every shard it touches, so it costs more as the database grows.
//
// The other answer is a run that has genuinely finished with everything: an automatic import that
// brought in a handful of photos and then went quiet has to write those few rather than hold them
// for a batch that may be hours away. That is only true when nothing is in flight as well. The
// scanner reports itself caught up the moment it has read the library to the end, which on a
// backfill happens while hundreds of the photos it handed over are still being hashed and uploaded,
// and writing on that alone gave every one of those photos a full commit to itself: measured on a
// Pixel 6 against a real library, an import ran at sixty photos a minute until the scanner finished
// its walk and then fell to four and a half a minute, one twenty-six second commit per photo.
//
pub fn shouldWriteDatabaseBatch(pendingCount: usize, scannerHasNothingLeft: bool, hasWorkInFlight: bool) bool {
    if (pendingCount == 0) {
        return false;
    }

    if (pendingCount >= DATABASE_BATCH_SIZE) {
        return true;
    }

    return scannerHasNothingLeft and !hasWorkInFlight;
}

//
// Payload for the import-assets task. Contains the paths to scan plus the configuration
// needed by downstream hash-file and upload-asset tasks.
// (The `= null` defaults let std.json parse task data that leaves the optional keys out. The options are kept as
// the raw JSON they were queued as, because the sources in them are told apart by their "type" field, which
// std.json cannot parse into a tagged union; normaliseAutoImportSettings reads them.)
//
pub const IImportAssetsData = struct {
    // Filesystem paths (files or directories) to import.
    paths: []const []const u8,

    // Identifies the target database and optional encryption key name.
    storageDescriptor: IDatabaseDescriptor,

    // Google Maps API key for reverse geocoding (optional).
    googleApiKey: ?[]const u8 = null,

    // Unique identifier for the session, used to acquire the write lock.
    sessionId: []const u8,

    // When true, files are scanned and hashed but not written to the database.
    dryRun: bool,

    // How this import runs. Absent is the default: `paths` above is walked once and the import
    // ends, which is what every manual import does.
    options: ?std.json.Value = null,

    // Names the job this task belongs to, so the import shows up in the interface's job list.
    // Automatic and manual imports both carry one; they differ only in what the row is called.
    job: ?IJobTag = null,
};

//
// One line saying what an import has done so far, for the job row in the interface.
//
// Failures are only mentioned once there are some. A run that has not failed anything should not
// have to say so, and "0 failed" reads as a warning at a glance.
//
pub fn describeImportProgress(allocator: std.mem.Allocator, imported: u64, skipped: u64, failed: u64) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    try parts.append(allocator, try std.fmt.allocPrint(allocator, "{d} imported", .{imported}));
    try parts.append(allocator, try std.fmt.allocPrint(allocator, "{d} already there", .{skipped}));
    if (failed > 0) {
        try parts.append(allocator, try std.fmt.allocPrint(allocator, "{d} failed", .{failed}));
    }
    return std.mem.join(allocator, ", ", parts.items);
}

//
// How an import runs, and what it watches when it is an automatic one.
//
pub const IImportOptions = struct {
    // Take photos from the sources below rather than walking `paths`. The import is then fed by a
    // scanner that reads those sources to the end, at the pace set below, and the run ends there.
    auto: bool,

    // The places that are watched for new media.
    sources: []const IAutoImportSource,

    //
    // Converts the options to the JSON object they are queued as (TypeScript: the object itself).
    // (No TypeScript counterpart.)
    //
    pub fn toJson(self: IImportOptions, allocator: std.mem.Allocator) !std.json.Value {
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "auto", .{ .bool = self.auto });
        try object.put(allocator, "sources", try api.auto_import_settings.autoImportSourcesToJson(allocator, self.sources));
        return .{ .object = object };
    }
};

//
// Converts what an import reports back to the JSON value returned as the task output.
// (No TypeScript counterpart: TypeScript returns the object itself. Each asset record is carried as the base64
// of its BSON serialization, as in IAssetDatabaseData.)
//
pub fn importAssetsResultToJson(allocator: std.mem.Allocator, result: IImportAssetsResult) !std.json.Value {
    var imported: std.json.Array = .init(allocator);
    for (result.imported) |importedAsset| {
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "assetId", .{ .string = importedAsset.assetId });
        try object.put(allocator, "logicalPath", .{ .string = importedAsset.logicalPath });
        try object.put(allocator, "asset", .{ .string = try encodeAssetRecord(allocator, importedAsset.asset) });
        try imported.append(.{ .object = object });
    }
    var skipped: std.json.Array = .init(allocator);
    for (result.skipped) |skippedImport| {
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "logicalPath", .{ .string = skippedImport.logicalPath });
        try object.put(allocator, "contentHash", .{ .string = skippedImport.contentHash });
        try skipped.append(.{ .object = object });
    }
    var output: std.json.ObjectMap = .empty;
    try output.put(allocator, "imported", .{ .array = imported });
    try output.put(allocator, "skipped", .{ .array = skipped });
    try output.put(allocator, "failedCount", .{ .integer = @intCast(result.failedCount) });
    return .{ .object = output };
}

//
// Converts a typed value to the JSON value it is queued or sent as, leaving out optional fields that are not set
// (as JSON.stringify leaves out undefined properties). (No TypeScript counterpart.)
//
fn toJsonValue(allocator: std.mem.Allocator, value: anytype) !std.json.Value {
    const text = try std.json.Stringify.valueAlloc(allocator, value, .{ .emit_null_optional_fields = false });
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

//
// A single pending database update gathered from a completed upload-asset task.
//
const IPendingDatabaseUpdate = struct {
    // The asset data returned by the upload-asset worker.
    assetData: IAssetDatabaseData,

    // Logical path of the file being imported (for logging).
    logicalPath: []const u8,

    // Total size of the uploaded asset + derivatives in bytes.
    totalSize: u64,

    // Pre-computed hash, kept here so it can be deleted from hashesQueuedForImport after commit.
    expectedHash: []const u8,

    // What this file's hash cache entry is filed under, so the asset id can be recorded against it
    // once the database write has actually landed.
    cacheKey: []const u8,
};

//
// `() => flushImportRecord()` passed to swallowError.
// (No TypeScript counterpart: the arrow function.)
//
const FlushImportRecordOperation = struct {
    // The import whose record is flushed.
    run_state: *ImportRun,

    //
    // Flushes the import record.
    //
    pub fn run(self: *FlushImportRecordOperation, io: std.Io) !void {
        _ = io;
        try self.run_state.flushImportRecord();
    }
};

//
// `() => scanner.release(filePath)` passed to swallowError. (No TypeScript counterpart: the arrow function.)
//
const ReleaseFileOperation = struct {
    // The import whose scanner releases the file.
    run_state: *ImportRun,

    // The file to release.
    filePath: []const u8,

    //
    // Releases the file.
    //
    pub fn run(self: *ReleaseFileOperation, io: std.Io) !void {
        try self.run_state.scanner.release(self.run_state.allocator, io, self.filePath);
    }
};

//
// `() => remove(sessionTempDir)` passed to swallowError. (No TypeScript counterpart: the arrow function.)
//
const RemoveSessionTempDirOperation = struct {
    // The directory to remove.
    dirPath: []const u8,

    //
    // Removes the directory.
    //
    pub fn run(self: *RemoveSessionTempDirOperation, io: std.Io) !void {
        try remove(io, self.dirPath);
    }
};

//
// Everything importAssetsHandler's inner functions share (TypeScript: the variables they close over).
//
// The throttled writer's timer fires on a thread of its own (see lodash/debounce.zig), and the queue runs its
// callbacks on the thread that waits for it. `loopLock` stands in for JavaScript's one thread: whatever runs the
// import's code holds it, and the import lets go of it only while it waits (for the queue, or in a sleep), which is
// where TypeScript would let a timer or a callback run.
//
const ImportRun = struct {
    // Allocates everything the run keeps (the task's arena; only used while holding loopLock).
    allocator: std.mem.Allocator,

    // Io for files, the clock and the lock.
    io: std.Io,

    // The task data.
    data: IImportAssetsData,

    // The task's context.
    context: ITaskContext,

    // Stands in for JavaScript's one thread (see above).
    loopLock: std.Io.Mutex,

    // The same outcome the messages report, gathered so a caller that cannot see the messages
    // (an orchestrator task running in a worker) can still read what happened.
    imported: std.ArrayList(IImportedAsset),

    // The files the database already held.
    skipped: std.ArrayList(ISkippedImport),

    // How many files failed.
    failedCount: u64,

    // When the run started, so a job row can say how long it has been going.
    runStartedAt: i64,

    // True once the scanner has nothing left to hand over, which is when a part-filled batch of
    // database writes should go out rather than wait for more that are not coming.
    scannerHasNothingLeft: bool,

    // What this run did, for the database's import record. Gathered as it goes and flushed in
    // batches, so a long import is a handful of writes rather than one per file.
    recordEntries: std.ArrayList(IImportRecordEntry),

    // Whether a write of the hash cache and the import record is happening right now, so two of them
    // cannot overlap.
    flushing: bool,

    // How many files have been recorded in the hash cache since it was last written out. Only used to
    // say so in the log, and to say nothing when there was nothing to write.
    pendingCacheWrites: u64,

    // Whether the user asked for this import or it arrived on its own. Recorded against every entry
    // so the Import page can say which is which.
    importSource: ImportSource,

    // Where the hash cache lives.
    hashCacheDir: []const u8,

    // The database's storage.
    storage: IStorage,

    // The database's storage without encryption, for the write lock and the state file.
    rawStorage: IStorage,

    // The BSON database.
    bsonDatabase: *BsonDatabase,

    // The metadata collection.
    metadataCollection: *IBsonCollection,

    // Every hash the database already holds, and the asset it belongs to.
    existingAssetIdsByHash: std.StringHashMapUnmanaged([]const u8),

    // The import's hash cache.
    localHashCache: HashCache,

    // What each file in flight is filed under in the hash cache, when that is not its own path.
    cacheKeysByPath: std.StringHashMapUnmanaged([]const u8),

    // Tracks hashes already queued for import in this scan to prevent duplicate uploads.
    hashesQueuedForImport: BufferSet,

    // How many files have been hashed and added to the cache.
    filesAddedToCache: u64,

    // Whether a batch is being written.
    isProcessingQueue: bool,

    // The queue the child tasks go to.
    queue: *TaskQueue,

    // The finished uploads waiting to be written to the database.
    pendingDatabaseUpdates: std.ArrayList(IPendingDatabaseUpdate),

    // Files the scan has found that have not been handed to a hash-file task yet. The scan runs far
    // faster than the hashing, so without this the whole library would be queued in seconds and every
    // other task on the machine would wait behind it.
    filesAwaitingHash: std.ArrayList(IHashFileData),

    // The index of the first file in filesAwaitingHash that has not been handed out (TypeScript: shift()).
    filesAwaitingHashHead: usize,

    // Files that have been hashed and are waiting for an upload-asset task. Held here rather than
    // queued straight away for the same reason, and drained ahead of the hash queue below.
    assetsAwaitingUpload: std.ArrayList(IUploadAssetData),

    // The index of the first upload in assetsAwaitingUpload that has not been handed out (TypeScript: shift()).
    assetsAwaitingUploadHead: usize,

    // How many hash-file and upload-asset tasks this import currently has in flight. Never allowed
    // above maxConcurrentChildTasks.
    childTasksInFlight: u32,

    // The modified stamp this run last wrote, so the next batch can tell its own writes apart from
    // somebody else.'s. Undefined until the first batch commits, which is why the first batch of a run
    // always drops its caches: it cannot know what happened before it started.
    lastModifiedAtWrittenByThisRun: ?[]const u8,

    // Throttled processor that drains pendingDatabaseUpdates in batches.
    throttledProcessQueue: Debounced,

    // Where the files come from.
    scanner: IImportScanner,

    // How many items the scanner recognised as already imported without opening them. Kept so the
    // run can report once more at the end, after the photos it pushed have finished being imported.
    skippedBeforeOpening: u64,

    // How many files the scan had reported as ignored, so one file-ignored message is sent per newly
    // ignored file (scanPaths reports a cumulative count).
    prevIgnoredCount: u64,

    //
    // Takes the loop lock.
    //
    fn lock(self: *ImportRun) void {
        self.loopLock.lockUncancelable(self.io);
    }

    //
    // Lets go of the loop lock.
    //
    fn unlock(self: *ImportRun) void {
        self.loopLock.unlock(self.io);
    }

    //
    // `await sleep(milliseconds)`: lets go of the loop lock while it waits, as JavaScript lets other work run.
    //
    fn sleepUnlocked(self: *ImportRun, milliseconds: u64) !void {
        self.unlock();
        defer self.lock();
        try sleep(self.io, milliseconds);
    }

    //
    // `new Date(timestampProvider.dateNow()).toISOString()`.
    //
    fn nowIsoString(self: *ImportRun) ![]const u8 {
        return self.context.timestampProvider.dateNow(self.io).toISOString(self.allocator);
    }

    //
    // Sends a task message made of string fields. (No TypeScript counterpart: TypeScript sends an object literal.)
    //
    fn sendStringMessage(self: *ImportRun, fields: []const [2][]const u8) !void {
        var message: std.json.ObjectMap = .empty;
        for (fields) |field| {
            try message.put(self.allocator, field[0], .{ .string = field[1] });
        }
        self.context.sendMessage(.{ .object = message });
    }

    //
    // Writes what has been gathered for the import record so far, and forgets it.
    //
    // Flushed part way through rather than only at the end, because the end used to be the only
    // place it happened: an import of two thousand photos that died at nineteen hundred wrote no
    // record at all, and an automatic import that runs until the app quits never reached the end.
    // Each flush is a full read-modify-write of one local JSON file, which is why it is every
    // hundred rather than every file. A dry run records nothing, because it changed nothing.
    //
    fn flushImportRecord(self: *ImportRun) !void {
        if (self.data.dryRun or self.recordEntries.items.len == 0) {
            return;
        }

        const entriesToWrite = self.recordEntries.items;
        self.recordEntries = .empty;
        recordImports(self.allocator, self.io, self.data.storageDescriptor.databasePath, entriesToWrite);
    }

    //
    // Records what happened to one file, flushing when enough have piled up or enough time has
    // passed.
    //
    fn recordImportOutcome(self: *ImportRun, entry: IImportRecordEntry) !void {
        try self.recordEntries.append(self.allocator, entry);
        if (self.recordEntries.items.len >= IMPORT_RECORD_FLUSH_SIZE) {
            var flushOperation: FlushImportRecordOperation = .{
                .run_state = self,
            };
            _ = swallowError(self.io, &flushOperation);
        }
    }

    //
    // Saves the hash cache once enough files have been hashed. The timer above is what covers an
    // import that stops short of the next hundred.
    //
    fn flushCacheIfDue(self: *ImportRun) void {
        if (self.filesAddedToCache % CACHE_FLUSH_SIZE != 0) {
            return;
        }

        var saveOperation: SaveHashCacheOperation = .{
            .cache = &self.localHashCache,
        };
        _ = swallowError(self.io, &saveOperation);
    }

    //
    // Whether the import still has a file it has not finished with.
    //
    // That is a task running, a file waiting to be hashed, or an asset waiting to be uploaded. The
    // scanner being caught up says only that it has nothing left to hand over, which on a backfill
    // happens while hundreds of the photos it already handed over are still being worked on.
    //
    fn hasWorkInFlight(self: *ImportRun) bool {
        return self.childTasksInFlight > 0 or self.filesAwaitingHashCount() > 0 or self.assetsAwaitingUploadCount() > 0;
    }

    //
    // `filesAwaitingHash.length`. (No TypeScript counterpart.)
    //
    fn filesAwaitingHashCount(self: *ImportRun) usize {
        return self.filesAwaitingHash.items.len - self.filesAwaitingHashHead;
    }

    //
    // `assetsAwaitingUpload.length`. (No TypeScript counterpart.)
    //
    fn assetsAwaitingUploadCount(self: *ImportRun) usize {
        return self.assetsAwaitingUpload.items.len - self.assetsAwaitingUploadHead;
    }

    //
    // What one file's hash cache entry is filed under: the identity the scanner gave it, or its own
    // path when it did not give one.
    //
    fn cacheKeyOfPath(self: *ImportRun, filePath: []const u8) []const u8 {
        return self.cacheKeysByPath.get(filePath) orelse filePath;
    }

    //
    // Tells the scanner the import has finished with a file, whatever it made of it.
    //
    // For a photo library item this is what deletes the temporary copy that had to be made to read
    // it. Doing it here rather than at the end of the run is what keeps a long automatic import from
    // filling the sandbox with copies of every photo it has ever looked at.
    //
    fn releaseFile(self: *ImportRun, filePath: []const u8) void {
        _ = self.cacheKeysByPath.remove(filePath);
        // Started rather than waited for. This runs inside the completion callback of a child task,
        // and anything awaited there lets the end of the run arrive before the callback has finished
        // recording what the child did: an upload whose database write had not been queued yet was
        // dropped on the floor. Deleting a temporary copy is not something the import waits on, and
        // a failure to delete one must not fail the import, which is what the swallow is for.
        var releaseOperation: ReleaseFileOperation = .{
            .run_state = self,
            .filePath = filePath,
        };
        _ = swallowError(self.io, &releaseOperation);
    }

    //
    // Hands as many waiting files to the queue as the concurrency limit allows.
    //
    // Uploads go before hashes, because an upload finishes a file that has already been paid for:
    // draining them first keeps the number of half-imported files down and gets assets into the
    // database sooner. Called once per completion, so a slot is refilled the moment one frees.
    //
    fn dispatchChildTasks(self: *ImportRun) !void {
        if (self.context.isCancelled()) {
            // Nothing more goes to the queue once the import has been cancelled. What is already
            // waiting is abandoned, and awaitAllTasks below stops as soon as the running ones settle.
            return;
        }

        while (self.childTasksInFlight < self.context.maxConcurrentChildTasks) {
            if (self.assetsAwaitingUploadCount() > 0) {
                const uploadData = self.assetsAwaitingUpload.items[self.assetsAwaitingUploadHead];
                self.assetsAwaitingUploadHead += 1;
                self.childTasksInFlight += 1;
                _ = try self.queue.addTask("upload-asset", try toJsonValue(self.allocator, uploadData), null, null);
                continue;
            }

            if (self.filesAwaitingHashCount() == 0) {
                return;
            }
            const hashData = self.filesAwaitingHash.items[self.filesAwaitingHashHead];
            self.filesAwaitingHashHead += 1;

            self.childTasksInFlight += 1;
            _ = try self.queue.addTask("hash-file", try toJsonValue(self.allocator, hashData), null, null);
        }
    }

    //
    // Writes a batch of completed uploads to the Merkle tree and BSON database under the write lock.
    // Returns true on success, false if the write lock could not be acquired.
    //
    fn processPendingDatabaseUpdates(self: *ImportRun, itemsToProcess: []const IPendingDatabaseUpdate) !bool {
        const allocator = self.allocator;
        const io = self.io;

        if (itemsToProcess.len == 0) {
            return true;
        }

        if (!try acquireWriteLock(allocator, io, self.rawStorage, self.data.sessionId, 1)) {
            return false;
        }

        // The cached shards and index pages are dropped only when somebody else has written to the
        // database since this run last did.
        //
        // Dropping them unconditionally, which is what this used to do, makes every batch read back
        // what it already had: about one and three quarter reads per record, against none when the
        // caches are kept, and those reads grow with the database because an index page holds every
        // record in it. On a phone each one crosses the embedded engine bridge.
        //
        // The check is the database.'s own modified stamp, which every writer updates under this
        // same lock, compared against what this run wrote when it last held the lock. It is read here
        // rather than before the lock because a database read outside the lock says nothing: another
        // writer can change it in the moment between.
        const stateBeforeWriting = try loadDatabaseState(allocator, io, self.rawStorage);
        const lastModifiedAt: ?[]const u8 = if (stateBeforeWriting) |state| state.lastModifiedAt else null;
        const databaseChangedElsewhere = !optionalStringsEqual(lastModifiedAt, self.lastModifiedAtWrittenByThisRun);
        if (databaseChangedElsewhere) {
            try self.bsonDatabase.flush();
        }

        log.verbose(try std.fmt.allocPrint(allocator, "Have write lock, processing {d} items.", .{itemsToProcess.len}));

        const writeResult = self.writeLockedBatch(itemsToProcess);
        try releaseWriteLock(allocator, io, self.rawStorage);
        log.verbose("Released write lock.");
        return writeResult;
    }

    //
    // The body of processPendingDatabaseUpdates' try block, run holding the write lock.
    // (No TypeScript counterpart: the try block is written inline; Zig needs it as a function to release the lock
    // in the finally block whether it failed or not.)
    //
    fn writeLockedBatch(self: *ImportRun, itemsToProcess: []const IPendingDatabaseUpdate) !bool {
        const allocator = self.allocator;
        const io = self.io;

        var loadOperation: LoadMerkleTreeOperation("() => loadMerkleTree(storage)") = .{
            .allocator = allocator,
            .storage = self.storage,
        };
        var merkleTree: IMerkleTree = try retry(io, &loadOperation, 3, 1_000, 2, 30_000, null) orelse {
            return errors.throwError("Failed to load merkle tree.", .{});
        };

        for (itemsToProcess) |item| {
            const assetData = item.assetData;
            const logicalPath = item.logicalPath;

            merkleTree = try addItem(allocator, &merkleTree, .{
                .name = assetData.assetPath,
                .hash = try hexToBuffer(allocator, assetData.assetHash),
                .length = assetData.assetLength,
                .lastModified = assetData.assetLastModified,
            });

            if (assetData.thumbPath) |thumbPath| {
                merkleTree = try addItem(allocator, &merkleTree, .{
                    .name = thumbPath,
                    .hash = try hexToBuffer(allocator, assetData.thumbHash.?),
                    .length = assetData.thumbLength.?,
                    .lastModified = assetData.thumbLastModified.?,
                });
            }

            if (assetData.displayPath) |displayPath| {
                merkleTree = try addItem(allocator, &merkleTree, .{
                    .name = displayPath,
                    .hash = try hexToBuffer(allocator, assetData.displayHash.?),
                    .length = assetData.displayLength.?,
                    .lastModified = assetData.displayLastModified.?,
                });
            }

            const assetRecord = try decodeAssetRecord(allocator, assetData.assetRecord);
            if (!self.data.dryRun) {
                var insertedRecord = try decodeAssetRecord(allocator, assetData.assetRecord);
                try self.metadataCollection.insertOne(io, &insertedRecord, null);

                // Recorded only here, on the far side of the write, so an id in the cache always
                // means the asset really is in the database rather than that an import once
                // intended to put it there. The next run reads this and skips the file without
                // asking the database. A dry run records nothing, because it wrote nothing: an id
                // from a dry run would make the next real import skip a file it never took in.
                _ = try self.localHashCache.setAssetId(item.cacheKey, assetData.assetId);
            }

            log.verbose(try std.fmt.allocPrint(allocator, "Added file \"{s}\" to the database with ID \"{s}\".", .{ logicalPath, assetData.assetId }));
            const micro = recordMicro(assetRecord);
            try self.imported.append(allocator, .{
                .assetId = assetData.assetId,
                .logicalPath = logicalPath,
                .asset = assetRecord,
            });
            try self.recordImportOutcome(.{
                .assetId = assetData.assetId,
                .logicalPath = logicalPath,
                .outcome = .imported,
                .importedAt = try self.nowIsoString(),
                .source = self.importSource,
                .micro = micro,
            });

            // The database is named on every arrival, because the gallery has to know which one
            // the photo landed in: automatic import writes to the default database, which is not
            // necessarily the one on screen, and an arrival in another one is not that gallery's
            // to show.
            var arrival: std.json.ObjectMap = .empty;
            try arrival.put(allocator, "type", .{ .string = "import-success" });
            try arrival.put(allocator, "databasePath", .{ .string = self.data.storageDescriptor.databasePath });
            try arrival.put(allocator, "assetId", .{ .string = assetData.assetId });
            try arrival.put(allocator, "logicalPath", .{ .string = logicalPath });
            try arrival.put(allocator, "source", .{ .string = @tagName(self.importSource) });
            if (micro) |microText| {
                try arrival.put(allocator, "micro", .{ .string = microText });
            }
            try arrival.put(allocator, "asset", .{ .string = assetData.assetRecord });
            self.context.sendMessage(.{ .object = arrival });
        }

        var databaseMetadata = merkleTree.databaseMetadata orelse BsonDocument.empty;
        if (merkleTree.databaseMetadata == null) {
            try databaseMetadata.put(allocator, "filesImported", .{ .number = 0 });
        }
        const filesImported = databaseMetadata.get("filesImported") orelse BsonValue.undefined;
        try databaseMetadata.put(allocator, "filesImported", .{ .number = jsNumber(filesImported) + @as(f64, @floatFromInt(itemsToProcess.len)) });
        merkleTree.databaseMetadata = databaseMetadata;

        if (!self.data.dryRun) {
            var saveOperation: SaveMerkleTreeOperation("() => saveMerkleTree(merkleTree, storage)") = .{
                .allocator = allocator,
                .merkleTree = &merkleTree,
                .storage = self.storage,
            };
            try retry(io, &saveOperation, 3, 1_000, 2, 30_000, null);

            try self.bsonDatabase.commit(io);

            try stampDatabaseModified(allocator, io, self.storage, self.rawStorage);
        }

        return true;
    }

    //
    // The body of the throttled processor (TypeScript: the async arrow function passed to throttle).
    //
    fn processQueue(self: *ImportRun) !void {
        if (self.isProcessingQueue or self.pendingDatabaseUpdates.items.len == 0) {
            return;
        }

        // Hold back until enough assets have piled up to be worth a batch, unless the scan has run
        // dry, in which case what is waiting is all there is ever going to be.
        //
        // The throttle above coalesces completions that arrive within a second of each other, which
        // does nothing at all on a phone: an item there takes over ten seconds to reach this point,
        // so every item got a batch to itself. Measured on a Pixel 6, that was 37 batches for 42
        // photos, and each batch pays for a full database commit whatever its size. Committing is
        // 47% of the write stage and the write stage is half the import.
        //
        // The end of the run is covered without this: the final drain below calls
        // processPendingDatabaseUpdates directly rather than going through here, so nothing is left
        // stranded in a part-filled batch. The rule itself is in shouldWriteDatabaseBatch.
        if (!shouldWriteDatabaseBatch(self.pendingDatabaseUpdates.items.len, self.scannerHasNothingLeft, self.hasWorkInFlight())) {
            return;
        }

        self.isProcessingQueue = true;
        defer self.isProcessingQueue = false;

        const itemsToProcess = self.pendingDatabaseUpdates.items;
        self.pendingDatabaseUpdates = .empty;

        const processed = try self.processPendingDatabaseUpdates(itemsToProcess);
        if (!processed) {
            try self.pendingDatabaseUpdates.appendSlice(self.allocator, itemsToProcess);
        }
        else {
            for (itemsToProcess) |item| {
                _ = try self.hashesQueuedForImport.delete(item.expectedHash);
            }
        }
    }

    //
    // The throttled function (TypeScript: the async arrow function passed to throttle, with its catch).
    // Runs holding the loop lock: on the timer thread, or from flush.
    //
    fn processQueueThrottled(context: *anyopaque) void {
        const self: *ImportRun = @ptrCast(@alignCast(context));
        self.processQueue() catch |err| {
            log.exception("Error processing pending database updates", err);
        };
    }

    //
    // Subscribe to task completions for hash-file and upload-asset tasks that belong
    // to this import session. The source filter prevents concurrent imports from
    // processing each other's completions.
    // (TypeScript: the arrow function passed to queue.onTaskComplete. Runs on the thread waiting in awaitAllTasks,
    // holding the loop lock.)
    //
    fn onTaskComplete(context: ?*anyopaque, taskResult: ITaskResult) anyerror!void {
        const self: *ImportRun = @ptrCast(@alignCast(context.?));
        self.lock();
        defer self.unlock();

        const outcome = self.recordChildTaskOutcome(taskResult);

        // In a finally so a slot is released even when handling the outcome threw. A slot leaked
        // here would be leaked for the life of the import, and enough of them would stop the
        // import dead with files still waiting and nothing running.
        self.childTasksInFlight -= 1;
        try self.dispatchChildTasks();
        return outcome;
    }

    //
    // Records what one finished child task did: caches the hash, queues the upload of a file that is
    // new, or counts the failure.
    //
    fn recordChildTaskOutcome(self: *ImportRun, taskResult: ITaskResult) !void {
        const allocator = self.allocator;

        if (self.context.isCancelled()) {
            return;
        }

        if (std.mem.eql(u8, taskResult.type, "hash-file")) {
            const hashFileData = try std.json.parseFromValueLeaky(IHashFileData, allocator, taskResult.inputs, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
            if (taskResult.status == TaskStatus.Succeeded) {
                const hashResult = try std.json.parseFromValueLeaky(IHashFileResult, allocator, taskResult.outputs orelse .null, .{
                    .ignore_unknown_fields = true,
                    .allocate = .alloc_always,
                });
                const hashBuffer = try hexToBuffer(allocator, hashResult.hash);

                if (!hashResult.hashFromCache) {
                    if (hashFileData.cacheIdentity) |cacheIdentity| {
                        // Filed under the item's source id, and against the size and created time the
                        // photo library reported, not the temporary copy's own path and modified time:
                        // the copy is deleted the moment the import finishes and its modified time was
                        // minted by the copy, so an entry describing it would never match anything again.
                        try self.localHashCache.addSourceHash(cacheIdentity.key, .{
                            .hash = hashBuffer,
                            .lastModified = cacheIdentity.lastModified,
                            .length = cacheIdentity.length,
                        });
                    }
                    else {
                        try self.localHashCache.addHash(hashFileData.filePath, .{
                            .hash = hashBuffer,
                            .lastModified = hashFileData.fileStat.lastModified,
                            .length = hashFileData.fileStat.length,
                        });
                    }
                    self.filesAddedToCache += 1;
                    self.pendingCacheWrites += 1;
                    self.flushCacheIfDue();
                }

                // Whether the database already holds this hash, answered from a map built once when
                // the run started.
                //
                // Asked synchronously, and that is not incidental. This is a task completion
                // callback, and anything awaited here lets the end of the run arrive before the
                // callback has finished recording what the child did: an upload whose database write
                // had not been queued yet is dropped on the floor. The comment further down says the
                // same thing about the upload branch, and it was learned the same way.
                //
                // The query this replaces ran inside the hash-file task, which built its own
                // database object per file, so the collection's sort index cache was fresh every
                // time and the whole hash index was loaded again to answer one question. That
                // measured 69% of an import on a Pixel 6.
                const existingAssetId = self.existingAssetIdsByHash.get(hashResult.hash);
                const filesAlreadyAdded = existingAssetId != null;

                // The database already holds this file, and now the cache says so too, which is what
                // lets the next run skip it without asking the database at all.
                if (existingAssetId) |assetId| {
                    _ = try self.localHashCache.setAssetId(self.cacheKeyOfPath(hashFileData.filePath), assetId);
                }

                if (filesAlreadyAdded) {
                    try self.skipped.append(allocator, .{
                        .logicalPath = hashFileData.logicalPath,
                        .contentHash = hashResult.hash,
                    });
                    try self.recordImportOutcome(.{
                        .assetId = hashFileData.assetId,
                        .logicalPath = hashFileData.logicalPath,
                        .outcome = .skipped,
                        .importedAt = try self.nowIsoString(),
                        .source = self.importSource,
                    });
                    try self.sendStringMessage(&.{
                        .{ "type", "import-skipped" },
                        .{ "assetId", hashFileData.assetId },
                        .{ "logicalPath", hashFileData.logicalPath },
                    });
                    // Nothing more will read this file.
                    self.releaseFile(hashFileData.filePath);
                }
                else {
                    if (try self.hashesQueuedForImport.has(hashBuffer)) {
                        log.verbose("File \"\" is a duplicate in this scan, skipping.");
                        self.releaseFile(hashFileData.filePath);
                    }
                    else {
                        _ = try self.hashesQueuedForImport.add(hashBuffer);
                        try self.assetsAwaitingUpload.append(allocator, .{
                            .filePath = hashFileData.filePath,
                            .fileStat = hashFileData.fileStat,
                            .contentType = hashFileData.contentType,
                            .storageDescriptor = hashFileData.storageDescriptor,
                            .logicalPath = hashFileData.logicalPath,
                            .labels = hashFileData.labels,
                            .googleApiKey = hashFileData.googleApiKey,
                            .sessionId = hashFileData.sessionId,
                            .dryRun = hashFileData.dryRun,
                            .assetId = hashFileData.assetId,
                            .expectedHash = hashResult.hash,
                        });
                    }
                }
            }
            else if (taskResult.status == TaskStatus.Failed) {
                log.@"error"(try std.fmt.allocPrint(allocator, "Failed to hash file \"{s}\": {s}", .{ hashFileData.logicalPath, taskResult.errorMessage orelse "undefined" }));
                self.failedCount += 1;
                try self.recordImportOutcome(.{
                    .assetId = hashFileData.assetId,
                    .logicalPath = hashFileData.logicalPath,
                    .outcome = .failed,
                    .importedAt = try self.nowIsoString(),
                    .source = self.importSource,
                });
                try self.sendStringMessage(&.{
                    .{ "type", "import-failed" },
                    .{ "assetId", hashFileData.assetId },
                    .{ "logicalPath", hashFileData.logicalPath },
                });
                self.releaseFile(hashFileData.filePath);
            }
        }
        else if (std.mem.eql(u8, taskResult.type, "upload-asset")) {
            const uploadData = try std.json.parseFromValueLeaky(IUploadAssetData, allocator, taskResult.inputs, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
            if (taskResult.status == TaskStatus.Succeeded) {
                const outputs = taskResult.outputs orelse .null;
                if (outputs == .null) {
                    return errors.throwError("undefined is not an object (evaluating 'uploadResult.assetData')", .{});
                }
                const uploadResult = try std.json.parseFromValueLeaky(IUploadAssetResult, allocator, outputs, .{
                    .ignore_unknown_fields = true,
                    .allocate = .alloc_always,
                });

                try self.pendingDatabaseUpdates.append(allocator, .{
                    .assetData = uploadResult.assetData,
                    .logicalPath = uploadData.logicalPath,
                    .totalSize = uploadResult.totalSize,
                    .expectedHash = try hexToBuffer(allocator, uploadData.expectedHash),
                    .cacheKey = self.cacheKeyOfPath(uploadData.filePath),
                });
                // Queued and scheduled with nothing awaited in between, so the update is on the list
                // before this callback yields. An await here would let the end of the run look at an
                // empty list and finish without writing this asset to the database at all.
                self.throttledProcessQueue.call();

                // The upload has read the file and written what it needs into storage, and the
                // database write works from what it returned, so the local copy is finished with
                // even though the record has not landed yet.
                self.releaseFile(uploadData.filePath);
            }
            else if (taskResult.status == TaskStatus.Failed) {
                log.@"error"(try std.fmt.allocPrint(allocator, "Failed to upload file \"{s}\": {s}", .{ uploadData.logicalPath, taskResult.errorMessage orelse "undefined" }));
                self.failedCount += 1;
                try self.recordImportOutcome(.{
                    .assetId = uploadData.assetId,
                    .logicalPath = uploadData.logicalPath,
                    .outcome = .failed,
                    .importedAt = try self.nowIsoString(),
                    .source = self.importSource,
                });
                try self.sendStringMessage(&.{
                    .{ "type", "import-failed" },
                    .{ "assetId", uploadData.assetId },
                    .{ "logicalPath", uploadData.logicalPath },
                });
                self.releaseFile(uploadData.filePath);
            }
        }
    }

    //
    // Saves what has been learnt when the scanner says it is caught up, and reports progress.
    // (Runs holding the loop lock, on the thread running the scan.)
    //
    fn onScannerProgress(context: ?*anyopaque, scannerProgress: IAutoImportScannerProgress) void {
        const self: *ImportRun = @ptrCast(@alignCast(context.?));
        self.skippedBeforeOpening = scannerProgress.skippedAsAlreadyImported;

        // Save the hash cache and the import record once there is nothing left to import.
        //
        // Saving on a count alone only works for an import that ends, and this one may not:
        // automatic import brings in a handful of photos and then waits, so without this a phone
        // that imported five photos and stayed running saved none of those entries, and the next run
        // hashed and copied the same photos again. Being caught up is the moment that matters, and
        // the moment it costs nothing: nothing more is coming, and hours may pass before anything is.
        //
        // It is deliberately not a timer. This task runs inside an embedded JavaScript engine on a
        // phone, where a timer fires outside the task's own control flow, can overlap the task's own
        // writes, and outlives the task if a clear is ever missed. This runs on the scanner's own
        // loop instead. Both writes cost nothing when nothing has changed, so repeating it on every
        // idle tick is free.
        self.scannerHasNothingLeft = scannerProgress.caughtUp;

        if (scannerProgress.caughtUp) {
            // Nudged from here because the escape above waits for the work in flight to finish, and
            // the last of that work finishes inside a completion callback that has already asked the
            // queue whether it should write. Without this an automatic import that brought in a
            // handful of photos and then went quiet would leave them in a part-filled batch, unwritten
            // until something else happened to arrive.
            self.throttledProcessQueue.call();
        }

        if (scannerProgress.caughtUp and !self.flushing) {
            self.flushing = true;
            var flushOperation: CaughtUpFlushOperation = .{
                .run_state = self,
            };
            _ = swallowError(self.io, &flushOperation);
        }

        self.sendImportProgress(scannerProgress.currentItem) catch |err| {
            log.exception("Failed to send import progress", err);
        };
    }

    //
    // Reports what the run has done so far, so the panel on the Import page can show it without
    // waiting for the run to end. Sent by both kinds of import, because there is nothing about it
    // that is particular to one of them.
    //
    // The counters come from this task, because it is the one that knows them: it is what sends
    // import-success, import-skipped and import-failed per file.
    //
    fn sendImportProgress(self: *ImportRun, currentItem: ?[]const u8) !void {
        const allocator = self.allocator;
        const importedCount: u64 = self.imported.items.len;
        const skippedCount: u64 = self.skipped.items.len;
        var message: std.json.ObjectMap = .empty;
        try message.put(allocator, "type", .{ .string = "import-progress" });
        try message.put(allocator, "seen", .{ .integer = @intCast(importedCount + skippedCount + self.failedCount + self.skippedBeforeOpening) });
        try message.put(allocator, "imported", .{ .integer = @intCast(importedCount) });
        // What the import recognised, plus what the scanner recognised before it went to the
        // trouble of copying the photo out of the library at all.
        try message.put(allocator, "skipped", .{ .integer = @intCast(skippedCount + self.skippedBeforeOpening) });
        try message.put(allocator, "skippedBeforeOpening", .{ .integer = @intCast(self.skippedBeforeOpening) });
        try message.put(allocator, "failed", .{ .integer = @intCast(self.failedCount) });
        if (currentItem) |item| {
            try message.put(allocator, "currentItem", .{ .string = item });
        }
        self.context.sendMessage(.{ .object = message });

        // The same counters again, as the job the interface lists and can cancel. Indeterminate,
        // because the scanner streams: how many files there are to import is not known until the
        // run that imports them has finished.
        try sendJobProgress(allocator, self.context, self.data.job, self.runStartedAt, try describeImportProgress(allocator, importedCount, skippedCount + self.skippedBeforeOpening, self.failedCount));
    }

    //
    // Queues one file the scanner found (TypeScript: the `async (result) => { ... }` arrow function passed to
    // scanner.scan). Runs holding the loop lock.
    //
    fn visitFile(context: ?*anyopaque, result: IScannedImportFile) anyerror!void {
        const self: *ImportRun = @ptrCast(@alignCast(context.?));
        const allocator = self.allocator;
        if (self.context.isCancelled()) {
            return;
        }

        if (result.cacheIdentity) |cacheIdentity| {
            try self.cacheKeysByPath.put(allocator, try allocator.dupe(u8, result.filePath), try allocator.dupe(u8, cacheIdentity.key));
        }

        try self.filesAwaitingHash.append(allocator, .{
            .filePath = try allocator.dupe(u8, result.filePath),
            .fileStat = .{
                .contentType = if (result.fileStat.contentType) |contentType| try allocator.dupe(u8, contentType) else null,
                .length = result.fileStat.length,
                .lastModified = result.fileStat.lastModified,
            },
            .contentType = try allocator.dupe(u8, result.contentType),
            .storageDescriptor = self.data.storageDescriptor,
            .hashCacheDir = self.hashCacheDir,
            .cacheIdentity = if (result.cacheIdentity) |cacheIdentity| .{
                .key = try allocator.dupe(u8, cacheIdentity.key),
                .length = cacheIdentity.length,
                .lastModified = cacheIdentity.lastModified,
            } else null,
            .logicalPath = try allocator.dupe(u8, result.logicalPath),
            .labels = result.labels,
            .googleApiKey = self.data.googleApiKey,
            .sessionId = self.data.sessionId,
            .dryRun = self.data.dryRun,
            .assetId = try self.context.uuidGenerator.generate(allocator, self.io),
        });
        try self.dispatchChildTasks();
    }

    //
    // Reports the scan's progress (TypeScript: the `(currentlyScanning, state) => { ... }` arrow function passed
    // to scanner.scan). Runs holding the loop lock.
    //
    fn onScanProgress(context: ?*anyopaque, currentlyScanning: ?[]const u8, state: *const ScannerState) void {
        const self: *ImportRun = @ptrCast(@alignCast(context.?));
        self.reportScanProgress(currentlyScanning, state) catch |err| {
            log.exception("Failed to report scan progress", err);
        };
    }

    //
    // The body of onScanProgress. (No TypeScript counterpart.)
    //
    fn reportScanProgress(self: *ImportRun, currentlyScanning: ?[]const u8, state: *const ScannerState) !void {
        const allocator = self.allocator;
        const newIgnored = state.numFilesIgnored - self.prevIgnoredCount;
        self.prevIgnoredCount = state.numFilesIgnored;
        if (newIgnored > 0) {
            var message: std.json.ObjectMap = .empty;
            try message.put(allocator, "type", .{ .string = "file-ignored" });
            try message.put(allocator, "count", .{ .integer = @intCast(newIgnored) });
            self.context.sendMessage(.{ .object = message });
        }
        if (currentlyScanning) |scanning| {
            if (scanning.len > 0) {
                try self.sendStringMessage(&.{
                    .{ "type", "scan-progress" },
                    .{ "currentPath", scanning },
                });
            }
        }

        // The same progress a watching run reports. Nothing about it is particular to one
        // kind of import, so the panel shows either without knowing which it is watching.
        try self.sendImportProgress(currentlyScanning);
    }
};

//
// The async arrow function onScannerProgress passes to swallowError when the scanner is caught up.
// (No TypeScript counterpart: the arrow function.)
//
const CaughtUpFlushOperation = struct {
    // The import whose hash cache and import record are written.
    run_state: *ImportRun,

    //
    // Writes the hash cache and the import record.
    //
    pub fn run(self: *CaughtUpFlushOperation, io: std.Io) !void {
        const run_state = self.run_state;
        defer run_state.flushing = false;
        const written = run_state.pendingCacheWrites;
        run_state.pendingCacheWrites = 0;
        try run_state.localHashCache.save(io);
        try run_state.flushImportRecord();
        if (written > 0) {
            // Said out loud because an entry that is only in memory does nothing for the
            // next run: it would hash and copy the same file again.
            log.info(try std.fmt.allocPrint(run_state.allocator, "Import saved {d} hash cache entries.", .{written}));
        }
    }
};

//
// `a === b` for two optional strings (undefined equals only undefined). (No TypeScript counterpart.)
//
fn optionalStringsEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) {
        return left == null and right == null;
    }
    return std.mem.eql(u8, left.?, right.?);
}

//
// `Buffer.from(hex, "hex")`. (No TypeScript counterpart.)
//
fn hexToBuffer(allocator: std.mem.Allocator, hex: []const u8) ![]const u8 {
    const buffer = try allocator.alloc(u8, hex.len / 2);
    return std.fmt.hexToBytes(buffer, hex);
}

//
// A JavaScript value used as a number in `+=` (undefined is NaN). (No TypeScript counterpart.)
//
fn jsNumber(value: BsonValue) f64 {
    return switch (value) {
        .number, .double => |number| number,
        .int32 => |number| @floatFromInt(number),
        .int64 => |number| @floatFromInt(number),
        .null => 0,
        .boolean => |boolean| if (boolean) 1 else 0,
        else => std.math.nan(f64),
    };
}

//
// `assetRecord.micro`, or undefined when the record has none. (No TypeScript counterpart.)
//
fn recordMicro(assetRecord: BsonDocument) ?[]const u8 {
    const micro = assetRecord.get("micro") orelse {
        return null;
    };
    return switch (micro) {
        .string => |text| text,
        else => null,
    };
}

//
// Orchestrator handler for the import-assets task. Scans filesystem paths, hashes the files it finds
// (no more than maxConcurrentChildTasks of them at a time), deduplicates by content hash, uploads the ones
// that are new, and batches all database writes under a single throttled write lock per batch.
// (Zig: the task data and output are JSON values holding IImportAssetsData and IImportAssetsResult.)
//
pub fn importAssetsHandler(allocator: std.mem.Allocator, io: std.Io, taskData: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    const data = try std.json.parseFromValueLeaky(IImportAssetsData, allocator, taskData, .{ .ignore_unknown_fields = true });
    const uuidGenerator = context.uuidGenerator;
    const maxConcurrentChildTasks = context.maxConcurrentChildTasks;

    if (maxConcurrentChildTasks < 1) {
        return errors.throwError("import-assets needs maxConcurrentChildTasks to be a whole number of at least 1, got {d}.", .{maxConcurrentChildTasks});
    }

    const isAuto = isAutoImport(data.options);

    const hashCacheDir = try getHashCacheDir(allocator, data.storageDescriptor.databasePath);

    const credentials = try resolveStorageCredentials(allocator, io, data.storageDescriptor.databasePath, data.storageDescriptor.encryptionKey, null);
    const loadedKeys = try loadEncryptionKeysFromPem(allocator, credentials.encryptionKeyPems);
    const created = try createStorage(allocator, io, data.storageDescriptor.databasePath, credentials.s3Config, loadedKeys.options);

    // Not ported: countedStorage, the Proxy that counts what the database writes (its counters are never read).
    const bsonDatabase = try BsonDatabase.init(allocator, created.storage, ".db/bson", uuidGenerator, context.timestampProvider);
    const metadataCollection = try bsonDatabase.collection("metadata");

    const run = try allocator.create(ImportRun);
    run.* = .{
        .allocator = allocator,
        .io = io,
        .data = data,
        .context = context,
        .loopLock = .init,
        .imported = .empty,
        .skipped = .empty,
        .failedCount = 0,
        .runStartedAt = std.Io.Clock.real.now(io).toMilliseconds(),
        .scannerHasNothingLeft = false,
        .recordEntries = .empty,
        .flushing = false,
        .pendingCacheWrites = 0,
        .importSource = if (isAuto) .automatic else .manual,
        .hashCacheDir = hashCacheDir,
        .storage = created.storage,
        .rawStorage = created.rawStorage,
        .bsonDatabase = bsonDatabase,
        .metadataCollection = metadataCollection,
        .existingAssetIdsByHash = .empty,
        .localHashCache = try HashCache.init(hashCacheDir, false),
        .cacheKeysByPath = .empty,
        .hashesQueuedForImport = BufferSet.init(allocator),
        .filesAddedToCache = 0,
        .isProcessingQueue = false,
        .queue = undefined,
        .pendingDatabaseUpdates = .empty,
        .filesAwaitingHash = .empty,
        .filesAwaitingHashHead = 0,
        .assetsAwaitingUpload = .empty,
        .assetsAwaitingUploadHead = 0,
        .childTasksInFlight = 0,
        .lastModifiedAtWrittenByThisRun = null,
        .throttledProcessQueue = undefined,
        .scanner = undefined,
        .skippedBeforeOpening = 0,
        .prevIgnoredCount = 0,
    };
    defer run.localHashCache.deinit();

    // Every hash the database already holds, and the asset it belongs to.
    //
    // Built once, here, rather than asked per file. The question is "have I already got this photo",
    // and it used to be answered by an index query inside every hash-file task, each of which built
    // its own database object so the collection's sort index cache never survived to be used twice.
    // On a Pixel 6 that was 69% of an import, and it grew as the database did: 373 milliseconds a
    // file early in a run, 4.3 seconds a file by the end of one.
    //
    // A snapshot taken at the start is enough, because anything added during the run is added to
    // hashesQueuedForImport below, which is checked as well.
    //
    try loadExistingHashes(run);

    _ = try run.localHashCache.load(io);

    // Trailing-edge throttled so that multiple completions that arrive close together
    // are coalesced into a single write-lock acquisition.
    run.throttledProcessQueue = throttle(io, .{
        .context = run,
        .function = ImportRun.processQueueThrottled,
    }, 1000, .{
        .leading = false,
        .trailing = true,
    }, &run.loopLock);
    try run.throttledProcessQueue.start();
    defer run.throttledProcessQueue.deinit();

    run.lock();
    defer run.unlock();

    run.queue = try TaskQueue.init(allocator, io, context.uuidGenerator, data.sessionId);
    defer run.queue.deinit();

    //
    // Subscribe to task completions for hash-file and upload-asset tasks that belong
    // to this import session. The source filter prevents concurrent imports from
    // processing each other's completions.
    //
    _ = try run.queue.onTaskComplete(.{
        .context = run,
        .function = ImportRun.onTaskComplete,
    });

    const sessionTempDir = try path.join(allocator, &.{ try getProcessTmpDir(allocator, io), "photosphere", try uuidGenerator.generate(allocator, io) });
    try ensureDir(io, sessionTempDir);

    // Where the files come from. The orchestrator below does not know which of the two it has: it
    // asks for files and takes what it is given. The only difference it can see is that a manual
    // scan returns when the paths have been walked, and an automatic one does not return until the
    // task is cancelled.
    if (isAuto) {
        const autoScanner = try createAutoImportScanner(allocator, .{
            .importOptions = data.options.?,
            .storage = created.storage,
            .metadataCollection = metadataCollection,
            .localHashCache = &run.localHashCache,
            .sessionTempDir = sessionTempDir,
            .context = context,
            .onProgress = .{
                .context = run,
                .function = ImportRun.onScannerProgress,
            },
        });
        run.scanner = autoScanner.importScanner();
    }
    else {
        const manualScanner = try allocator.create(ManualImportScanner);
        manualScanner.* = ManualImportScanner.init(data.paths, .{
            .ignorePatterns = &.{".db"},
        }, sessionTempDir, uuidGenerator);
        run.scanner = manualScanner.importScanner();
    }

    defer {
        run.queue.shutdown();
        var removeOperation: RemoveSessionTempDirOperation = .{
            .dirPath = sessionTempDir,
        };
        _ = swallowError(io, &removeOperation);

        // Whatever has not reached the flush size yet. Written even when the import failed part way,
        // because what it did take in before failing is exactly what a user asking "what happened?"
        // wants to see.
        var flushOperation: FlushImportRecordOperation = .{
            .run_state = run,
        };
        _ = swallowError(io, &flushOperation);
    }

    try run.scanner.scan(allocator, io, .{
        .context = run,
        .function = ImportRun.visitFile,
    }, .{
        .context = run,
        .function = ImportRun.onScanProgress,
    });

    //
    // Wait for all child tasks to complete.
    // If the task is cancelled, childQueue.shutdown() in the finally block
    // will resolve this immediately rather than waiting for the backlog.
    //
    {
        run.unlock();
        defer run.lock();
        try run.queue.awaitAllTasks();
    }

    // The queue says its tasks are finished, which is not the same as this import having finished
    // with them: a completion callback may still be recording what one of them did, and a hash
    // that has just come back may still be waiting for its upload to be queued. Ending here left
    // an uploaded asset with its database write never queued, so the file was uploaded and then
    // not in the database.
    while (run.childTasksInFlight > 0 or run.filesAwaitingHashCount() > 0 or run.assetsAwaitingUploadCount() > 0) {
        if (context.isCancelled()) {
            break;
        }
        try run.sleepUnlocked(50);
    }

    if (context.isCancelled()) {
        return importAssetsResultToJson(allocator, runResult(run));
    }

    // Flush the throttled queue and wait for any in-progress batch to finish.
    run.throttledProcessQueue.flush();
    run.throttledProcessQueue.cancel();

    while (run.isProcessingQueue) {
        try run.sleepUnlocked(100);
    }

    // Process any remaining items, retrying until the write lock is acquired.
    while (run.pendingDatabaseUpdates.items.len > 0) {
        const processed = try run.processPendingDatabaseUpdates(run.pendingDatabaseUpdates.items);
        if (!processed) {
            log.@"error"(try std.fmt.allocPrint(allocator, "Failed to acquire write lock for final {d} pending database updates; retrying.", .{run.pendingDatabaseUpdates.items.len}));
            try run.sleepUnlocked(1000);
        }
        else {
            for (run.pendingDatabaseUpdates.items) |item| {
                _ = try run.hashesQueuedForImport.delete(item.expectedHash);
            }
            run.pendingDatabaseUpdates = .empty;
        }
    }

    var saveOperation: SaveHashCacheOperation = .{
        .cache = &run.localHashCache,
    };
    _ = try retryOrLog(io, &saveOperation, "Failed to save hash cache", 3, 1000, 2);

    // The last word on what this run did, sent after the photos it queued have actually landed.
    //
    // Every other progress report goes out on a scanner tick, and the scanner stops ticking the
    // moment it has read the source to the end, which is well before the last photo it pushed
    // has been hashed, uploaded and written. Without this the run's final report says nothing
    // was imported and is never corrected, which is exactly what a phone importing one photo
    // looked like: `0 imported` repeatedly, and then the run ended.
    try run.sendImportProgress(null);

    return importAssetsResultToJson(allocator, runResult(run));
}

//
// `data.options?.auto`, read from the raw options. (No TypeScript counterpart.)
//
fn isAutoImport(options: ?std.json.Value) bool {
    const value = options orelse {
        return false;
    };
    if (value != .object) {
        return false;
    }
    const auto = value.object.get("auto") orelse {
        return false;
    };
    return auto == .bool and auto.bool;
}

//
// The result object the handler returns. (No TypeScript counterpart: TypeScript fills the object as it goes.)
//
fn runResult(run: *ImportRun) IImportAssetsResult {
    return .{
        .imported = run.imported.items,
        .skipped = run.skipped.items,
        .failedCount = run.failedCount,
    };
}

//
// Reads every record's hash into existingAssetIdsByHash (TypeScript: the inner loadExistingHashes function).
//
fn loadExistingHashes(run: *ImportRun) !void {
    var next: ?[]const u8 = null;
    while (true) {
        const page = try run.metadataCollection.getAll(run.io, next);
        for (page.records) |record| {
            const hash = record.get("hash") orelse {
                continue;
            };
            if (hash != .string or hash.string.len == 0) {
                continue;
            }
            const recordId = record.get("_id") orelse {
                return errors.throwError("Record has no _id", .{});
            };
            try run.existingAssetIdsByHash.put(run.allocator, hash.string, recordId.string);
        }
        next = page.next;
        if (next == null) {
            break;
        }
    }
}
