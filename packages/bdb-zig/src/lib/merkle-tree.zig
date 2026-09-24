//
// Merkle tree utilities for BSON database.
//

const std = @import("std");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const storage_zig = @import("storage-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const json_stable_stringify = @import("json-stable-stringify.zig");
const js_value = @import("js-value.zig");
const shard_zig = @import("shard.zig");
const bson = serialization_zig.bson;
const merkle_tree = merkle_tree_zig.merkle_tree;
const IMerkleTree = merkle_tree.IMerkleTree;
const HashedItem = merkle_tree.HashedItem;
const IStorage = storage_zig.storage.IStorage;
const pathJoin = storage_zig.storage_factory.pathJoin;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const IInternalRecord = shard_zig.IInternalRecord;
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// Hashes a record and returns a HashedItem.
// (Zig: `io` reads the clock for `new Date()`. The hash is a new 32 byte allocation.)
//
pub fn hashRecord(allocator: std.mem.Allocator, io: std.Io, recordId: []const u8, fields: bson.BsonDocument) !HashedItem {
    const jsonString = try json_stable_stringify.stringifyDocument(allocator, fields);
    const recordHash = try allocator.alloc(u8, Sha256.digest_length);
    Sha256.hash(jsonString, recordHash[0..Sha256.digest_length], .{});
    return .{
        .name = recordId,
        .hash = recordHash,
        .length = js_value.utf16Length(jsonString),
        .lastModified = std.Io.Clock.real.now(io).toMilliseconds(),
    };
}

//
// Builds a merkle tree for a shard with record hashes as leaves.
// Records are sorted by their _id before being added to the tree.
//
pub fn buildShardMerkleTree(allocator: std.mem.Allocator, io: std.Io, records: []const IInternalRecord, uuidGenerator: IUuidGenerator) !IMerkleTree {

    var merkleTree = merkle_tree.createTree(try uuidGenerator.generate(allocator, io));

    for (records) |record| {
        const hashedItem = try hashRecord(allocator, io, record._id, record.fields);
        merkleTree = try merkle_tree.addItem(allocator, &merkleTree, hashedItem);
    }

    return merkleTree;
}

//
// Saves a shard merkle tree next to the shard file.
//
pub fn saveShardMerkleTree(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, bsonDbPath: []const u8, collectionName: []const u8, shardId: []const u8, tree: *IMerkleTree) !void {

    if (tree.dirty) {
        tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort);
        tree.dirty = false;
    }

    const shardFilePath = try pathJoin(allocator, &.{ bsonDbPath, "collections", collectionName, "shards", shardId });
    const treeFilePath = try std.fmt.allocPrint(allocator, "{s}.dat", .{shardFilePath});
    try merkle_tree.saveTree(allocator, io, treeFilePath, tree, storage, "COLT");
}

//
// Deletes a shard merkle tree file.
//
pub fn deleteShardMerkleTree(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, bsonDbPath: []const u8, collectionName: []const u8, shardId: []const u8) !void {
    const shardFilePath = try pathJoin(allocator, &.{ bsonDbPath, "collections", collectionName, "shards", shardId });
    const treeFilePath = try std.fmt.allocPrint(allocator, "{s}.dat", .{shardFilePath});
    try storage.deleteFile(allocator, io, treeFilePath);
}

//
// Loads a shard merkle tree.
//
pub fn loadShardMerkleTree(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, bsonDbPath: []const u8, collectionName: []const u8, shardId: []const u8) !?IMerkleTree {
    const shardFilePath = try pathJoin(allocator, &.{ bsonDbPath, "collections", collectionName, "shards", shardId });
    const treeFilePath = try std.fmt.allocPrint(allocator, "{s}.dat", .{shardFilePath});
    return merkle_tree.loadTree(allocator, io, treeFilePath, storage, "COLT");
}

// Not ported: listShards, buildCollectionMerkleTree (only used to rebuild trees, not by psi replicate or psi verify).

//
// Saves a collection merkle tree in the collection directory.
//
pub fn saveCollectionMerkleTree(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, bsonDbPath: []const u8, collectionName: []const u8, tree: *IMerkleTree) !void {

    if (tree.dirty) {
        tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort);
        tree.dirty = false;
    }

    const treeFilePath = try pathJoin(allocator, &.{ bsonDbPath, "collections", collectionName, "collection.dat" });
    try merkle_tree.saveTree(allocator, io, treeFilePath, tree, storage, "COLT");
}

//
// Loads a collection merkle tree.
//
pub fn loadCollectionMerkleTree(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, bsonDbPath: []const u8, collectionName: []const u8) !?IMerkleTree {
    const treeFilePath = try pathJoin(allocator, &.{ bsonDbPath, "collections", collectionName, "collection.dat" });
    return merkle_tree.loadTree(allocator, io, treeFilePath, storage, "COLT");
}

//
// Deletes a collection merkle tree file.
//
pub fn deleteCollectionMerkleTree(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, bsonDbPath: []const u8, collectionName: []const u8) !void {
    const treeFilePath = try pathJoin(allocator, &.{ bsonDbPath, "collections", collectionName, "collection.dat" });
    try storage.deleteFile(allocator, io, treeFilePath);
}

// Not ported: listCollections, buildDatabaseMerkleTree (only used to rebuild trees, not by psi replicate or psi verify).

//
// Saves a database merkle tree.
//
pub fn saveDatabaseMerkleTree(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, bsonDbPath: []const u8, tree: *IMerkleTree) !void {

    if (tree.dirty) {
        tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort);
        tree.dirty = false;
    }

    const treeFilePath = try pathJoin(allocator, &.{ bsonDbPath, "db.dat" });
    try merkle_tree.saveTree(allocator, io, treeFilePath, tree, storage, "BDBT");
}

//
// Loads a database merkle tree. path is the storage prefix under which the tree file is stored.
//
pub fn loadDatabaseMerkleTree(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, bsonDbPath: []const u8) !?IMerkleTree {
    const treeFilePath = try pathJoin(allocator, &.{ bsonDbPath, "db.dat" });
    return merkle_tree.loadTree(allocator, io, treeFilePath, storage, "BDBT");
}

//
// Deletes a database merkle tree file.
//
pub fn deleteDatabaseMerkleTree(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, bsonDbPath: []const u8) !void {
    const treeFilePath = try pathJoin(allocator, &.{ bsonDbPath, "db.dat" });
    try storage.deleteFile(allocator, io, treeFilePath);
}

// Not ported: databaseMerkleTreeExists, getDatabaseRootHash (not used by psi replicate or psi verify).
