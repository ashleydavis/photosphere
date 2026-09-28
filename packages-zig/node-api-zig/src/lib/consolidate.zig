const std = @import("std");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const serialization_zig = @import("serialization-zig");
const bdb = @import("bdb-zig");
const api = @import("api-zig");
const media_file_database = @import("media-file-database.zig");
const replicate_module = @import("replicate.zig");
const tree = @import("tree.zig");
const sync = @import("sync.zig");
const retry_operations = @import("retry-operations.zig");
const errors = utils.errors;
const log = &utils.log.log;
const retry = utils.retry.retry;
const ITimestampProvider = utils.timestamp_provider.ITimestampProvider;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const IStorage = storage_zig.storage.IStorage;
const merkle_tree = merkle_tree_zig.merkle_tree;
const IMerkleTree = merkle_tree.IMerkleTree;
const SortNode = merkle_tree.SortNode;
const addItem = merkle_tree.addItem;
const iterateLeaves = merkle_tree.iterateLeaves;
const BsonDocument = serialization_zig.bson.BsonDocument;
const BsonValue = serialization_zig.bson.BsonValue;
const BsonDatabase = bdb.database.BsonDatabase;
const acquireWriteLock = api.write_lock.acquireWriteLock;
const releaseWriteLock = api.write_lock.releaseWriteLock;
const updateDatabaseConfig = api.database_config.updateDatabaseConfig;
const replicate = replicate_module.replicate;
const releaseWriteLockAfter = sync.releaseWriteLockAfter;

//
// Joining a standalone local database to a remote that already has photos in it.
//
// Sync refuses to work between two databases that are not related, and this does not weaken that
// refusal: consolidation is a separate, explicit operation that makes them related. It works by
// content hash rather than by asset id, because two databases that grew up apart gave different ids
// to the same photo, and the id says nothing about whether the remote already has the content.
//
// Afterwards the local database is a partial replica of the remote: it has adopted the remote's
// database id, named it as its origin, and been marked partial, so ordinary sync applies from then
// on.
//

//
// The three kinds of file an asset has in storage. The micro thumbnail lives inside the metadata
// record, not in storage, so it is not listed here.
//
const ASSET_FILE_PREFIXES = [_][]const u8{ "asset/", "display/", "thumb/" };

//
// What consolidation would do, worked out from the two merkle trees alone.
//
pub const IConsolidationPlan = struct {
    // Local assets whose original the remote does not hold. Their content and metadata are pushed.
    absentAssetIds: []const []const u8,

    // Local assets whose original the remote already holds under some id. Nothing of theirs is
    // pushed, because the remote's copy is the one that survives.
    presentAssetIds: []const []const u8,
};

//
// Every content hash a merkle tree holds an original for, lower-case hex.
//
fn originalHashes(allocator: std.mem.Allocator, merkleTree: ?*const IMerkleTree) !std.StringHashMap(void) {
    var hashes = std.StringHashMap(void).init(allocator);
    const hashedTree = merkleTree orelse {
        return hashes;
    };

    var leaves = iterateLeaves(SortNode, allocator, hashedTree.sort);
    while (try leaves.next()) |leaf| {
        if (leaf.name == null or leaf.name.?.len == 0 or leaf.contentHash == null) {
            continue;
        }
        if (!std.mem.startsWith(u8, leaf.name.?, "asset/")) {
            continue;
        }
        try hashes.put(try std.ascii.allocLowerString(allocator, try hexOf(allocator, leaf.contentHash.?)), {});
    }

    return hashes;
}

//
// A content hash as hex (TypeScript: `contentHash.toString("hex")`, which is lower-case).
// (No TypeScript counterpart: the conversion is inline.)
//
fn hexOf(allocator: std.mem.Allocator, contentHash: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{x}", .{contentHash});
}

//
// Works out which local assets the remote is missing, by content hash.
//
pub fn planConsolidation(
    allocator: std.mem.Allocator,
    localTree: ?*const IMerkleTree,
    remoteTree: ?*const IMerkleTree,
) !IConsolidationPlan {
    const remoteHashes = try originalHashes(allocator, remoteTree);

    var absentAssetIds: std.ArrayList([]const u8) = .empty;
    var presentAssetIds: std.ArrayList([]const u8) = .empty;

    const local = localTree orelse {
        return .{
            .absentAssetIds = absentAssetIds.items,
            .presentAssetIds = presentAssetIds.items,
        };
    };

    var leaves = iterateLeaves(SortNode, allocator, local.sort);
    while (try leaves.next()) |leaf| {
        if (leaf.name == null or leaf.name.?.len == 0 or leaf.contentHash == null) {
            continue;
        }
        if (!std.mem.startsWith(u8, leaf.name.?, "asset/")) {
            continue;
        }

        const assetId = leaf.name.?["asset/".len..];
        if (remoteHashes.contains(try std.ascii.allocLowerString(allocator, try hexOf(allocator, leaf.contentHash.?)))) {
            try presentAssetIds.append(allocator, assetId);
        }
        else {
            try absentAssetIds.append(allocator, assetId);
        }
    }

    return .{
        .absentAssetIds = absentAssetIds.items,
        .presentAssetIds = presentAssetIds.items,
    };
}

//
// What a consolidation run did.
//
pub const IConsolidationResult = struct {
    // How many local assets were pushed to the remote.
    pushedCount: u64,

    // How many local assets the remote already had, and were dropped locally in favour of the
    // remote's copy.
    alreadyPresentCount: u64,

    // The database id the local database now shares with the remote.
    databaseId: []const u8,
};

//
// Reports progress as consolidation works through the assets.
// (Zig: a closure; `function` is called with `context`.)
//
pub const IConsolidationProgressCallback = struct {
    // The state of the callback, passed to function.
    context: ?*anyopaque,

    // The callback function.
    function: *const fn (context: ?*anyopaque, pushed: u64, total: u64) void,

    //
    // Invokes the callback.
    //
    pub fn call(self: IConsolidationProgressCallback, pushed: u64, total: u64) void {
        self.function(self.context, pushed, total);
    }
};

//
// Copies one file between storages if the source has it, and returns what it copied so the caller
// can record it in the destination's merkle tree.
//
fn copyAssetFile(allocator: std.mem.Allocator, io: std.Io, fileName: []const u8, sourceStorage: IStorage, destStorage: IStorage) !bool {
    if (!try sourceStorage.fileExists(allocator, io, fileName)) {
        return false;
    }

    var infoOperation: retry_operations.InfoOperation("() => sourceStorage.info(fileName)") = .{
        .allocator = allocator,
        .storage = sourceStorage,
        .fileName = fileName,
    };
    const info = try retry(io, &infoOperation, 3, 1_000, 2, 30_000, null) orelse {
        return false;
    };

    var copyOperation: retry_operations.CopyStreamOperation("async () => {\n    const readStream = await sourceStorage.readStream(fileName);\n    await destStorage.writeStream(fileName, info.contentType, readStream);\n  }") = .{
        .allocator = allocator,
        .sourceStorage = sourceStorage,
        .destStorage = destStorage,
        .fileName = fileName,
        .contentType = info.contentType,
    };
    try retry(io, &copyOperation, 3, 1_000, 2, 30_000, null);

    return true;
}

//
// Pushes the local assets the remote does not have into it, drops the local copies of the ones it
// already has, and re-stamps the local database as a partial replica of the remote.
//
pub fn consolidateDatabases(
    allocator: std.mem.Allocator,
    io: std.Io,
    localPath: []const u8,
    localStorage: IStorage,
    localRawStorage: IStorage,
    localBsonDatabase: *BsonDatabase,
    remotePath: []const u8,
    remoteStorage: IStorage,
    remoteRawStorage: IStorage,
    remoteBsonDatabase: *BsonDatabase,
    sessionId: []const u8,
    uuidGenerator: IUuidGenerator,
    timestampProvider: ITimestampProvider,
    onProgress: ?IConsolidationProgressCallback,
) !IConsolidationResult {
    var loadLocalOperation: retry_operations.LoadMerkleTreeOperation("() => loadMerkleTree(localStorage)") = .{
        .allocator = allocator,
        .storage = localStorage,
    };
    const localTree = try retry(io, &loadLocalOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwError("Failed to load the merkle tree of the local database at {s}.", .{localPath});
    };

    var loadRemoteOperation: retry_operations.LoadMerkleTreeOperation("() => loadMerkleTree(remoteStorage)") = .{
        .allocator = allocator,
        .storage = remoteStorage,
    };
    var remoteTree = try retry(io, &loadRemoteOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwError("Failed to load the merkle tree of the remote database at {s}.", .{remotePath});
    };

    if (std.mem.eql(u8, localTree.id, remoteTree.id)) {
        // Already related, so there is nothing to consolidate: ordinary sync covers this case.
        return .{
            .pushedCount = 0,
            .alreadyPresentCount = 0,
            .databaseId = remoteTree.id,
        };
    }

    const plan = try planConsolidation(allocator, &localTree, &remoteTree);

    // --- Push what the remote does not have. ---

    try localBsonDatabase.flush();

    if (!try acquireWriteLock(allocator, io, remoteRawStorage, sessionId, 3)) {
        return errors.throwError("Failed to acquire the write lock on the remote database at {s}.", .{remotePath});
    }

    var pushedCount: u64 = 0;
    const pushed = pushAbsentAssets(allocator, io, localStorage, localBsonDatabase, remoteStorage, remoteRawStorage, remoteBsonDatabase, &localTree, &remoteTree, plan, onProgress, &pushedCount);
    try releaseWriteLockAfter(allocator, io, remoteRawStorage, pushed);

    // --- Make the local database a partial replica of the remote. ---

    if (!try acquireWriteLock(allocator, io, localRawStorage, sessionId, 3)) {
        return errors.throwError("Failed to acquire the write lock on the local database at {s}.", .{localPath});
    }

    const joined = joinAsPartialReplica(allocator, io, localStorage, localRawStorage, remotePath, remoteStorage, remoteBsonDatabase, uuidGenerator, timestampProvider, plan);
    try releaseWriteLockAfter(allocator, io, localRawStorage, joined);

    return .{
        .pushedCount = pushedCount,
        .alreadyPresentCount = plan.presentAssetIds.len,
        .databaseId = remoteTree.id,
    };
}

//
// The body of consolidateDatabases' first try block, run holding the remote's write lock.
// (No TypeScript counterpart: the try block is written inline. remoteTree and pushedCount are updated through the
// pointers, where TypeScript reassigns the variables.)
//
fn pushAbsentAssets(
    allocator: std.mem.Allocator,
    io: std.Io,
    localStorage: IStorage,
    localBsonDatabase: *BsonDatabase,
    remoteStorage: IStorage,
    remoteRawStorage: IStorage,
    remoteBsonDatabase: *BsonDatabase,
    localTree: *const IMerkleTree,
    remoteTree: *IMerkleTree,
    plan: IConsolidationPlan,
    onProgress: ?IConsolidationProgressCallback,
    pushedCount: *u64,
) !void {
    const localMetadata = try localBsonDatabase.collection("metadata");
    const remoteMetadata = try remoteBsonDatabase.collection("metadata");

    for (plan.absentAssetIds) |assetId| {
        var assetRecord = try localMetadata.getOne(io, assetId) orelse {
            // The tree names a file the metadata knows nothing about. Pushing the bytes with no
            // record would put an asset in the remote that nothing can show, so it is reported
            // and skipped rather than half-pushed.
            log.@"error"(try std.fmt.allocPrint(allocator, "Consolidation skipped asset {s}: the local database has the file but no metadata record for it.", .{assetId}));
            continue;
        };

        for (ASSET_FILE_PREFIXES) |prefix| {
            const fileName = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, assetId });
            if (!try copyAssetFile(allocator, io, fileName, localStorage, remoteStorage)) {
                continue;
            }

            var infoOperation: retry_operations.InfoOperation("() => remoteStorage.info(fileName)") = .{
                .allocator = allocator,
                .storage = remoteStorage,
                .fileName = fileName,
            };
            const info = try retry(io, &infoOperation, 3, 1_000, 2, 30_000, null);
            const localItem = if (localTree.sort != null) try findLeaf(allocator, localTree, fileName) else null;
            if (info == null or localItem == null or localItem.?.contentHash == null) {
                return errors.throwError("Consolidation copied {s} to the remote but could not record it in the remote's merkle tree.", .{fileName});
            }

            remoteTree.* = try addItem(allocator, remoteTree, .{
                .name = fileName,
                .hash = localItem.?.contentHash.?,
                .length = localItem.?.size,
                .lastModified = localItem.?.lastModified orelse std.Io.Clock.real.now(io).toMilliseconds(),
            });
        }

        try remoteMetadata.insertOne(io, &assetRecord, null);
        pushedCount.* += 1;
        if (onProgress) |progressCallback| {
            progressCallback.call(pushedCount.*, plan.absentAssetIds.len);
        }
    }

    var databaseMetadata = remoteTree.databaseMetadata orelse try media_file_database.emptyDatabaseMetadata(allocator);
    const filesImported = databaseMetadata.get("filesImported") orelse BsonValue.undefined;
    const filesImportedNumber = if (filesImported == .undefined) std.math.nan(f64) else try bdb.js_value.toNumber(allocator, filesImported);
    try databaseMetadata.put(allocator, "filesImported", .{ .number = filesImportedNumber + @as(f64, @floatFromInt(pushedCount.*)) });
    remoteTree.databaseMetadata = databaseMetadata;

    var saveOperation: retry_operations.SaveMerkleTreeOperation("() => saveMerkleTree(remoteTree, remoteStorage)") = .{
        .allocator = allocator,
        .merkleTree = remoteTree,
        .storage = remoteStorage,
    };
    try retry(io, &saveOperation, 3, 1_000, 2, 30_000, null);
    try remoteBsonDatabase.commit(io);
    try tree.stampDatabaseModified(allocator, io, remoteStorage, remoteRawStorage);
}

//
// The body of consolidateDatabases' second try block, run holding the local database's write lock.
// (No TypeScript counterpart: the try block is written inline.)
//
fn joinAsPartialReplica(
    allocator: std.mem.Allocator,
    io: std.Io,
    localStorage: IStorage,
    localRawStorage: IStorage,
    remotePath: []const u8,
    remoteStorage: IStorage,
    remoteBsonDatabase: *BsonDatabase,
    uuidGenerator: IUuidGenerator,
    timestampProvider: ITimestampProvider,
    plan: IConsolidationPlan,
) !void {
    // The local originals the remote already had are dropped. The remote's copy of that content
    // is the one that survives, under the remote's own asset id, and keeping the local file
    // would leave a copy nothing refers to.
    for (plan.presentAssetIds) |assetId| {
        for (ASSET_FILE_PREFIXES) |prefix| {
            const fileName = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, assetId });
            if (try localStorage.fileExists(allocator, io, fileName)) {
                var deleteOperation: retry_operations.DeleteFileOperation("() => localStorage.deleteFile(fileName)") = .{
                    .allocator = allocator,
                    .storage = localStorage,
                    .filePath = fileName,
                };
                try retry(io, &deleteOperation, 3, 1_000, 2, 30_000, null);
            }
        }
    }

    // The local records go entirely, and the remote's take their place. Everything the local
    // database knew is now on the remote, either because it was pushed just now or because the
    // remote already had it, so nothing is lost. Leaving the local records in place would be
    // worse than useless: the merkle trees copied down next describe the remote's records, and
    // a stale local record file would be read in preference to fetching the remote's.
    try localStorage.deleteDir(allocator, io, ".db/bson");

    // Replicating the remote down as a partial replica is what adopts the remote's database id,
    // its merkle trees and its record set in one step, and marks the local database partial so
    // the originals it does not hold are fetched from the origin when they are wanted. `force`
    // is needed precisely because the two ids differ: making them the same is the point.
    _ = try replicate(
        allocator,
        io,
        remotePath,
        remoteStorage,
        remoteBsonDatabase,
        uuidGenerator,
        timestampProvider,
        localStorage,
        localRawStorage,
        .{
            .partial = true,
            .force = true,
        },
        null,
    );

    try updateDatabaseConfig(allocator, io, localRawStorage, .{
        .origin = remotePath,
    });
}

//
// Finds the leaf for a file name in a merkle tree, or undefined when it is not there.
//
fn findLeaf(allocator: std.mem.Allocator, merkleTree: *const IMerkleTree, fileName: []const u8) !?*SortNode {
    var leaves = iterateLeaves(SortNode, allocator, merkleTree.sort);
    while (try leaves.next()) |leaf| {
        if (leaf.name != null and std.mem.eql(u8, leaf.name.?, fileName)) {
            return leaf;
        }
    }
    return null;
}
