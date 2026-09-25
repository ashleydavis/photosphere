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

//
// Path for the files Merkle tree (v6). Legacy path was .db/tree.dat.
// The files tree stores hash, length, and lastModified of the logical (plain/decrypted)
// content of each file only, so that plain and encrypted databases compare equal via compare.
//
pub const FILES_TREE_PATH = ".db/files.dat";

// Not ported: ENCRYPTION_PUB_PATH and isDatabaseEncrypted (psi sync, not psi replicate or psi verify).

//
// Checks if the merkle tree exists.
//
pub fn merkleTreeExists(allocator: std.mem.Allocator, io: std.Io, assetStorage: IStorage) !bool {
    return try assetStorage.fileExists(allocator, io, FILES_TREE_PATH);
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

// Not ported: stampDatabaseState, stampDatabaseModified (psi add, psi sync and the other commands that
// modify a database, not psi replicate or psi verify).

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

// Not ported: IBuildFilesTreeResult, buildFilesTree (psi debug, not psi replicate or psi verify).
