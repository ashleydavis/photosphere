const std = @import("std");
const utils = @import("utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const storage_zig = @import("storage-zig");
const serialization_zig = @import("serialization-zig");
const bdb = @import("bdb-zig");
const api = @import("api-zig");
const media_file_database = @import("media-file-database.zig");
const tree = @import("tree.zig");
const hash_module = @import("hash.zig");
const retry_operations = @import("retry-operations.zig");
const errors = utils.errors;
const log = &utils.log.log;
const retry = utils.retry.retry;
const retryOnce = utils.retry.retryOnce;
const OperationResult = utils.retry.OperationResult;
const WrappedError = utils.wrapped_error.WrappedError;
const merkle_tree = merkle_tree_zig.merkle_tree;
const IMerkleTree = merkle_tree.IMerkleTree;
const MerkleNode = merkle_tree.MerkleNode;
const getItemInfo = merkle_tree.getItemInfo;
const upsertItem = merkle_tree.upsertItem;
const deleteItem = merkle_tree.deleteItem;
const compareTrees = merkle_tree_zig.compare.compareTrees;
const findMerkleTreeDifferences = merkle_tree_zig.merkle_diff.findMerkleTreeDifferences;
const IStorage = storage_zig.storage.IStorage;
const IFileInfo = storage_zig.storage.IFileInfo;
const pathJoin = storage_zig.storage_factory.pathJoin;
const BsonDatabase = bdb.database.BsonDatabase;
const IBsonCollection = bdb.collection.IBsonCollection;
const IInternalRecord = bdb.shard.IInternalRecord;
const RecordMap = bdb.shard.RecordMap;
const mergeRecords = bdb.merge_records.mergeRecords;
const toExternal = bdb.collection.toExternal;
const BsonDocument = serialization_zig.bson.BsonDocument;
const BsonValue = serialization_zig.bson.BsonValue;
const js_date = serialization_zig.js_date;
const ISyncChange = api.sync_database_types.ISyncChange;
const loadDatabaseState = api.database_state.loadDatabaseState;
const acquireWriteLock = api.write_lock.acquireWriteLock;
const releaseWriteLock = api.write_lock.releaseWriteLock;
const LARGE_FILE_TIMEOUT = api.constants.LARGE_FILE_TIMEOUT;
const computeAssetHash = hash_module.computeAssetHash;

//
// How long one step of a sync may take before the pass gives up on it.
//
// Generous, because these steps are slow on a phone and there is no harm in a long one finishing. It
// exists to put a floor under a step that will never finish at all: a pass that fails is ordinary and
// the loop runs another, while a pass that hangs stops syncing until the app is restarted.
//
const SYNC_STEP_TIMEOUT_MS: u64 = 30 * 60 * 1000;

//
// Runs one step of a sync under a deadline, naming it if the deadline passes.
//
fn retryOnceNamed(io: std.Io, step: anytype, description: []const u8) anyerror!OperationResult(@TypeOf(step)) {
    return retryOnce(io, step, SYNC_STEP_TIMEOUT_MS) catch |err| {
        if (err != error.Thrown and err != error.FatalError) {
            errors.recordError("Error", "{s}", .{@errorName(err)});
        }
        return WrappedError.throw("Sync gave up while {s}", .{description});
    };
}

//
// Result of a sync operation.
//
pub const ISyncResult = struct {
    // True if a sync ran; false if the databases were already identical and the sync was skipped.
    synced: bool,
};

//
// The optional onLocalChange callback of syncDatabases and syncDatabase (TypeScript:
// `(change: ISyncChange) => void`). (Zig: a closure; `function` is called with `context`.)
//
pub const SyncChangeCallback = struct {
    // The state of the callback, passed to function.
    context: ?*anyopaque,

    // The callback function.
    function: *const fn (context: ?*anyopaque, change: ISyncChange) void,

    //
    // Invokes the callback.
    //
    pub fn call(self: SyncChangeCallback, change: ISyncChange) void {
        self.function(self.context, change);
    }
};

//
// The current time in milliseconds (TypeScript: `Date.now()`). (No TypeScript counterpart.)
//
fn now(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}

//
// The asset ids a merkle tree records as deleted, in order (TypeScript:
// `new Set(merkleTree?.databaseMetadata?.deletedAssetIds || [])`). (No TypeScript counterpart.)
//
fn deletedAssetIdsOf(allocator: std.mem.Allocator, merkleTree: ?IMerkleTree) !std.StringArrayHashMapUnmanaged(void) {
    var deletedIds: std.StringArrayHashMapUnmanaged(void) = .empty;
    const loadedTree = merkleTree orelse {
        return deletedIds;
    };
    const databaseMetadata = loadedTree.databaseMetadata orelse {
        return deletedIds;
    };
    const deletedAssetIds = databaseMetadata.get("deletedAssetIds") orelse {
        return deletedIds;
    };
    switch (deletedAssetIds) {
        .array => |array| {
            for (array) |deletedAssetId| {
                if (deletedAssetId != .string) {
                    return errors.throwError("A deleted asset id that is a {s} value is not ported", .{@tagName(deletedAssetId)});
                }
                try deletedIds.put(allocator, deletedAssetId.string, {});
            }
        },
        .null, .undefined => {},
        else => {
            return errors.throwError("deletedAssetIds that is a {s} value is not ported", .{@tagName(deletedAssetIds)});
        },
    }
    return deletedIds;
}

//
// `() => pushFiles(...)`, the step of syncDatabases that pushes files from one database to the other.
//
fn PushFilesOperation(comptime sourceText: []const u8) type {
    return struct {
        // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
        pub const source = sourceText;

        // Allocates everything the push keeps.
        allocator: std.mem.Allocator,

        // The storage files are pushed from.
        sourceAssetStorage: IStorage,

        // The storage files are pushed to.
        targetAssetStorage: IStorage,

        // The database of the storage files are pushed to.
        targetBsonDatabase: *BsonDatabase,

        // Where the push reads each file's bytes from and writes them to.
        bytes: IPushBytes,

        //
        // Pushes the files.
        //
        pub fn run(self: *@This(), io: std.Io) !void {
            return pushFiles(self.allocator, io, self.sourceAssetStorage, self.targetAssetStorage, self.targetBsonDatabase, self.bytes);
        }
    };
}

//
// `() => syncDatabase(...)`, the step of syncDatabases that merges one database's records into the other.
//
fn SyncDatabaseOperation(comptime sourceText: []const u8) type {
    return struct {
        // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
        pub const source = sourceText;

        // Allocates the merged records.
        allocator: std.mem.Allocator,

        // The database records are merged from.
        sourceBsonDatabase: *BsonDatabase,

        // The database records are merged into.
        targetBsonDatabase: *BsonDatabase,

        // The asset ids the target intentionally deleted.
        targetDeletedIds: *const std.StringArrayHashMapUnmanaged(void),

        // Told of each change to the target's metadata (null for none).
        onLocalChange: ?SyncChangeCallback,

        //
        // Merges the records.
        //
        pub fn run(self: *@This(), io: std.Io) !void {
            return syncDatabase(self.allocator, io, self.sourceBsonDatabase, self.targetBsonDatabase, self.targetDeletedIds, self.onLocalChange);
        }
    };
}

//
// `() => bsonDatabase.commit()`.
//
fn CommitOperation(comptime sourceText: []const u8) type {
    return struct {
        // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
        pub const source = sourceText;

        // The database to commit.
        bsonDatabase: *BsonDatabase,

        //
        // Commits the database.
        //
        pub fn run(self: *@This(), io: std.Io) !void {
            return self.bsonDatabase.commit(io);
        }
    };
}

//
// `() => stampDatabaseState(assetStorage, rawStorage, { lastSyncedAt: syncedAt })`.
//
fn StampDatabaseStateOperation(comptime sourceText: []const u8) type {
    return struct {
        // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
        pub const source = sourceText;

        // Allocates the state.
        allocator: std.mem.Allocator,

        // The database's asset storage.
        assetStorage: IStorage,

        // The database's raw storage, holding the state file.
        rawStorage: IStorage,

        // The time both sides record as their last successful sync.
        syncedAt: []const u8,

        //
        // Stamps the state file.
        //
        pub fn run(self: *@This(), io: std.Io) !void {
            return tree.stampDatabaseState(self.allocator, io, self.assetStorage, self.rawStorage, .{ .lastSyncedAt = self.syncedAt });
        }
    };
}

//
// Syncs between source and target databases.
// (Zig: the TypeScript optional onLocalChange is passed as null.)
//
pub fn syncDatabases(
    allocator: std.mem.Allocator,
    io: std.Io,
    sourceAssetStorage: IStorage,
    sourceRawStorage: IStorage,
    sourceBsonDatabase: *BsonDatabase,
    targetAssetStorage: IStorage,
    targetRawStorage: IStorage,
    targetBsonDatabase: *BsonDatabase,
    sessionId: []const u8,
    onLocalChange: ?SyncChangeCallback,
) !ISyncResult {

    //
    // Fast early-out: if both databases report the same content hash they are identical, so there is
    // nothing to sync. Reading the two small state files avoids acquiring the remote write lock and
    // downloading the remote merkle trees when there are no differences.
    //
    const sourceState = try loadDatabaseState(allocator, io, sourceRawStorage);
    const targetState = try loadDatabaseState(allocator, io, targetRawStorage);
    const sourceContentHash = if (sourceState) |state| state.contentHash else null;
    const targetContentHash = if (targetState) |state| state.contentHash else null;
    if (sourceContentHash != null and targetContentHash != null
        and std.mem.eql(u8, sourceContentHash.?, targetContentHash.?)) {
        log.verbose("Databases have identical content hashes, skipping sync.");
        return .{ .synced = false };
    }

    // The timestamp both sides record as their last successful sync.
    var syncedAtWriter: std.Io.Writer.Allocating = .init(allocator);
    try js_date.writeIsoString(&syncedAtWriter.writer, now(io));
    const syncedAt = syncedAtWriter.written();

    //
    // Pull incoming files.
    //
    try sourceBsonDatabase.flush();

    if (!try acquireWriteLock(allocator, io, sourceRawStorage, sessionId, 3)) { //todo: Don't need write lock if nothing to pull.
        return errors.throwError("Failed to acquire write lock for source database.", .{});
    }

    const pulled = pullIncomingFiles(allocator, io, sourceAssetStorage, sourceRawStorage, sourceBsonDatabase, targetAssetStorage, targetRawStorage, targetBsonDatabase, syncedAt, onLocalChange);
    try releaseWriteLockAfter(allocator, io, sourceRawStorage, pulled);

    //
    // Push outgoing files.
    //
    try targetBsonDatabase.flush();

    if (!try acquireWriteLock(allocator, io, targetRawStorage, sessionId, 3)) { //todo: Don't need write lock if nothing to push.
        return errors.throwError("Failed to acquire write lock for target database.", .{});
    }

    const pushed = pushOutgoingFiles(allocator, io, sourceAssetStorage, sourceRawStorage, sourceBsonDatabase, targetAssetStorage, targetRawStorage, targetBsonDatabase, syncedAt);
    try releaseWriteLockAfter(allocator, io, targetRawStorage, pushed);

    return .{ .synced = true };
}

//
// The finally block of syncDatabases' two locked sections: releases the write lock whether the section succeeded or
// not, then passes on the section's result. (No TypeScript counterpart: TypeScript writes try/finally inline. The
// error message of a failed section is kept across the release, which records errors of its own.)
//
fn releaseWriteLockAfter(allocator: std.mem.Allocator, io: std.Io, rawStorage: IStorage, sectionResult: anyerror!void) !void {
    var sectionError: errors.ErrorRecord = undefined;
    errors.captureError(&sectionError);
    try releaseWriteLock(allocator, io, rawStorage);
    errors.restoreError(&sectionError);
    return sectionResult;
}

//
// The body of syncDatabases' first try block, run holding the source's write lock.
// (No TypeScript counterpart: the try block is written inline.)
//
fn pullIncomingFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    sourceAssetStorage: IStorage,
    sourceRawStorage: IStorage,
    sourceBsonDatabase: *BsonDatabase,
    targetAssetStorage: IStorage,
    targetRawStorage: IStorage,
    targetBsonDatabase: *BsonDatabase,
    syncedAt: []const u8,
    onLocalChange: ?SyncChangeCallback,
) !void {
    // Push files from target to source (effectively pulls files from target into source).
    // We are pulling files into the sourceDb, so need the write lock on the source db.
    // Each step is given a deadline and a name.
    //
    // A step that never finishes used to stop the sync for good, silently: measured on a Pixel 6,
    // a pass sat for nearly three hours at no CPU at all, having written nothing and logged
    // nothing, because the record merge and the commit had no timeout anywhere around them. A
    // pass that fails is ordinary and the loop runs another one; a pass that hangs is the end of
    // syncing until the app is restarted.
    const pull = try chooseHowToPushBytes(allocator, io, targetAssetStorage, targetRawStorage, sourceAssetStorage, sourceRawStorage);
    var pullOperation: PushFilesOperation("() => pushFiles(targetAssetStorage, sourceAssetStorage, sourceBsonDatabase, pull)") = .{
        .allocator = allocator,
        .sourceAssetStorage = targetAssetStorage,
        .targetAssetStorage = sourceAssetStorage,
        .targetBsonDatabase = sourceBsonDatabase,
        .bytes = pull,
    };
    try retryOnceNamed(io, &pullOperation, "pulling files from the origin");
    var loadOperation: retry_operations.LoadMerkleTreeOperation("() => loadMerkleTree(sourceAssetStorage)") = .{
        .allocator = allocator,
        .storage = sourceAssetStorage,
    };
    const sourceMerkleTree = try retry(io, &loadOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, "Failed to load the source merkle tree");
    const sourceDeletedIds = try deletedAssetIdsOf(allocator, sourceMerkleTree);
    var syncOperation: SyncDatabaseOperation("() => syncDatabase(targetBsonDatabase, sourceBsonDatabase, sourceDeletedIds, onLocalChange)") = .{
        .allocator = allocator,
        .sourceBsonDatabase = targetBsonDatabase,
        .targetBsonDatabase = sourceBsonDatabase,
        .targetDeletedIds = &sourceDeletedIds,
        .onLocalChange = onLocalChange,
    };
    try retryOnceNamed(io, &syncOperation, "merging the origin's records into this database");
    var commitOperation: CommitOperation("() => sourceBsonDatabase.commit()") = .{
        .bsonDatabase = sourceBsonDatabase,
    };
    try retryOnceNamed(io, &commitOperation, "committing this database");

    // Refresh the source state file under the write lock we already hold (records the new content
    // hash and sync time), avoiding a second lock acquisition after the block.
    var stampOperation: StampDatabaseStateOperation("() => stampDatabaseState(sourceAssetStorage, sourceRawStorage, { lastSyncedAt: syncedAt })") = .{
        .allocator = allocator,
        .assetStorage = sourceAssetStorage,
        .rawStorage = sourceRawStorage,
        .syncedAt = syncedAt,
    };
    try retryOnceNamed(io, &stampOperation, "stamping this database's state");
}

//
// The body of syncDatabases' second try block, run holding the target's write lock.
// (No TypeScript counterpart: the try block is written inline.)
//
fn pushOutgoingFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    sourceAssetStorage: IStorage,
    sourceRawStorage: IStorage,
    sourceBsonDatabase: *BsonDatabase,
    targetAssetStorage: IStorage,
    targetRawStorage: IStorage,
    targetBsonDatabase: *BsonDatabase,
    syncedAt: []const u8,
) !void {
    // Push files from source to target.
    // Need the write lock in the target database.
    // No deadline on this one, unlike every other step: it is the whole point of a sync, it
    // copies every file the origin is missing, and on a phone with a real library that is hours
    // of work. The copies inside it have their own deadline, one per file, which is where a
    // stuck upload is caught. A deadline here caught nothing but honest progress: thirty minutes
    // in it gave up on a push that was uploading steadily.
    const push = try chooseHowToPushBytes(allocator, io, sourceAssetStorage, sourceRawStorage, targetAssetStorage, targetRawStorage);
    try pushFiles(allocator, io, sourceAssetStorage, targetAssetStorage, targetBsonDatabase, push);
    var loadOperation: retry_operations.LoadMerkleTreeOperation("() => loadMerkleTree(targetAssetStorage)") = .{
        .allocator = allocator,
        .storage = targetAssetStorage,
    };
    const targetMerkleTree = try retry(io, &loadOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, "Failed to load the target merkle tree");
    const targetDeletedIds = try deletedAssetIdsOf(allocator, targetMerkleTree);
    var syncOperation: SyncDatabaseOperation("() => syncDatabase(sourceBsonDatabase, targetBsonDatabase, targetDeletedIds)") = .{
        .allocator = allocator,
        .sourceBsonDatabase = sourceBsonDatabase,
        .targetBsonDatabase = targetBsonDatabase,
        .targetDeletedIds = &targetDeletedIds,
        .onLocalChange = null,
    };
    try retryOnceNamed(io, &syncOperation, "merging this database's records into the origin");
    var commitOperation: CommitOperation("() => targetBsonDatabase.commit()") = .{
        .bsonDatabase = targetBsonDatabase,
    };
    try retryOnceNamed(io, &commitOperation, "committing the origin");

    // Refresh the target state file under the write lock we already hold. Both sides now hold the
    // same (merged) content, so their content hashes match and the next sync can early-out.
    var stampOperation: StampDatabaseStateOperation("() => stampDatabaseState(targetAssetStorage, targetRawStorage, { lastSyncedAt: syncedAt })") = .{
        .allocator = allocator,
        .assetStorage = targetAssetStorage,
        .rawStorage = targetRawStorage,
        .syncedAt = syncedAt,
    };
    try retryOnceNamed(io, &stampOperation, "stamping the origin's state");
}

//
// Extracts asset ID from a file path.
// Asset files are stored with the asset ID as the filename, potentially in nested directories.
// Examples: "asset/abc123" -> "abc123", "directory/subdirectory/abc123" -> "abc123"
// Returns the asset ID (the last part of the path), or undefined if the path is empty.
//
fn extractAssetId(filePath: []const u8) ?[]const u8 {
    if (filePath.len == 0) {
        return null;
    }
    var parts = std.mem.tokenizeScalar(u8, filePath, '/');
    var lastPart: ?[]const u8 = null;
    while (parts.next()) |part| {
        lastPart = part;
    }
    // Asset ID is always the last part of the path (the filename)
    return lastPart;
}

//
// A file the source's tree describes that the target's does not, or does not under the same hash.
//
const IFileToConsider = struct {
    // The file's name in both trees.
    name: []const u8,

    // The hash the source's tree records for it.
    hash: []const u8,
};

//
// Where a push reads each file's bytes from and writes them to.
//
// Usually the two asset storages themselves, which hand out and take in what the database holds.
// When both databases are encrypted under the same key, the raw storages underneath instead: the
// ciphertext one holds is exactly the ciphertext the other would write, so it goes across as it is,
// with no decryption on the way out and no encryption on the way in.
//
// On a phone those two are the whole cost of pushing an original. AES-256-CBC there runs in the
// embedded engine's own JavaScript at about a fifth of a megabyte a second in each direction, so a
// push of twenty originals measured on a Pixel 6 moved 48MB in 472 seconds, about 100KB/s on a
// network that carries 11.8MB/s from the same phone, and a ninety megabyte video was a quarter of an
// hour. The bytes themselves, sent as they are stored, go from the file to the socket natively.
//
pub const IPushBytes = struct {
    // The storage each file's bytes are read from.
    source: IStorage,

    // The storage each file's bytes are written to.
    target: IStorage,

    // True when the bytes are the stored ones, going across untouched, rather than what the
    // databases hold. The hash the target is handed is then of the stored bytes, taken from the
    // source's copy, since the tree's hash is of what the database holds and would not match.
    verbatim: bool,
};

//
// A push that moves what the databases hold: read out of one asset storage, written into the other.
//
pub fn throughTheDatabases(sourceAssetStorage: IStorage, targetAssetStorage: IStorage) IPushBytes {
    return .{
        .source = sourceAssetStorage,
        .target = targetAssetStorage,
        .verbatim = false,
    };
}

//
// Decides how a push moves each file's bytes between two databases, given the storages they are
// read through and the raw storages underneath them.
//
// Verbatim, between the raw storages, when both databases are encrypted under the same key. Each
// encrypted database carries `.db/encryption.pub` naming the key its files are written under, and it
// is rewritten only once every file has been re-encrypted under a new one, so two databases whose
// key files are the same byte for byte hold files either could read. Otherwise through the asset
// storages, which decrypt and encrypt on the way as they always have. A database that is not
// encrypted has no key file, so a pair with one such side is never verbatim.
//
pub fn chooseHowToPushBytes(allocator: std.mem.Allocator, io: std.Io, sourceAssetStorage: IStorage, sourceRawStorage: IStorage, targetAssetStorage: IStorage, targetRawStorage: IStorage) !IPushBytes {
    var sourceReadOperation: retry_operations.ReadOperation("() => sourceRawStorage.read(\".db/encryption.pub\")") = .{
        .allocator = allocator,
        .storage = sourceRawStorage,
        .fileName = ".db/encryption.pub",
    };
    const sourceKey = try retry(io, &sourceReadOperation, 3, 1_000, 2, 30_000, null);
    var targetReadOperation: retry_operations.ReadOperation("() => targetRawStorage.read(\".db/encryption.pub\")") = .{
        .allocator = allocator,
        .storage = targetRawStorage,
        .fileName = ".db/encryption.pub",
    };
    const targetKey = try retry(io, &targetReadOperation, 3, 1_000, 2, 30_000, null);
    if (sourceKey != null and targetKey != null and std.mem.eql(u8, sourceKey.?, targetKey.?)) {
        return .{
            .source = sourceRawStorage,
            .target = targetRawStorage,
            .verbatim = true,
        };
    }

    return throughTheDatabases(sourceAssetStorage, targetAssetStorage);
}

//
// The state of a push (TypeScript: the variables the copyFile and sayWhereTheTimeWent closures of pushFiles
// capture).
//
const PushState = struct {
    // Allocates the tree and the messages.
    allocator: std.mem.Allocator,

    // The io of the push.
    io: std.Io,

    // The storage files are pushed from.
    sourceAssetStorage: IStorage,

    // Where the push reads each file's bytes from and writes them to.
    bytes: IPushBytes,

    // The source's merkle tree.
    sourceMerkleTree: *IMerkleTree,

    // The target's merkle tree, which the push adds the copied files to.
    targetMerkleTree: *IMerkleTree,

    // The asset ids the source records as deleted.
    sourceDeletedIds: *const std.StringArrayHashMapUnmanaged(void),

    // The asset ids the target records as deleted.
    targetDeletedIds: *const std.StringArrayHashMapUnmanaged(void),

    // The number of files copied.
    filesCopied: u64 = 0,

    // Where the time goes, in milliseconds, reported every so often while a push runs.
    //
    // Without it a slow sync is a number of files a minute and nothing else. The import path has the
    // same thing for the same reason: its unmeasured remainder turned out to be 54% of an import.
    millisecondsAskingAboutTheSource: i64 = 0,

    // The time spent writing files to the target.
    millisecondsWriting: i64 = 0,

    // The time spent updating the target's tree.
    millisecondsUpdatingTheTree: i64 = 0,

    // The time spent saving the target's tree.
    millisecondsSavingTheTree: i64 = 0,

    // The time spent working out which files to consider.
    millisecondsDiffingTheTrees: i64 = 0,

    // The time spent deciding whether to copy each file.
    millisecondsDecidingWhetherToCopy: i64 = 0,

    // The time spent inside copyFile.
    millisecondsInsideCopyFile: i64 = 0,

    // The time spent opening each file at the source.
    millisecondsOpeningTheSource: i64 = 0,

    // The number of leaves copyFile was called for.
    leavesVisited: u64 = 0,

    // The number of files considered.
    nodesVisited: u64 = 0,

    // The time spent saying where the time went.
    millisecondsLogging: i64 = 0,

    // The number of bytes copied.
    bytesCopied: u64 = 0,

    // When the push started.
    pushStartedAt: i64,

    //
    // Says where the push's time has gone so far.
    //
    // A sync that is slow is otherwise just a number of files a minute, and the interesting figure is
    // always the one that does not belong: a pass that spent forty-six minutes of its forty-six
    // minutes writing the merkle tree said so here and nowhere else.
    //
    fn sayWhereTheTimeWent(self: *PushState) !void {
        const loggedAt = now(self.io);
        const elapsed = now(self.io) - self.pushStartedAt;
        const unaccounted = elapsed - self.millisecondsAskingAboutTheSource - self.millisecondsWriting
            - self.millisecondsUpdatingTheTree - self.millisecondsSavingTheTree
            - self.millisecondsDiffingTheTrees - self.millisecondsDecidingWhetherToCopy - self.millisecondsLogging;
        log.info(try std.fmt.allocPrint(self.allocator, "Sync timings: {{\"filesCopied\":{d},\"leavesVisited\":{d},\"nodesVisited\":{d},\"bytesCopied\":{d},\"elapsedMs\":{d},\"copyFileMs\":{d},\"diffMs\":{d},\"decideMs\":{d},\"openSourceMs\":{d},\"sourceInfoMs\":{d},\"writeMs\":{d},\"treeUpdateMs\":{d},\"treeSaveMs\":{d},\"loggingMs\":{d},\"unaccountedMs\":{d}}}", .{
            self.filesCopied,
            self.leavesVisited,
            self.nodesVisited,
            self.bytesCopied,
            elapsed,
            self.millisecondsInsideCopyFile,
            self.millisecondsDiffingTheTrees,
            self.millisecondsDecidingWhetherToCopy,
            self.millisecondsOpeningTheSource,
            self.millisecondsAskingAboutTheSource,
            self.millisecondsWriting,
            self.millisecondsUpdatingTheTree,
            self.millisecondsSavingTheTree,
            self.millisecondsLogging,
            unaccounted,
        }));
        self.millisecondsLogging += now(self.io) - loggedAt;
    }

    //
    // Copies a single file if necessary.
    //
    fn copyFile(self: *PushState, fileName: []const u8, sourceHash: []const u8) !void {
        const allocator = self.allocator;
        const io = self.io;
        const decidingStartedAt = now(io);
        self.leavesVisited += 1;

        // Check if target database is partial - if so, only copy thumb directory files and root-level files
        const isTargetPartial = media_file_database.isPartialDatabase(self.targetMerkleTree.databaseMetadata);
        if (isTargetPartial) {
            const normalizedFileName = try allocator.dupe(u8, fileName);
            std.mem.replaceScalar(u8, normalizedFileName, '\\', '/');
            const isThumbFile = std.mem.startsWith(u8, normalizedFileName, "thumb/");
            const isRootFile = std.mem.indexOfScalar(u8, normalizedFileName, '/') == null;
            if (!isThumbFile and !isRootFile) {
                log.verbose(try std.fmt.allocPrint(allocator, "Skipped {s} (target database is partial, only thumb files and root files are copied)", .{fileName}));
                return;
            }
        }

        // Check if this asset is in the deleted list
        const assetId = extractAssetId(fileName) orelse {
            return errors.throwError("Failed to extract asset ID from file name: {s}", .{fileName});
        };

        if (self.sourceDeletedIds.contains(assetId) or self.targetDeletedIds.contains(assetId)) {
            // Asset is deleted, skip copying it
            log.verbose(try std.fmt.allocPrint(allocator, "Skipped deleted asset file: {s}", .{fileName}));
            return;
        }

        // Check if file already exists in destination tree with matching hash.
        const targetFileInfo = try getItemInfo(self.targetMerkleTree, fileName);
        if (targetFileInfo != null and std.mem.eql(u8, targetFileInfo.?.hash, sourceHash)) {
            // File already exists with correct hash, skip copying.
            // This assumes the file is non-corrupted. To find corrupted files, a verify would be needed.
            self.millisecondsDecidingWhetherToCopy += now(io) - decidingStartedAt;
            return;
        }
        self.millisecondsDecidingWhetherToCopy += now(io) - decidingStartedAt;

        // Get file info from source.
        const askedAboutTheSourceAt = now(io);
        const sourceFileInfo = try self.sourceAssetStorage.info(allocator, io, fileName) orelse {
            return errors.throwError("Failed to find file {s} in source database.", .{fileName});
        };
        self.millisecondsAskingAboutTheSource += now(io) - askedAboutTheSourceAt;

        // What the source's tree records for this file, which is what the target's tree is about to
        // record for its copy. Its hash is already trusted for exactly this file: it is what decided
        // the copy was needed and what goes up with the body.
        const sourceTreeInfo = try getItemInfo(self.sourceMerkleTree, fileName) orelse {
            return errors.throwError("Source file \"{s}\" is in the source tree's merkle nodes but not in its sort tree.", .{fileName});
        };

        // Copy file from source to target.
        // The hash goes up with the file. It is already known, because it is what the merkle tree is
        // made of, and handing it over means nothing has to compute it: S3 checks the body against it
        // and refuses a write that does not match, while a store that cannot check it writes the
        // stream as usual. On a phone that is the difference between a sync and a stalled one, since
        // the SDK would otherwise hash every byte in the embedded engine's pure JavaScript SHA-256.
        //
        // What is sent, and what the target is told it is. Through the databases the stream is what
        // the database holds and the hash is the tree's, which is of exactly that. Verbatim, the
        // stream is the stored bytes themselves and the hash has to be of those, so it is taken from
        // the source's copy, natively where there is a native hasher: the tree's hash is of the
        // plaintext and would not match.
        //
        const openedAt = now(io);
        const storedInfo: IFileInfo = (if (self.bytes.verbatim) try self.bytes.source.info(allocator, io, fileName) else sourceFileInfo) orelse {
            return errors.throwError("Failed to find the stored bytes of {s} in the source database.", .{fileName});
        };
        var hashForTheStore = sourceHash;
        if (self.bytes.verbatim) {
            const hashStream = try self.bytes.source.readStream(allocator, io, fileName);
            defer hashStream.destroy(io);
            hashForTheStore = (try computeAssetHash(allocator, hashStream.reader(), .{
                .contentType = storedInfo.contentType,
                .length = storedInfo.length,
                .lastModified = storedInfo.lastModified,
            })).hash;
        }
        const readStream = try self.bytes.source.readStream(allocator, io, fileName);
        defer readStream.destroy(io);
        self.millisecondsOpeningTheSource += now(io) - openedAt;
        // A store that checked the bytes against the hash as it wrote them has already told us
        // everything a check afterwards could, so nothing else is asked of it.
        //
        // Asking cost two more round trips per file, on top of the write: one to learn the file is
        // there and how long it is, another to read back the hash the server had just verified. On a
        // phone, where every request is a fresh connection and a response crosses the engine bridge,
        // those two were a large part of the time a file took. A store that cannot check (a
        // filesystem, or encrypted storage, whose stored bytes are ciphertext and hash to something
        // else) is still asked, and the copy is checked by its length. `psi verify` is the deep
        // check, and it reads everything deliberately rather than as a side effect of every sync.
        //
        // How many bytes that stream will produce, which is the source's to say and not the same as
        // the size of the file it keeps.
        //
        // An encrypted database holds ciphertext and reads out plaintext, and it cannot say how long
        // the plaintext is without decrypting the file, so it says it cannot. Handing the stored size
        // over instead made the target declare a Content-Length it then fell short of by the
        // encryption's overhead, and S3 sat waiting for a remainder that was never coming: measured
        // on a Pixel 6 pushing to MinIO on the same LAN, every file failed after thirty seconds with
        // "A timeout occurred while trying to lock a resource, please reduce your request rate",
        // three attempts each, and the sync copied nothing at all for as long as it was left running.
        //
        const writeStartedAt = now(io);
        const verifiedByTheStore = try self.bytes.target.writeStreamHashed(allocator, io, fileName, sourceFileInfo.contentType, readStream.reader(), self.bytes.source.readableLength(storedInfo), hashForTheStore);
        self.millisecondsWriting += now(io) - writeStartedAt;
        self.bytesCopied += sourceTreeInfo.length;

        if (!verifiedByTheStore) {
            const copiedFileInfo = try self.bytes.target.info(allocator, io, fileName) orelse {
                return errors.throwError("Failed to copy {s} to target db.", .{fileName});
            };

            const storedHash = try self.bytes.target.storedHash(allocator, io, fileName);
            if (storedHash) |targetHash| {
                if (!std.mem.eql(u8, targetHash, hashForTheStore)) {
                    return errors.throwError("Hash of copied file {s} is different to the source hash.", .{fileName});
                }
            }
            else if (copiedFileInfo.length != storedInfo.length) {
                return errors.throwError("Copied file {s} is {d} bytes at the target and {d} at the source.", .{ fileName, copiedFileInfo.length, storedInfo.length });
            }
        }

        // Add or update file in target merkle tree, under what the source's tree recorded: the copy
        // has just been checked against that hash, so the two describe the same bytes, and the length
        // and time are the source tree's for the same reason. Reading them back off the target would
        // be another request per file to be told what was just sent, and off an encrypted target it
        // would give the ciphertext's length, which would never match the source and would put the
        // file back in the difference on every pass for ever.
        const treeStartedAt = now(io);
        self.targetMerkleTree.* = try upsertItem(allocator, self.targetMerkleTree, .{
            .name = fileName,
            .hash = sourceHash,
            .length = sourceTreeInfo.length,
            .lastModified = sourceTreeInfo.lastModified,
        });
        self.millisecondsUpdatingTheTree += now(io) - treeStartedAt;

        self.filesCopied += 1;

        log.verbose(try std.fmt.allocPrint(allocator, "Copied file: {s}", .{fileName}));
    }
};

//
// `() => copyFile(file.name, file.hash)`.
//
const CopyFileOperation = struct {
    // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
    pub const source = "() => copyFile(file.name, file.hash)";

    // The state of the push.
    state: *PushState,

    // The file to copy.
    file: IFileToConsider,

    //
    // Copies the file.
    //
    pub fn run(self: *CopyFileOperation, io: std.Io) !void {
        _ = io;
        return self.state.copyFile(self.file.name, self.file.hash);
    }
};

//
// Pushes from source db to target db for a particular device based
// on missing files detected by comparing source and target merkle trees.
//
pub fn pushFiles(allocator: std.mem.Allocator, io: std.Io, sourceAssetStorage: IStorage, targetAssetStorage: IStorage, targetBsonDatabase: *BsonDatabase, bytes: IPushBytes) !void {

    //
    // Load the merkle tree.
    //
    var loadSourceOperation: retry_operations.LoadMerkleTreeOperation("() => loadMerkleTree(sourceAssetStorage)") = .{
        .allocator = allocator,
        .storage = sourceAssetStorage,
    };
    var sourceMerkleTree = try retry(io, &loadSourceOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, "Failed to load the source merkle tree to push from") orelse {
        return errors.throwError("Failed to load source merkle tree.", .{});
    };

    var loadTargetOperation: retry_operations.LoadMerkleTreeOperation("() => loadMerkleTree(targetAssetStorage)") = .{
        .allocator = allocator,
        .storage = targetAssetStorage,
    };
    var targetMerkleTree = try retry(io, &loadTargetOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, "Failed to load the target merkle tree to push into") orelse {
        return errors.throwError("Failed to load target merkle tree.", .{});
    };

    // Check that source and target databases have the same ID.
    if (!std.mem.eql(u8, sourceMerkleTree.id, targetMerkleTree.id)) {
        return errors.throwFatalError(
            "You are trying to sync databases that have different IDs.\n" ++
                "Source database ID: {s}\n" ++
                "Target database ID: {s}\n" ++
                "The databases are not related to each other.",
            .{ sourceMerkleTree.id, targetMerkleTree.id },
        );
    }

    // Don't do anything if the source and target merkle trees are identical.
    if (sourceMerkleTree.merkle != null and targetMerkleTree.merkle != null
        and std.mem.eql(u8, sourceMerkleTree.merkle.?.hash, targetMerkleTree.merkle.?.hash)) {
        log.verbose("Source and target merkle trees are identical, no sync needed.");
        return;
    }

    // Get deleted asset IDs from source and target
    const sourceDeletedIds = try deletedAssetIdsOf(allocator, sourceMerkleTree);
    const targetDeletedIds = try deletedAssetIdsOf(allocator, targetMerkleTree);

    var state: PushState = .{
        .allocator = allocator,
        .io = io,
        .sourceAssetStorage = sourceAssetStorage,
        .bytes = bytes,
        .sourceMerkleTree = &sourceMerkleTree,
        .targetMerkleTree = &targetMerkleTree,
        .sourceDeletedIds = &sourceDeletedIds,
        .targetDeletedIds = &targetDeletedIds,
        .pushStartedAt = now(io),
    };

    // Files that could not be copied this pass. They stay missing at the far end, so the next pass
    // finds them in the difference and tries them again.
    var filesLeftBehind: u64 = 0;

    // What filesCopied stood at when the tree was last saved and when the timings were last said.
    //
    // Both of those happen every so many files, and both are checked once per leaf rather than once
    // per copy, so a count sitting on a multiple repeated them for every leaf walked and matched
    // afterwards. Measured on a Pixel 6 pushing to an origin holding thousands of photos, the timings
    // line came out five times in a row for leaves 417 to 421 with the count stuck at sixty, and the
    // tree save does the same thing at every hundredth file, which is a megabyte written back per
    // leaf to record that nothing changed.
    var filesCopiedAtLastTreeSave: u64 = 0;
    var filesCopiedAtLastTimingsLine: u64 = 0;

    //
    // The files to consider: every file the source's tree describes that the target's does not, or
    // describes under a different hash, found by name.
    //
    // This used to be the merkle diff, and the merkle diff matches leaves by hash rather than by
    // name, so a file whose content the target already held under another name was never offered
    // for copying at all. A library holds such files whenever a photo has been imported twice: an
    // import stopped before its batch was written imports the same photos again under new ids on
    // its next run, and the records for the new ids reach the target through the record merge while
    // their files never do. Measured on a Pixel 6 against an origin holding 15,491 files, 243 files
    // of 101 assets were missing at the origin after five passes that had each reported nothing
    // left behind, and only a walk of both trees by name said so.
    //
    const decidingWhatToConsiderAt = now(io);
    const comparison = try compareTrees(allocator, &sourceMerkleTree, &targetMerkleTree, null);
    var filesToConsider: std.ArrayList(IFileToConsider) = .empty;
    for ([_][]const []const u8{ comparison.onlyInA, comparison.modified }) |names| {
        for (names) |name| {
            const info = try getItemInfo(&sourceMerkleTree, name) orelse {
                return errors.throwError("The source tree compared as holding {s} and then did not have it.", .{name});
            };
            try filesToConsider.append(allocator, .{
                .name = name,
                .hash = info.hash,
            });
        }
    }
    state.nodesVisited = filesToConsider.items.len;
    state.millisecondsDiffingTheTrees += now(io) - decidingWhatToConsiderAt;

    for (filesToConsider.items) |file| {
        // The long timeout is the one the import path already uses for streaming large files
        // to S3. Left at retry's thirty second default, every copy of a file that takes
        // longer than that was abandoned and tried again from the start: on a Pixel 6, which
        // pushes about seven megabytes a minute through the engine bridge, that is anything
        // over about three megabytes, so a library with a video in it never finished syncing
        // and the same file was uploaded over and over for ever.
        // A file that will not copy is left behind rather than taken as the end of the sync.
        //
        // The rest of the library has nothing to do with it, and abandoning the pass on the
        // first bad file means everything after that file in the tree never goes anywhere:
        // measured on a Pixel 6 against a real library, one video that the server kept
        // refusing held up all 2,292 assets, pass after pass, for as long as it was left
        // running. The file stays missing at the far end, so the next pass finds it in the
        // difference and tries it again.
        const copyStartedAt = now(io);
        var copyOperation: CopyFileOperation = .{
            .state = &state,
            .file = file,
        };
        retry(io, &copyOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, try std.fmt.allocPrint(allocator, "Failed to copy file {s}", .{file.name})) catch |err| {
            filesLeftBehind += 1;
            log.exception(try std.fmt.allocPrint(allocator, "Failed to copy {s}, carrying on with the rest of the sync", .{file.name}), err);
            continue;
        };
        state.millisecondsInsideCopyFile += now(io) - copyStartedAt;

        // Save the target merkle tree every hundred files, so a push that is interrupted
        // does not start again from nothing.
        //
        // Comparing against the count at the last save is what makes that "every hundred
        // files" rather than "every leaf". This is reached once per leaf, and a leaf whose
        // file is already at the far end copies nothing, so a count resting on a multiple of
        // a hundred saved the whole tree again for each of them. Measured on a Pixel 6
        // pushing to an S3 origin holding thousands of photos, a pass that had nothing to
        // copy spent 42 minutes visiting 92 leaves, of which 10 milliseconds was the copying:
        // the rest was serializing and uploading a megabyte of merkle tree, once per leaf, to
        // record that nothing had changed. A count of zero is the starting value, so a pass
        // that has copied nothing yet saves nothing.
        if (state.filesCopied % 100 == 0 and state.filesCopied != filesCopiedAtLastTreeSave) {
            filesCopiedAtLastTreeSave = state.filesCopied;
            const savedAt = now(io);
            var saveOperation: retry_operations.SaveMerkleTreeOperation("() => saveMerkleTree(targetMerkleTree, targetAssetStorage)") = .{
                .allocator = allocator,
                .merkleTree = &targetMerkleTree,
                .storage = targetAssetStorage,
            };
            try retry(io, &saveOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, "Failed to save the target merkle tree part way through a push");
            state.millisecondsSavingTheTree += now(io) - savedAt;
        }

        // Where the time went, said out loud often enough to be useful and rarely enough to
        // be readable. A sync that is slow is otherwise just a number of files a minute.
        //
        // Against the count at the last line for the reason above: this is reached once per
        // leaf, so a count resting on a multiple of twenty said the same thing again for
        // every leaf walked and matched afterwards. On a Pixel 6 pushing to an origin holding
        // thousands of photos that was five identical lines for leaves 417 to 421, and the
        // line that mattered was somewhere under them.
        if (state.filesCopied % 20 == 0 and state.filesCopied != filesCopiedAtLastTimingsLine) {
            filesCopiedAtLastTimingsLine = state.filesCopied;
            try state.sayWhereTheTimeWent();
        }
    }

    // Delete assets that are marked as deleted in source (but not yet deleted in target)
    // Iterate through source's deleted list and delete each asset from target
    var assetsDeleted: u64 = 0;
    for (sourceDeletedIds.keys()) |assetId| {
        // Skip if already deleted in target
        if (targetDeletedIds.contains(assetId)) {
            continue;
        }

        // Delete the asset files
        const assetPath = try pathJoin(allocator, &.{ "asset", assetId });
        const displayPath = try pathJoin(allocator, &.{ "display", assetId });
        const thumbPath = try pathJoin(allocator, &.{ "thumb", assetId });

        // Try to delete files (may not exist, which is fine)
        targetAssetStorage.deleteFile(allocator, io, assetPath) catch {};
        targetAssetStorage.deleteFile(allocator, io, displayPath) catch {};
        targetAssetStorage.deleteFile(allocator, io, thumbPath) catch {};

        // Remove from the target merkle tree
        try deleteItem(allocator, &targetMerkleTree, assetPath);
        try deleteItem(allocator, &targetMerkleTree, displayPath);
        try deleteItem(allocator, &targetMerkleTree, thumbPath);

        // Remove from metadata collection
        const metadataCollection = try targetBsonDatabase.collection("metadata");
        _ = try metadataCollection.deleteOne(io, assetId);

        // Ensure databaseMetadata exists
        if (targetMerkleTree.databaseMetadata == null) {
            targetMerkleTree.databaseMetadata = try media_file_database.emptyDatabaseMetadata(allocator);
        }
        var databaseMetadata = &targetMerkleTree.databaseMetadata.?;

        // Decrement filesImported count
        const filesImported = databaseMetadata.get("filesImported") orelse BsonValue.undefined;
        const filesImportedNumber = if (filesImported == .undefined) std.math.nan(f64) else try bdb.js_value.toNumber(allocator, filesImported);
        if (filesImportedNumber > 0) {
            try databaseMetadata.put(allocator, "filesImported", .{ .number = filesImportedNumber - 1 });
        }

        assetsDeleted += 1;

        // Add to target's deleted list
        var deletedAssetIds: std.ArrayList(BsonValue) = .empty;
        if (databaseMetadata.get("deletedAssetIds")) |existing| {
            if (existing == .array) {
                try deletedAssetIds.appendSlice(allocator, existing.array);
            }
        }

        try deletedAssetIds.append(allocator, .{ .string = assetId });
        try databaseMetadata.put(allocator, "deletedAssetIds", .{ .array = deletedAssetIds.items });

        log.verbose(try std.fmt.allocPrint(allocator, "Deleted asset {s} from target (marked as deleted in source)", .{assetId}));
    }

    // Save the target merkle tree one final time, and only when this pass put something in it.
    //
    // Nothing copied and nothing deleted leaves the tree exactly as it was loaded, so writing it back
    // sends a megabyte to say that. On a Pixel 6 pushing to an origin holding 8,481 photos that one
    // write took twenty-nine seconds of a thirty-one second pass, every five minutes, for as long as
    // the app was running: it is the whole cost of a sync that has nothing to do, and it was
    // competing for the connection with the import that did.
    if (state.filesCopied > 0 or assetsDeleted > 0) {
        const savedAt = now(io);
        var saveOperation: retry_operations.SaveMerkleTreeOperation("() => saveMerkleTree(targetMerkleTree, targetAssetStorage)") = .{
            .allocator = allocator,
            .merkleTree = &targetMerkleTree,
            .storage = targetAssetStorage,
        };
        try retry(io, &saveOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, "Failed to save the target merkle tree after a push");
        state.millisecondsSavingTheTree += now(io) - savedAt;
    }

    // Said once at the end whatever the pass did, because a pass that copied nothing is exactly the
    // one whose time needs explaining and is the one the every-twenty-files line above never reaches.
    try state.sayWhereTheTimeWent();

    log.info(try std.fmt.allocPrint(allocator, "Push completed: {d} files copied, {d} left behind for the next pass, {d} deleted from target", .{ state.filesCopied, filesLeftBehind, assetsDeleted }));
}

//
// Extracts leaf node names from MerkleNode arrays.
// (Zig: collects the names into a list in place of the TypeScript generator yielding them.)
//
fn iterateLeaves(allocator: std.mem.Allocator, leaves: *std.ArrayList([]const u8), nodes: []const *MerkleNode) !void { //todo: This could be a shared function in the merkle-tree package.
    for (nodes) |node| {
        if (node.left == null and node.right == null) {
            const name = node.name orelse {
                return errors.throwError("Leaf node has no name", .{});
            };
            try leaves.append(allocator, name);
        }
        else {
            if (node.left) |left| {
                try iterateLeaves(allocator, leaves, &.{left});
            }
            if (node.right) |right| {
                try iterateLeaves(allocator, leaves, &.{right});
            }
        }
    }
}

//
// The leaf names of MerkleNode arrays, in order (TypeScript: a loop over `iterateLeaves(nodes)`).
// (No TypeScript counterpart.)
//
fn leavesOf(allocator: std.mem.Allocator, nodes: []const *MerkleNode) ![]const []const u8 {
    var leaves: std.ArrayList([]const u8) = .empty;
    try iterateLeaves(allocator, &leaves, nodes);
    return leaves.items;
}

//
// Identifies a differing record between source and target databases, used as the yield type for sync diff generators.
//
const ISyncDiffRecord = struct {
    // The collection holding the record.
    collectionName: []const u8,

    // The id of the record.
    recordId: []const u8,

    // The record in the source database (null when it has none).
    sourceRecord: ?IInternalRecord,

    // The record in the target database (null when it has none).
    targetRecord: ?IInternalRecord,
};

//
// Receives each differing record (Zig: the sync diff generators call this in place of yielding the record, so each
// record is handled before the next one is looked up, as the TypeScript `for await` does).
//
const DiffVisitor = struct {
    // The state of the visitor, passed to function.
    context: *anyopaque,

    // Handles one differing record.
    function: *const fn (context: *anyopaque, diff: ISyncDiffRecord) anyerror!void,

    //
    // Hands the visitor a differing record.
    //
    fn yield(self: DiffVisitor, diff: ISyncDiffRecord) !void {
        return self.function(self.context, diff);
    }
};

//
// Removes the dashes from a record id (TypeScript: `recordId.replace(/-/g, '')`). (No TypeScript counterpart.)
//
fn withoutDashes(allocator: std.mem.Allocator, recordId: []const u8) ![]const u8 {
    const normalized = try allocator.alloc(u8, recordId.len);
    const length = std.mem.replace(u8, recordId, "-", "", normalized);
    return normalized[0 .. recordId.len - length];
}

//
// Yields differing records for a specific collection and shard.
//
fn iterateShardDifferences(
    allocator: std.mem.Allocator,
    io: std.Io,
    collectionName: []const u8,
    shardId: []const u8,
    sourceCollection: *IBsonCollection,
    targetCollection: *IBsonCollection,
    sourceShardTree: ?*IMerkleTree,
    targetShardTree: ?*IMerkleTree,
    visitor: DiffVisitor,
) !void {

    const diff = try findMerkleTreeDifferences(allocator, if (sourceShardTree) |shardTree| shardTree.merkle else null, if (targetShardTree) |shardTree| shardTree.merkle else null);
    const sourceShard = try sourceCollection.shard(shardId);
    const targetShard = try targetCollection.shard(shardId);

    // Extract record IDs from both sets to detect modifications
    var recordIdsInTree1: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (try leavesOf(allocator, diff.onlyInTree1)) |recordId| {
        try recordIdsInTree1.put(allocator, recordId, {});
    }
    var recordIdsInTree2: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (try leavesOf(allocator, diff.onlyInTree2)) |recordId| {
        try recordIdsInTree2.put(allocator, recordId, {});
    }

    const sourceRecords: *RecordMap = try sourceShard.records(io);
    const targetRecords: *RecordMap = try targetShard.records(io);

    // Track record IDs we've already yielded to avoid duplicates
    var seenRecordIds: std.StringHashMapUnmanaged(void) = .empty;

    // Process records from tree1
    for (recordIdsInTree1.keys()) |recordId| {
        try seenRecordIds.put(allocator, recordId, {});
        const normalizedId = try withoutDashes(allocator, recordId); //todo: This is a bit ugly.
        const sourceRecord = sourceRecords.get(normalizedId);
        const targetRecord = targetRecords.get(normalizedId);

        // If record ID appears in both trees, it's modified (different hash)
        // Otherwise, it's only in source
        try visitor.yield(.{
            .collectionName = collectionName,
            .recordId = recordId,
            .sourceRecord = sourceRecord,
            .targetRecord = targetRecord,
        });
    }

    // Process records only in tree2 (not already processed above)
    for (recordIdsInTree2.keys()) |recordId| {
        if (seenRecordIds.contains(recordId)) {
            continue; // Already processed as a modification
        }

        const normalizedId = try withoutDashes(allocator, recordId); //todo: This is a bit ugly.
        const sourceRecord = sourceRecords.get(normalizedId);
        const targetRecord = targetRecords.get(normalizedId);
        try visitor.yield(.{
            .collectionName = collectionName,
            .recordId = recordId,
            .sourceRecord = sourceRecord,
            .targetRecord = targetRecord,
        });
    }
}

//
// Yields differing records for a specific collection.
//
fn iterateCollectionDifferences(
    allocator: std.mem.Allocator,
    io: std.Io,
    collectionName: []const u8,
    sourceCollection: *IBsonCollection,
    targetCollection: *IBsonCollection,
    sourceCollectionTree: ?*IMerkleTree,
    targetCollectionTree: ?*IMerkleTree,
    visitor: DiffVisitor,
) !void {
    const diff = try findMerkleTreeDifferences(allocator, if (sourceCollectionTree) |collectionTree| collectionTree.merkle else null, if (targetCollectionTree) |collectionTree| collectionTree.merkle else null);

    // Track shard keys we've seen to avoid duplicates (only track, don't collect all)
    var seenShardKeys: std.StringHashMapUnmanaged(void) = .empty;

    // Process shards only in source
    for (try leavesOf(allocator, diff.onlyInTree1)) |shardId| {
        try seenShardKeys.put(allocator, shardId, {});

        const sourceShardTree = try (try (try sourceCollection.shard(shardId)).merkleTree()).get(io);
        const targetShardTree = try (try (try targetCollection.shard(shardId)).merkleTree()).get(io);
        if (sourceShardTree == null and targetShardTree == null) {
            continue;
        }

        try iterateShardDifferences(allocator, io, collectionName, shardId, sourceCollection, targetCollection, sourceShardTree, targetShardTree, visitor);
    }

    // Process shards only in target or modified
    for (try leavesOf(allocator, diff.onlyInTree2)) |shardId| {
        if (seenShardKeys.contains(shardId)) {
            continue; // Already processed
        }

        const sourceShardTree = try (try (try sourceCollection.shard(shardId)).merkleTree()).get(io);
        const targetShardTree = try (try (try targetCollection.shard(shardId)).merkleTree()).get(io);
        if (sourceShardTree == null and targetShardTree == null) {
            continue;
        }

        try iterateShardDifferences(allocator, io, collectionName, shardId, sourceCollection, targetCollection, sourceShardTree, targetShardTree, visitor);
    }
}

//
// Yields differing records in the BSON database.
//
fn iterateDatabaseDifferences( //todo: todo this could be in the bdb package and tested.
    allocator: std.mem.Allocator,
    io: std.Io,
    sourceDb: *BsonDatabase,
    targetDb: *BsonDatabase,
    visitor: DiffVisitor,
) !void {
    const sourceDbTree = try (try sourceDb.merkleTree()).get(io);
    const targetDbTree = try (try targetDb.merkleTree()).get(io);
    if (sourceDbTree == null and targetDbTree == null) {
        return;
    }

    const diff = try findMerkleTreeDifferences(allocator, if (sourceDbTree) |dbTree| dbTree.merkle else null, if (targetDbTree) |dbTree| dbTree.merkle else null);

    // Track collections we've seen to avoid duplicates (only track, don't collect all)
    var seenCollections: std.StringHashMapUnmanaged(void) = .empty;

    // Process collections only in source
    for (try leavesOf(allocator, diff.onlyInTree1)) |collectionName| {
        try seenCollections.put(allocator, collectionName, {});

        const sourceCollection = try sourceDb.collection(collectionName);
        const targetCollection = try targetDb.collection(collectionName);
        const sourceCollectionTree = try (try sourceCollection.merkleTree()).get(io);
        const targetCollectionTree = try (try targetCollection.merkleTree()).get(io);

        if (sourceCollectionTree == null and targetCollectionTree == null) {
            continue;
        }

        try iterateCollectionDifferences(
            allocator,
            io,
            collectionName,
            sourceCollection,
            targetCollection,
            sourceCollectionTree,
            targetCollectionTree,
            visitor,
        );
    }

    // Process collections only in target or modified
    for (try leavesOf(allocator, diff.onlyInTree2)) |collectionName| {
        if (seenCollections.contains(collectionName)) {
            continue; // Already processed
        }

        const sourceCollection = try sourceDb.collection(collectionName);
        const targetCollection = try targetDb.collection(collectionName);
        const sourceCollectionTree = try (try sourceCollection.merkleTree()).get(io);
        const targetCollectionTree = try (try targetCollection.merkleTree()).get(io);

        if (sourceCollectionTree == null and targetCollectionTree == null) {
            continue;
        }

        try iterateCollectionDifferences(
            allocator,
            io,
            collectionName,
            sourceCollection,
            targetCollection,
            sourceCollectionTree,
            targetCollectionTree,
            visitor,
        );
    }
}

//
// The state of syncDatabase's `for await` loop over the differing records (TypeScript: the variables its body uses).
//
const SyncDatabaseState = struct {
    // Allocates the merged records.
    allocator: std.mem.Allocator,

    // The io of the sync.
    io: std.Io,

    // The database records are merged into.
    targetBsonDatabase: *BsonDatabase,

    // The asset ids the target intentionally deleted.
    targetDeletedIds: *const std.StringArrayHashMapUnmanaged(void),

    // Told of each change to the target's metadata (null for none).
    onLocalChange: ?SyncChangeCallback,

    // The number of records merged.
    mergedCount: u64 = 0,

    //
    // Handles one differing record (TypeScript: the body of the `for await` loop).
    //
    fn visit(context: *anyopaque, diff: ISyncDiffRecord) anyerror!void {
        const self: *SyncDatabaseState = @ptrCast(@alignCast(context));
        const allocator = self.allocator;
        const io = self.io;

        const targetCollection = try self.targetBsonDatabase.collection(diff.collectionName);

        const isMetadata = std.mem.eql(u8, diff.collectionName, "metadata");
        if (diff.sourceRecord != null and diff.targetRecord != null) {
            // Both records exist, merge them.
            const merged = try mergeRecords(allocator, diff.sourceRecord.?, diff.targetRecord.?);
            // Use setInternalRecord to preserve all timestamps exactly
            try targetCollection.setInternalRecord(io, merged);
            self.mergedCount += 1;
            if (self.onLocalChange != null and isMetadata) {
                self.onLocalChange.?.call(.{ .type = .updated, .asset = try toExternal(allocator, merged) });
            }
        }
        else if (diff.sourceRecord) |sourceRecord| {
            // Record only in source - insert it unless the target intentionally deleted it.
            if (!self.targetDeletedIds.contains(sourceRecord._id)) {
                try targetCollection.setInternalRecord(io, sourceRecord);
                self.mergedCount += 1;
                if (self.onLocalChange != null and isMetadata) {
                    self.onLocalChange.?.call(.{ .type = .added, .asset = try toExternal(allocator, sourceRecord) });
                }
            }
            else {
                if (self.onLocalChange != null and isMetadata) {
                    self.onLocalChange.?.call(.{ .type = .deleted, .assetId = sourceRecord._id });
                }
            }
        }
        else if (diff.targetRecord != null) {
            // Record only in target, nothing to do (target already has it)
            // This case is less common in sync scenarios
        }

        if (self.mergedCount % 100 == 0) {
            log.verbose(try std.fmt.allocPrint(allocator, "Merged {d} records...", .{self.mergedCount}));
        }
    }
};

//
// Syncs database records from source to target using hierarchical merkle-tree based diffing.
// targetDeletedIds: asset IDs that have been intentionally deleted from the target database.
// Records whose IDs are in this set will not be inserted into the target even if they exist in source.
// (Zig: the TypeScript optional onLocalChange is passed as null.)
//
pub fn syncDatabase(
    allocator: std.mem.Allocator,
    io: std.Io,
    sourceBsonDatabase: *BsonDatabase,
    targetBsonDatabase: *BsonDatabase,
    targetDeletedIds: *const std.StringArrayHashMapUnmanaged(void),
    onLocalChange: ?SyncChangeCallback,
) !void {
    const sourceDbTree = try (try sourceBsonDatabase.merkleTree()).get(io);
    const targetDbTree = try (try targetBsonDatabase.merkleTree()).get(io);

    if (sourceDbTree != null and sourceDbTree.?.merkle != null and targetDbTree != null and targetDbTree.?.merkle != null) { //todo: move this comparison to the iterateDatabaseDifferences function.
        if (std.mem.eql(u8, sourceDbTree.?.merkle.?.hash, targetDbTree.?.merkle.?.hash)) {
            log.verbose("Databases are identical, no sync needed.");
            return;
        }
    }

    log.info("Finding differing records using hierarchical merkle trees...");

    var state: SyncDatabaseState = .{
        .allocator = allocator,
        .io = io,
        .targetBsonDatabase = targetBsonDatabase,
        .targetDeletedIds = targetDeletedIds,
        .onLocalChange = onLocalChange,
    };

    // Process differing records as they're found (using generator)
    try iterateDatabaseDifferences(allocator, io, sourceBsonDatabase, targetBsonDatabase, .{
        .context = &state,
        .function = SyncDatabaseState.visit,
    });

    if (state.mergedCount == 0) {
        log.info("No differing records found.");
    }
    else {
        log.info(try std.fmt.allocPrint(allocator, "Sync completed: {d} records merged.", .{state.mergedCount}));
    }
}
