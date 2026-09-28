const std = @import("std");
const utils = @import("utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const storage_zig = @import("storage-zig");
const bdb = @import("bdb-zig");
const api = @import("api-zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const errors = utils.errors;
const IMerkleTree = merkle_tree.IMerkleTree;
const IStorage = storage_zig.storage.IStorage;
const IDatabaseState = api.database_state.IDatabaseState;
const js_date = @import("serialization-zig").js_date;
const media_file_database = @import("media-file-database.zig");
const retry_operations = @import("retry-operations.zig");
const retry = utils.retry.retry;
const batchGenerator = utils.batch_generator.batchGenerator;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const walk_directory = storage_zig.walk_directory;
const IOrderedFile = walk_directory.IOrderedFile;
const BsonDocument = @import("serialization-zig").bson.BsonDocument;
const LARGE_FILE_TIMEOUT = api.constants.LARGE_FILE_TIMEOUT;

//
// Path for the files Merkle tree (v6). Legacy path was .db/tree.dat.
// The files tree stores hash, length, and lastModified of the logical (plain/decrypted)
// content of each file only, so that plain and encrypted databases compare equal via compare.
//
pub const FILES_TREE_PATH = ".db/files.dat";

//
// Path for the encryption public-key marker (indicates database is encrypted).
//
const ENCRYPTION_PUB_PATH = ".db/encryption.pub";

//
// Checks if the merkle tree exists.
//
pub fn merkleTreeExists(allocator: std.mem.Allocator, io: std.Io, assetStorage: IStorage) !bool {
    return try assetStorage.fileExists(allocator, io, FILES_TREE_PATH);
}

//
// Returns true if the database has an encryption marker (storage is scoped to db root).
//
pub fn isDatabaseEncrypted(allocator: std.mem.Allocator, io: std.Io, assetStorage: IStorage) !bool {
    return try assetStorage.fileExists(allocator, io, ENCRYPTION_PUB_PATH);
}

//
// Saves the merkle tree to disk.
// (Zig: the tree's database metadata is the BSON document described by IDatabaseMetadata.)
//
pub fn saveMerkleTree(allocator: std.mem.Allocator, io: std.Io, merkleTree: ?*IMerkleTree, assetStorage: IStorage) !void {
    const tree = merkleTree orelse {
        return errors.throwError("Cannot save database. No merkle tree provided.", .{});
    };

    if (tree.dirty) {
        tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort);
        tree.dirty = false;
    }

    try merkle_tree.saveTree(allocator, io, FILES_TREE_PATH, tree, assetStorage, "FTRE");
}

//
// Loads the merkle tree from disk.
//
pub fn loadMerkleTree(allocator: std.mem.Allocator, io: std.Io, assetStorage: IStorage) !?IMerkleTree {
    return try merkle_tree.loadTree(allocator, io, FILES_TREE_PATH, assetStorage, "FTRE");
}

//
// Gets the root hash for the files merkle tree.
// Returns undefined if the merkle tree doesn't exist or has no root hash.
//
pub fn getFilesRootHash(allocator: std.mem.Allocator, io: std.Io, assetStorage: IStorage) !?[]const u8 {
    const tree = try loadMerkleTree(allocator, io, assetStorage) orelse {
        return null;
    };
    const merkle = tree.merkle orelse {
        return null;
    };
    return merkle.hash;
}

//
// BSON database path within a database (v6 layout).
//
const BSON_DB_PATH = ".db/bson";

//
// Computes the combined content hash of the database: the files-tree root combined with the bson-db-tree root.
// Two databases with the same content hash are identical. Returns undefined if either root is unavailable
// (e.g. an empty database), in which case callers skip the content-hash based sync early-out.
//
pub fn getDatabaseContentHash(allocator: std.mem.Allocator, io: std.Io, assetStorage: IStorage) !?[]const u8 {
    const filesRootHash = try getFilesRootHash(allocator, io, assetStorage) orelse {
        return null;
    };
    const bsonRootHash = try bdb.merkle_tree.getDatabaseRootHash(allocator, io, assetStorage, BSON_DB_PATH) orelse {
        return null;
    };
    const combined = merkle_tree.combineHashes(filesRootHash, bsonRootHash);
    return try allocator.dupe(u8, &combined);
}

//
// Builds the state-file partial for a stamp: the given fields plus the database's current content hash
// (only when both merkle trees are available, so an empty database does not clear an existing hash).
//
fn buildStampPartial(allocator: std.mem.Allocator, io: std.Io, assetStorage: IStorage, extra: IDatabaseState) !IDatabaseState {
    var partial: IDatabaseState = extra;
    const contentHash = try getDatabaseContentHash(allocator, io, assetStorage);
    if (contentHash) |hash| {
        partial.contentHash = hash;
    }
    return partial;
}

//
// Refreshes the content hash in the state file together with the given fields (e.g. lastModifiedAt or
// lastSyncedAt). Lock-free: the caller must already hold the database write lock and should call this as
// the last step of the locked mutation, after the merkle tree and bson database are persisted. A crash
// between persisting the trees and this call leaves the previous content hash, which only causes an extra
// full sync (which self-heals the state file), never data loss.
//
pub fn stampDatabaseState(allocator: std.mem.Allocator, io: std.Io, assetStorage: IStorage, rawStorage: IStorage, extra: IDatabaseState) !void {
    try api.database_state.mergeDatabaseState(allocator, io, rawStorage, try buildStampPartial(allocator, io, assetStorage, extra));
}

//
// Records that the database was modified locally: stamps lastModifiedAt and refreshes the content hash.
// Lock-free: the caller must already hold the database write lock.
//
pub fn stampDatabaseModified(allocator: std.mem.Allocator, io: std.Io, assetStorage: IStorage, rawStorage: IStorage) !void {
    var lastModifiedAt: std.Io.Writer.Allocating = .init(allocator);
    try js_date.writeIsoString(&lastModifiedAt.writer, std.Io.Clock.real.now(io).toMilliseconds());
    try stampDatabaseState(allocator, io, assetStorage, rawStorage, .{
        .lastModifiedAt = lastModifiedAt.written(),
    });
}

//
// Refreshes the content hash in the state file together with the given fields (e.g. lastSyncedAt or
// lastReplicatedAt), acquiring the write lock for the duration. For callers that do not already hold the
// lock (replicate, repair). Does nothing if the lock cannot be acquired.
//
pub fn stampDatabaseStateLocked(allocator: std.mem.Allocator, io: std.Io, assetStorage: IStorage, rawStorage: IStorage, sessionId: []const u8, extra: IDatabaseState) !void {
    try api.database_state.updateDatabaseStateLocked(allocator, io, rawStorage, sessionId, try buildStampPartial(allocator, io, assetStorage, extra));
}

//
// Loads a collection Merkle tree by collection name (v6 path: collections/<name>).
//
pub fn loadCollectionMerkleTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    storage: IStorage,
    collectionName: []const u8,
) !?IMerkleTree {
    return bdb.merkle_tree.loadCollectionMerkleTree(allocator, io, storage, ".db/bson", collectionName);
}

//
// Loads a shard Merkle tree by collection name and shard ID (v6 path: collections/<name>/shards/<id>).
//
pub fn loadShardMerkleTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    storage: IStorage,
    collectionName: []const u8,
    shardId: []const u8,
) !?IMerkleTree {
    return bdb.merkle_tree.loadShardMerkleTree(allocator, io, storage, ".db/bson", collectionName, shardId);
}

//
// Result of buildFilesTree: the rebuilt tree and the number of files included.
//
pub const IBuildFilesTreeResult = struct {
    // The rebuilt files tree.
    merkleTree: IMerkleTree,

    // The number of files in the rebuilt tree.
    fileCount: u64,
};

//
// Called by buildFilesTree with the number of files hashed so far (TypeScript: `(fileCount: number) => void`).
//
pub const IBuildFilesTreeProgress = struct {
    // The state of the callback, passed to function.
    context: ?*anyopaque,

    // The callback function.
    function: *const fn (context: ?*anyopaque, fileCount: u64) void,

    //
    // Invokes the callback.
    //
    pub fn call(self: IBuildFilesTreeProgress, fileCount: u64) void {
        self.function(self.context, fileCount);
    }
};

//
// Matches /^\.db(\/|$)/: the .db directory and everything below it.
//
fn matchesDbDirectory(fullPath: []const u8) bool {
    return std.mem.eql(u8, fullPath, ".db") or std.mem.startsWith(u8, fullPath, ".db/");
}

//
// A file read and hashed by buildFilesTree (TypeScript: what the readAndHash inner function resolves to).
//
const IReadAndHashResult = struct {
    // The file name in storage.
    fileName: []const u8,

    // The hash of the file's logical content.
    hash: [32]u8,

    // The length of the file.
    length: u64,

    // When the file was last modified (milliseconds since the Unix epoch).
    lastModified: i64,
};

//
// Gets a file's info and hashes it (TypeScript: the readAndHash inner function of buildFilesTree).
//
fn readAndHash(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, fileName: []const u8) !IReadAndHashResult {
    var infoOperation: retry_operations.InfoOperation("() => storage.info(fileName)") = .{
        .allocator = allocator,
        .storage = storage,
        .fileName = fileName,
    };
    const info = try retry(io, &infoOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwError("No info for file listed in storage: {s}", .{fileName});
    };
    var hashOperation: retry_operations.ComputeStorageHashOperation("async () => computeHash(await storage.readStream(fileName))") = .{
        .allocator = allocator,
        .storage = storage,
        .fileName = fileName,
    };
    const hash = try retry(io, &hashOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, try std.fmt.allocPrint(allocator, "Failed to hash file {s}", .{fileName}));
    return .{
        .fileName = fileName,
        .hash = hash,
        .length = info.length,
        .lastModified = info.lastModified,
    };
}

//
// Reads and hashes one file of a batch (TypeScript: the `({ fileName }) => readAndHash(fileName)` arrow function
// that `batch.map` runs). Runs concurrently with the rest of its batch, with its own allocator because the caller's
// is not shared between threads.
//
const ReadAndHashTask = struct {
    // The storage holding the file.
    storage: IStorage,

    // The file to hash.
    fileName: []const u8,

    // The result, set when the task succeeded.
    result: ?IReadAndHashResult = null,

    // The error the task failed with, or null when it succeeded.
    failure: ?anyerror = null,

    // The message of the error the task failed with, captured on the thread that ran it.
    errorRecord: errors.ErrorRecord = .{},

    //
    // Reads and hashes the file, recording the error when it fails.
    //
    fn run(self: *ReadAndHashTask, io: std.Io) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        if (readAndHash(arena.allocator(), io, self.storage, self.fileName)) |result| {
            self.result = result;
        }
        else |err| {
            self.failure = err;
            errors.captureError(&self.errorRecord);
        }
    }
};

//
// Builds the files merkle tree from storage: walks only paths that belong in the tree
// (asset/, display/, thumb/; skips .db/). Hashes each file via storage (logical content
// when encrypted), upserts into tree, saves once. Reads and hashes up to BATCH_SIZE
// files in parallel per batch to overlap I/O.
//
pub fn buildFilesTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    storage: IStorage,
    progressCallback: IBuildFilesTreeProgress,
    uuidGenerator: IUuidGenerator,
) !IBuildFilesTreeResult {
    var loadOperation: retry_operations.LoadMerkleTreeOperation("() => loadMerkleTree(storage)") = .{
        .allocator = allocator,
        .storage = storage,
    };
    const existingTree = try retry(io, &loadOperation, 3, 1_000, 2, 30_000, null);
    const newTreeId = if (existingTree) |existing| existing.id else try uuidGenerator.generate(allocator, io);
    var merkleTree = merkle_tree.createTree(newTreeId);
    var databaseMetadata: BsonDocument = undefined;
    if (existingTree != null and existingTree.?.databaseMetadata != null) {
        databaseMetadata = try media_file_database.copyDatabaseMetadata(allocator, existingTree.?.databaseMetadata.?);
    }
    else {
        databaseMetadata = try media_file_database.emptyDatabaseMetadata(allocator);
    }
    var filesImported: u64 = 0;
    var fileCount: u64 = 0;

    const BATCH_SIZE = 100;
    const ignorePatterns = [_]walk_directory.IgnorePattern{matchesDbDirectory};
    var files = try walk_directory.walkDirectory(allocator, io, storage, "", &ignorePatterns);
    var batches = batchGenerator(IOrderedFile, allocator, &files, BATCH_SIZE);
    while (try batches.next()) |batch| {
        const tasks = try allocator.alloc(ReadAndHashTask, batch.len);
        for (batch, tasks) |file, *task| {
            task.* = .{
                .storage = storage,
                .fileName = file.fileName,
            };
        }

        var group: std.Io.Group = .init;
        for (tasks) |*task| {
            group.async(io, ReadAndHashTask.run, .{ task, io });
        }
        try group.await(io);

        for (tasks) |*task| {
            if (task.failure) |failure| {
                errors.restoreError(&task.errorRecord);
                return failure;
            }
        }

        for (tasks) |*task| {
            const result = task.result.?;
            merkleTree = try merkle_tree.upsertItem(allocator, &merkleTree, .{
                .name = result.fileName,
                .hash = try allocator.dupe(u8, &result.hash),
                .length = result.length,
                .lastModified = result.lastModified,
            });
            fileCount += 1;
            if (std.mem.startsWith(u8, result.fileName, "asset/")) {
                filesImported += 1;
            }
            progressCallback.call(fileCount);
        }
    }

    try databaseMetadata.put(allocator, "filesImported", .{ .number = @floatFromInt(filesImported) });
    merkleTree.databaseMetadata = databaseMetadata;
    var saveOperation: retry_operations.SaveMerkleTreeOperation("() => saveMerkleTree(merkleTree, storage)") = .{
        .allocator = allocator,
        .merkleTree = &merkleTree,
        .storage = storage,
    };
    try retry(io, &saveOperation, 3, 1_000, 2, 30_000, null);
    return .{
        .merkleTree = merkleTree,
        .fileCount = fileCount,
    };
}
