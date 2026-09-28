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
const collection_zig = @import("collection.zig");
const bson = serialization_zig.bson;
const merkle_tree = merkle_tree_zig.merkle_tree;
const IMerkleTree = merkle_tree.IMerkleTree;
const HashedItem = merkle_tree.HashedItem;
const IStorage = storage_zig.storage.IStorage;
const pathJoin = storage_zig.storage_factory.pathJoin;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const IInternalRecord = shard_zig.IInternalRecord;
const BsonCollection = collection_zig.BsonCollection;
const TimestampProvider = utils.timestamp_provider.TimestampProvider;
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

//
// Sort predicate for shard ids: `shardIds.sort(compareNames)`.
//
fn compareNamesLessThan(context: void, leftName: []const u8, rightName: []const u8) bool {
    _ = context;
    return merkle_tree.compareNames(leftName, rightName) < 0;
}

//
// Lists existing shard IDs in a collection.
//
pub fn listShards(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, bsonDbPath: []const u8, collectionName: []const u8) ![]const []const u8 {
    const shardsDir = try pathJoin(allocator, &.{ bsonDbPath, "collections", collectionName, "shards" });
    var shardIds: std.ArrayList([]const u8) = .empty;
    var next: ?[]const u8 = null;

    while (true) {
        const storageResult = try storage.listFiles(allocator, io, shardsDir, 1000, next);
        for (storageResult.names) |fileName| {
            if (std.mem.indexOfScalar(u8, fileName, '.') != null) {
                continue;
            }
            try shardIds.append(allocator, fileName);
        }
        next = storageResult.next;
        // `while (next)`: an empty token ends the listing like a missing one.
        if (!utils.js_string.isTruthy(next)) {
            break;
        }
    }

    std.mem.sort([]const u8, shardIds.items, {}, compareNamesLessThan);
    return shardIds.items;
}

//
// The onDirty callback given to the collection that buildCollectionMerkleTree reads shards through
// (TypeScript: `() => {}`). The collection is never written to, so there is nothing to propagate.
//
fn ignoreDirty(context: *anyopaque) void {
    _ = context;
}

//
// Builds a merkle tree for a collection with shard root hashes as leaves.
//
pub fn buildCollectionMerkleTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    storage: IStorage,
    bsonDbPath: []const u8,
    collectionName: []const u8,
    uuidGenerator: IUuidGenerator,
    rebuild: bool,
) !IMerkleTree {

    const shardIds = try listShards(allocator, io, storage, bsonDbPath, collectionName);
    var collectionTree = merkle_tree.createTree(try uuidGenerator.generate(allocator, io));

    for (shardIds) |shardId| {
        const timestampProvider = try allocator.create(TimestampProvider);
        timestampProvider.* = .{};
        const collection = try allocator.create(BsonCollection);
        collection.* = BsonCollection.init(
            allocator,
            collectionName,
            bsonDbPath,
            storage,
            bsonDbPath,
            uuidGenerator,
            timestampProvider.timestampProvider(),
            .{ .context = collection, .function = ignoreDirty },
        );
        const records = try (try collection.shard(shardId)).records(io);
        var shardTree: ?IMerkleTree = null;

        if (records.count() == 0) {
            // If the shard is empty, delete the tree file instead of saving it
            try deleteShardMerkleTree(allocator, io, storage, bsonDbPath, collectionName, shardId);
        }
        else if (rebuild) {
            shardTree = try buildShardMerkleTree(allocator, io, records.values(), uuidGenerator);
            try saveShardMerkleTree(allocator, io, storage, bsonDbPath, collectionName, shardId, &shardTree.?);
        }
        else {
            shardTree = try loadShardMerkleTree(allocator, io, storage, bsonDbPath, collectionName, shardId);
            if (shardTree == null) {
                // Shard tree doesn't exist, build it.
                shardTree = try buildShardMerkleTree(allocator, io, records.values(), uuidGenerator);
                try saveShardMerkleTree(allocator, io, storage, bsonDbPath, collectionName, shardId, &shardTree.?);
            }
        }

        if (shardTree != null and shardTree.?.merkle != null) {
            const shardKey = shardId;
            const hashedItem: HashedItem = .{
                .name = shardKey,
                .hash = shardTree.?.merkle.?.hash,
                .length = shardTree.?.merkle.?.nodeCount,
                .lastModified = std.Io.Clock.real.now(io).toMilliseconds(),
            };
            collectionTree = try merkle_tree.addItem(allocator, &collectionTree, hashedItem);
        }
    }

    return collectionTree;
}

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

//
// Lists all collections in the database (v6: databaseDir = "collections").
//
fn listCollections(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, bsonDbPath: []const u8) ![]const []const u8 {
    var uniqueSet: std.StringArrayHashMapUnmanaged(void) = .empty;
    var next: ?[]const u8 = null;
    while (true) {
        const storageResult = try storage.listDirs(allocator, io, try pathJoin(allocator, &.{ bsonDbPath, "collections" }), 1000, next);
        for (storageResult.names) |name| {
            try uniqueSet.put(allocator, name, {});
        }
        next = storageResult.next;
        // `while (next)`: an empty token ends the listing like a missing one.
        if (!utils.js_string.isTruthy(next)) {
            break;
        }
    }

    return uniqueSet.keys();
}

//
// Builds a merkle tree for a database with collection root hashes as leaves.
//
pub fn buildDatabaseMerkleTree(
    allocator: std.mem.Allocator,
    io: std.Io,
    storage: IStorage,
    bsonDbPath: []const u8,
    uuidGenerator: IUuidGenerator,
    preloadedCollectionName: ?[]const u8,
    preloadedCollectionTree: ?IMerkleTree,
    rebuild: bool,
) !IMerkleTree {

    const collections = try listCollections(allocator, io, storage, bsonDbPath);

    var databaseTree = merkle_tree.createTree(try uuidGenerator.generate(allocator, io));

    for (collections) |collectionName| {
        var collectionTree: ?IMerkleTree = null;
        if (preloadedCollectionName != null and std.mem.eql(u8, preloadedCollectionName.?, collectionName)) {
            // Use the pre-loaded collection tree.
            collectionTree = preloadedCollectionTree;
        }
        else if (rebuild) {
            // Rebuild the collection tree.
            collectionTree = try buildCollectionMerkleTree(allocator, io, storage, bsonDbPath, collectionName, uuidGenerator, rebuild);
            if (collectionTree.?.sort == null) {
                // Collection tree is empty, delete it.
                collectionTree = null;
                try deleteCollectionMerkleTree(allocator, io, storage, bsonDbPath, collectionName);
            }
            else {
                try saveCollectionMerkleTree(allocator, io, storage, bsonDbPath, collectionName, &collectionTree.?);
            }
        }
        else {
            // Load the collection tree.
            collectionTree = try loadCollectionMerkleTree(allocator, io, storage, bsonDbPath, collectionName);
            if (collectionTree == null) {
                // Collection tree doesn't exist, build it.
                collectionTree = try buildCollectionMerkleTree(allocator, io, storage, bsonDbPath, collectionName, uuidGenerator, rebuild);
                if (collectionTree.?.sort == null) {
                    // Collection tree is empty, delete it.
                    collectionTree = null;
                    try deleteCollectionMerkleTree(allocator, io, storage, bsonDbPath, collectionName);
                }
                else {
                    try saveCollectionMerkleTree(allocator, io, storage, bsonDbPath, collectionName, &collectionTree.?);
                }
            }
        }

        if (collectionTree != null and collectionTree.?.merkle != null) {
            const hashedItem: HashedItem = .{
                .name = collectionName,
                .hash = collectionTree.?.merkle.?.hash,
                .length = collectionTree.?.merkle.?.nodeCount,
                .lastModified = std.Io.Clock.real.now(io).toMilliseconds(),
            };
            databaseTree = try merkle_tree.addItem(allocator, &databaseTree, hashedItem);
        }
    }

    return databaseTree;
}

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

// Not ported: databaseMerkleTreeExists (not used by psi replicate or psi verify).

//
// Gets the root hash for the database from its merkle tree.
// Returns undefined if the database merkle tree doesn't exist or has no root hash.
//
pub fn getDatabaseRootHash(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, bsonDbPath: []const u8) !?[]const u8 {
    const tree = try loadDatabaseMerkleTree(allocator, io, storage, bsonDbPath) orelse {
        return null;
    };
    const merkle = tree.merkle orelse {
        return null;
    };
    return merkle.hash;
}
