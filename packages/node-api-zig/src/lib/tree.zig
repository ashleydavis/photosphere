const std = @import("std");
const utils = @import("utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const storage_zig = @import("storage-zig");
const bdb = @import("bdb-zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const errors = utils.errors;
const IMerkleTree = merkle_tree.IMerkleTree;
const IStorage = storage_zig.storage.IStorage;

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

// Not ported: getFilesRootHash (psi summary and psi root-hash, not psi replicate or psi verify).

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
