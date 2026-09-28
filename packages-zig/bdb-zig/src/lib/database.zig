//
// Implements a BSON-based database that can store multiple collections of documents.
//

const std = @import("std");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const collection_zig = @import("collection.zig");
const merkle_tree = @import("merkle-tree.zig");
const merkle_tree_ref = @import("merkle-tree-ref.zig");
const IStorage = storage_zig.storage.IStorage;
const pathJoin = storage_zig.storage_factory.pathJoin;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const ITimestampProvider = utils.timestamp_provider.ITimestampProvider;
const IMerkleTree = merkle_tree_zig.merkle_tree.IMerkleTree;
const BsonCollection = collection_zig.BsonCollection;
const IBsonCollection = collection_zig.IBsonCollection;
const MerkleRef = merkle_tree_ref.MerkleRef;
const errors = utils.errors;

//
// (Zig: IBsonDatabase has a single implementation, so callers use *BsonDatabase directly.)
//
pub const IBsonDatabase = BsonDatabase;

//
// A BSON database (TypeScript: the BsonDatabase class).
// (Zig: create it with init, which allocates it on the heap, because its collections point back at it.)
//
pub const BsonDatabase = struct {

    //
    // Allocates the collections and everything the database keeps (normally an arena).
    //
    allocator: std.mem.Allocator,

    //
    // Caches created collections.
    //
    _collections: std.StringArrayHashMapUnmanaged(*BsonCollection) = .empty,

    //
    // Lazily-created ref for the database-level merkle tree.
    //
    _merkleRef: ?*MerkleRef = null,

    //
    // Aggregate dirty flag: true if any collection is dirty since last commit.
    //
    dirty: bool = false,

    //
    // The storage holding the database files.
    //
    storage: IStorage,

    //
    // The database root in storage.
    //
    bsonDbPath: []const u8,

    //
    // Generates ids for new merkle trees and sort index pages.
    //
    uuidGenerator: IUuidGenerator,

    //
    // Provides the current time to collections.
    //
    timestampProvider: ITimestampProvider,

    //
    // Creates a database (TypeScript: the constructor).
    //
    pub fn init(allocator: std.mem.Allocator, storage: IStorage, bsonDbPath: []const u8, uuidGenerator: IUuidGenerator, timestampProvider: ITimestampProvider) !*BsonDatabase {
        const database = try allocator.create(BsonDatabase);
        database.* = .{
            .allocator = allocator,
            .storage = storage,
            .bsonDbPath = bsonDbPath,
            .uuidGenerator = uuidGenerator,
            .timestampProvider = timestampProvider,
        };
        return database;
    }

    //
    // Marks the database as having uncommitted changes.
    //
    fn markDirty(self: *BsonDatabase) void {
        self.dirty = true;
    }

    //
    // The onDirty callback given to collections (TypeScript: `() => this.markDirty()`).
    //
    fn markDirtyCallback(context: *anyopaque) void {
        const self: *BsonDatabase = @ptrCast(@alignCast(context));
        self.markDirty();
    }

    //
    // Clears the dirty flag after a successful commit.
    //
    fn clearDirty(self: *BsonDatabase) void {
        self.dirty = false;
    }

    //
    // Gets the names of all collections in the database.
    //
    pub fn collections(self: *BsonDatabase, io: std.Io) ![]const []const u8 {

        var uniqueSet: std.StringArrayHashMapUnmanaged(void) = .empty;

        const collectionsPath = try pathJoin(self.allocator, &.{ self.bsonDbPath, "collections" });
        if (try self.storage.dirExists(self.allocator, io, collectionsPath)) {
            var next: ?[]const u8 = null;
            while (true) {
                const storageResult = try self.storage.listDirs(self.allocator, io, collectionsPath, 1000, next);
                for (storageResult.names) |name| {
                    try uniqueSet.put(self.allocator, name, {});
                }
                next = storageResult.next;
                if (next == null) {
                    break;
                }
            }
        }

        for (self._collections.keys()) |name| {
            try uniqueSet.put(self.allocator, name, {});
        }

        return uniqueSet.keys();
    }

    //
    // Gets a named collection (v6 layout: directory = collections/<name>).
    //
    pub fn collection(self: *BsonDatabase, name: []const u8) !*IBsonCollection {
        if (self._collections.get(name)) |cached| {
            return cached;
        }
        const ownedName = try self.allocator.dupe(u8, name);
        const newCollection = try self.allocator.create(BsonCollection);
        newCollection.* = BsonCollection.init(
            self.allocator,
            ownedName,
            self.bsonDbPath,
            self.storage,
            self.bsonDbPath,
            self.uuidGenerator,
            self.timestampProvider,
            .{ .context = self, .function = markDirtyCallback },
        );
        try self._collections.put(self.allocator, ownedName, newCollection);
        return newCollection;
    }

    //
    // Flushes all pending writes to disk across all collections and updates the database merkle tree.
    // Dirty flags are cleared; the in-memory cache remains populated for fast subsequent reads.
    //
    pub fn commit(self: *BsonDatabase, io: std.Io) !void {
        if (!self.dirty) {
            return;
        }

        for (self._collections.keys(), self._collections.values()) |collName, coll| {
            if (!coll.dirty()) {
                continue;
            }

            try coll.commit(io);

            const collMerkleRef = try coll.merkleTree();
            const collMerkle = try collMerkleRef.get(io);
            const databaseMerkleRef = try self.merkleTree();
            if (collMerkle != null and collMerkle.?.merkle != null) {
                try databaseMerkleRef.upsert(io, .{
                    .name = collName,
                    .hash = collMerkle.?.merkle.?.hash,
                    .length = collMerkle.?.merkle.?.nodeCount,
                    .lastModified = std.Io.Clock.real.now(io).toMilliseconds(),
                });
            }
            else {
                try databaseMerkleRef.remove(io, collName);
            }
        }

        const merkleRef = try self.merkleTree();
        try merkleRef.commit(io);
        self.clearDirty();
    }

    //
    // Drops every cached collection's shards, sort indexes and merkle trees, and the database merkle tree, so the
    // next access reloads them from storage. Throws when the database has uncommitted changes.
    //
    pub fn flush(self: *BsonDatabase) !void {
        if (self.dirty) {
            return errors.throwError("Cannot flush: database has uncommitted changes. Call commit() first.", .{});
        }

        for (self._collections.values()) |coll| {
            try coll.flush();
        }

        if (self._merkleRef) |merkleRef| {
            try merkleRef.flush();
        }
        self._merkleRef = null;
    }

    //
    // Returns the database-level merkle ref, creating it on first use.
    //
    pub fn merkleTree(self: *BsonDatabase) !*MerkleRef {
        if (self._merkleRef == null) {
            const merkleRef = try self.allocator.create(MerkleRef);
            merkleRef.* = MerkleRef.init(self.allocator, self, merkleLoader, merkleSaver, merkleDeleter, merkleCreator);
            self._merkleRef = merkleRef;
        }
        return self._merkleRef.?;
    }

    //
    // The merkle ref loader (TypeScript: the first arrow function in merkleTree()).
    //
    fn merkleLoader(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!?IMerkleTree {
        const self: *BsonDatabase = @ptrCast(@alignCast(context));
        return try merkle_tree.loadDatabaseMerkleTree(allocator, io, self.storage, self.bsonDbPath);
    }

    //
    // The merkle ref saver.
    //
    fn merkleSaver(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io, tree: *IMerkleTree) anyerror!void {
        const self: *BsonDatabase = @ptrCast(@alignCast(context));
        return merkle_tree.saveDatabaseMerkleTree(allocator, io, self.storage, self.bsonDbPath, tree);
    }

    //
    // The merkle ref deleter.
    //
    fn merkleDeleter(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!void {
        const self: *BsonDatabase = @ptrCast(@alignCast(context));
        return merkle_tree.deleteDatabaseMerkleTree(allocator, io, self.storage, self.bsonDbPath);
    }

    //
    // The merkle ref creator.
    //
    fn merkleCreator(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!IMerkleTree {
        const self: *BsonDatabase = @ptrCast(@alignCast(context));
        return merkle_tree_zig.merkle_tree.createTree(try self.uuidGenerator.generate(allocator, io));
    }
};
