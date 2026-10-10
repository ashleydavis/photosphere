const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const storage_zig = @import("storage-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const task_queue_zig = @import("task-queue-zig");
const api = @import("api-zig");
const open_storage = @import("open-storage.zig");
const tree = @import("tree.zig");
const media_file_database = @import("media-file-database.zig");
const errors = utils.errors;
const log = &utils.log.log;
const IStorage = storage_zig.storage.IStorage;
const IMerkleTree = merkle_tree_zig.merkle_tree.IMerkleTree;
const SortNode = merkle_tree_zig.merkle_tree.SortNode;
const iterateLeaves = merkle_tree_zig.merkle_tree.iterateLeaves;
const ITaskContext = task_queue_zig.types.ITaskContext;
const IEvictionCandidate = api.retention_policy.IEvictionCandidate;
const IRetentionContext = api.retention_policy.IRetentionContext;
const RetentionPolicy = api.retention_policy.RetentionPolicy;
const ACTIVE_RETENTION_POLICY = api.retention_policy.ACTIVE_RETENTION_POLICY;
const loadDatabaseConfig = api.database_config.loadDatabaseConfig;
const openStorage = open_storage.openStorage;
const loadMerkleTree = tree.loadMerkleTree;
const saveMerkleTree = tree.saveMerkleTree;

//
// Drops local original files that the origin already holds, so the local database can stay small.
//
// Only the original and the transcoded display copy go. The thumbnail and the micro thumbnail stay
// on the device, which is what keeps the gallery browsable with no network at all. An evicted
// original is fetched back from the origin on demand by LazyOriginStorage, which is why the
// database is marked partial the moment anything is evicted: that flag is what makes reads lazy and
// what stops verify reporting the now-absent files as corruption.
//

//
// Payload for the evict-originals task.
// (Zig: the `= ""` and `= null` defaults let std.json parse data that leaves the keys out.)
//
pub const IEvictOriginalsData = struct {
    // Path of the local database to evict from.
    databasePath: []const u8 = "",

    // Identifies the session. Reserved for the write lock if eviction ever needs one.
    sessionId: []const u8 = "",

    // Keep local originals under this many bytes, instead of using the active retention policy.
    // Null uses ACTIVE_RETENTION_POLICY, which is what the desktop and mobile apps do. The CLI
    // exposes this as --evict-budget for anyone who wants a different cap on one machine without
    // rebuilding, and it is what lets the smoke tests exercise eviction with ordinary-sized photos
    // rather than needing more than the policy's default cap of test data.
    localOriginalBudgetBytes: ?f64 = null,
};

//
// What an eviction run did.
//
pub const IEvictOriginalsResult = struct {
    // The assets whose local original was dropped.
    evictedAssetIds: []const []const u8,

    // How many bytes were freed on the device.
    freedBytes: f64,

    // Why nothing was evicted, when nothing was. Null when the run went ahead.
    // (Zig: the `= null` default lets std.json parse a result that leaves the key out.)
    skippedReason: ?[]const u8 = null,
};

//
// One file the local database holds, as the merkle tree records it.
//
pub const ILocalFile = struct {
    // The hash the tree records for the file, lower-case hex.
    contentHash: []const u8,

    // The size in bytes the tree records for the file.
    sizeBytes: f64,

    // When the tree last saw the file change, in milliseconds since the epoch.
    lastModifiedMs: f64,
};

//
// A map of file name to file, in the order the files were added.
//
pub const LocalFileMap = std.StringArrayHashMapUnmanaged(ILocalFile);

//
// Every file in a merkle tree under one of the given directory prefixes, by name.
//
fn indexTreeFiles(allocator: std.mem.Allocator, merkleTree: ?IMerkleTree, prefixes: []const []const u8) !LocalFileMap {
    var files: LocalFileMap = .empty;
    const foundTree = merkleTree orelse {
        return files;
    };

    var leaves = iterateLeaves(SortNode, allocator, foundTree.sort);
    while (try leaves.next()) |leaf| {
        const leafName = leaf.name orelse {
            continue;
        };
        if (leafName.len == 0) {
            continue;
        }
        const leafContentHash = leaf.contentHash orelse {
            continue;
        };
        var hasPrefix = false;
        for (prefixes) |prefix| {
            if (std.mem.startsWith(u8, leafName, prefix)) {
                hasPrefix = true;
            }
        }
        if (!hasPrefix) {
            continue;
        }
        try files.put(allocator, leafName, .{
            .contentHash = try utils.hex.toHex(allocator, leafContentHash),
            .sizeBytes = @floatFromInt(leaf.size),
            .lastModifiedMs = if (leaf.lastModified) |lastModified| @floatFromInt(lastModified) else 0,
        });
    }

    return files;
}

//
// How many bytes are free on the filesystem holding the given path.
//
// Reports zero for a path that is not on a local filesystem (an S3 database, say), because there is
// no device to run out of space on. It never guesses: a filesystem it cannot measure is reported as
// unmeasurable by throwing, so a policy that reads free space cannot act on a made-up number.
//
pub fn getDeviceFreeBytes(allocator: std.mem.Allocator, io: std.Io, databasePath: []const u8) !f64 {
    const localPath = if (std.mem.startsWith(u8, databasePath, "fs:")) databasePath["fs:".len..] else databasePath;
    if (std.mem.indexOf(u8, localPath, "://") != null or std.mem.startsWith(u8, databasePath, "s3:")) {
        return 0;
    }

    // A database directory that does not exist yet still sits on a filesystem, and that filesystem
    // is the one that can run out of space, so the nearest existing ancestor is what to measure.
    var candidatePath = try node_utils.path.resolve(allocator, io, localPath);
    while (true) {
        if (node_utils.node_fs.statfsPath(allocator, candidatePath)) |stats| {
            return @as(f64, @floatFromInt(stats.bavail)) * @as(f64, @floatFromInt(stats.bsize));
        }
        else |err| {
            if (err != error.FileNotFound) {
                return err;
            }
        }

        const parentPath = node_utils.path.dirname(candidatePath);
        if (std.mem.eql(u8, parentPath, candidatePath)) {
            return errors.throwError("Could not measure free space for \"{s}\": no ancestor directory of it exists.", .{databasePath});
        }
        candidatePath = parentPath;
    }
}

//
// The assets whose local original could be dropped, and how the device is placed.
//
pub fn buildEvictionCandidates(
    allocator: std.mem.Allocator,
    localFiles: LocalFileMap,
    originFiles: LocalFileMap,
) ![]IEvictionCandidate {
    var candidates: std.ArrayList(IEvictionCandidate) = .empty;

    for (localFiles.keys(), localFiles.values()) |name, localFile| {
        if (!std.mem.startsWith(u8, name, "asset/")) {
            continue;
        }

        const assetId = name["asset/".len..];
        const originFile = originFiles.get(name);

        try candidates.append(allocator, .{
            .assetId = assetId,
            .originalSizeBytes = localFile.sizeBytes,
            .importedAtMs = localFile.lastModifiedMs,
            // Nothing records when an asset was last looked at, so no policy may depend on it.
            .lastViewedAtMs = null,
            .confirmedOnOrigin = originFile != null and std.mem.eql(u8, originFile.?.contentHash, localFile.contentHash),
        });
    }

    return candidates.items;
}

//
// Deletes a file if it is there, and reports how many bytes went. A file that is already gone frees
// nothing and is not an error: that is the state the caller wanted.
//
fn deleteIfPresent(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, filePath: []const u8, sizeBytes: f64) !f64 {
    if (!try storage.fileExists(allocator, io, filePath)) {
        return 0;
    }
    try storage.deleteFile(allocator, io, filePath);
    return sizeBytes;
}

//
// Gets `config?.origin` when it is a non-empty string (null otherwise).
//
fn configOrigin(config: ?std.json.Value) ?[]const u8 {
    const value = config orelse {
        return null;
    };
    const object = switch (value) {
        .object => |object| object,
        else => {
            return null;
        },
    };
    const origin = object.get("origin") orelse {
        return null;
    };
    return switch (origin) {
        .string => |text| if (text.len > 0) text else null,
        else => null,
    };
}

//
// Converts the eviction result to the JSON value returned as the task output.
//
fn evictResultToJson(allocator: std.mem.Allocator, result: IEvictOriginalsResult) !std.json.Value {
    const text = try std.json.Stringify.valueAlloc(allocator, result, .{
        .emit_null_optional_fields = false,
    });
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

//
// Drops the local originals the active retention policy selects.
// (Zig: the task data and output are JSON values holding IEvictOriginalsData and IEvictOriginalsResult.)
//
pub fn evictOriginalsHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    const data = std.json.parseFromValueLeaky(IEvictOriginalsData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errors.throwError("The evict-originals task data is not valid: databasePath and sessionId must be strings, and localOriginalBudgetBytes must be a number", .{});
    };
    if (data.databasePath.len == 0) {
        return errors.throwError("databasePath is required", .{});
    }

    const local = try openStorage(allocator, io, data.databasePath, null, null, context.hostRequester);
    const localStorage = local.storage;
    const localRawStorage = local.rawStorage;

    const config = try loadDatabaseConfig(allocator, io, localRawStorage);
    const origin = configOrigin(config) orelse {
        // With nowhere to fetch an evicted original back from, dropping it would lose it.
        return evictResultToJson(allocator, .{
            .evictedAssetIds = &.{},
            .freedBytes = 0,
            .skippedReason = "no origin configured",
        });
    };

    var localMerkleTree = try loadMerkleTree(allocator, io, localStorage) orelse {
        return evictResultToJson(allocator, .{
            .evictedAssetIds = &.{},
            .freedBytes = 0,
            .skippedReason = "no local merkle tree",
        });
    };

    const originStorage = (try openStorage(allocator, io, origin, null, null, context.hostRequester)).storage;
    const originMerkleTree = try loadMerkleTree(allocator, io, originStorage) orelse {
        return evictResultToJson(allocator, .{
            .evictedAssetIds = &.{},
            .freedBytes = 0,
            .skippedReason = try std.fmt.allocPrint(allocator, "origin not accessible ({s})", .{origin}),
        });
    };

    const localFiles = try indexTreeFiles(allocator, localMerkleTree, &.{ "asset/", "display/" });
    const originFiles = try indexTreeFiles(allocator, originMerkleTree, &.{ "asset/", "display/" });

    const candidates = try buildEvictionCandidates(allocator, localFiles, originFiles);

    var totalLocalOriginalBytes: f64 = 0;
    for (candidates) |candidate| {
        totalLocalOriginalBytes += candidate.originalSizeBytes;
    }

    const retentionContext: IRetentionContext = .{
        .totalLocalOriginalBytes = totalLocalOriginalBytes,
        .deviceFreeBytes = try getDeviceFreeBytes(allocator, io, data.databasePath),
        .nowMs = @floatFromInt(std.Io.Clock.real.now(io).toMilliseconds()),
    };

    const policy: RetentionPolicy = if (data.localOriginalBudgetBytes) |budgetBytes| .{
        .sizeBudget = .{
            .budgetBytes = budgetBytes,
        },
    } else ACTIVE_RETENTION_POLICY;

    const selectedAssetIds = try policy.selectForEviction(allocator, candidates, retentionContext);
    var confirmedAssetIds: std.StringHashMapUnmanaged(void) = .empty;
    for (candidates) |candidate| {
        if (candidate.confirmedOnOrigin) {
            try confirmedAssetIds.put(allocator, candidate.assetId, {});
        }
    }

    var evictedAssetIds: std.ArrayList([]const u8) = .empty;
    var freedBytes: f64 = 0;

    for (selectedAssetIds) |assetId| {
        if (context.isCancelled()) {
            break;
        }

        // The policy is not trusted with the one rule that matters. A policy with a bug that
        // selected an unconfirmed asset would delete the user's only copy, so it is checked here as
        // well as inside every policy.
        if (!confirmedAssetIds.contains(assetId)) {
            log.@"error"(try std.fmt.allocPrint(allocator, "Retention policy selected asset {s} for eviction, but the origin does not hold a matching original. Keeping it.", .{assetId}));
            continue;
        }

        const originalName = try std.fmt.allocPrint(allocator, "asset/{s}", .{assetId});
        freedBytes += try deleteIfPresent(allocator, io, localStorage, originalName, if (localFiles.get(originalName)) |localFile| localFile.sizeBytes else 0);

        // The display copy goes only if the origin holds a matching one of its own. Thumbnails and
        // micro thumbnails are never touched: they are what keeps the gallery usable offline.
        const displayName = try std.fmt.allocPrint(allocator, "display/{s}", .{assetId});
        const localDisplay = localFiles.get(displayName);
        const originDisplay = originFiles.get(displayName);
        if (localDisplay != null and originDisplay != null and std.mem.eql(u8, localDisplay.?.contentHash, originDisplay.?.contentHash)) {
            freedBytes += try deleteIfPresent(allocator, io, localStorage, displayName, localDisplay.?.sizeBytes);
        }

        try evictedAssetIds.append(allocator, assetId);
    }

    if (evictedAssetIds.items.len > 0 and !media_file_database.isPartialDatabase(localMerkleTree.databaseMetadata)) {
        // Originals are now missing locally and are fetched from the origin on demand, which is
        // exactly what partial means. Recording it is what makes reads lazy and stops verify
        // treating the absent files as damage.
        var databaseMetadata = if (localMerkleTree.databaseMetadata) |existing|
            try media_file_database.copyDatabaseMetadata(allocator, existing)
        else
            try media_file_database.emptyDatabaseMetadata(allocator);
        try databaseMetadata.put(allocator, "isPartial", .{
            .boolean = true,
        });
        localMerkleTree.databaseMetadata = databaseMetadata;
        try saveMerkleTree(allocator, io, &localMerkleTree, localStorage);
    }

    return evictResultToJson(allocator, .{
        .evictedAssetIds = evictedAssetIds.items,
        .freedBytes = freedBytes,
        .skippedReason = null,
    });
}
