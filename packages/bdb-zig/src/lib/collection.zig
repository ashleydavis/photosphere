//
// A collection in a database that stores BSON records in a sharded format.
//

const std = @import("std");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const sort_index = @import("sort-index.zig");
const merkle_tree = @import("merkle-tree.zig");
const merkle_tree_ref = @import("merkle-tree-ref.zig");
const shard_zig = @import("shard.zig");
const errors = utils.errors;
const IStorage = storage_zig.storage.IStorage;
const IListResult = storage_zig.storage.IListResult;
const pathJoin = storage_zig.storage_factory.pathJoin;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const ITimestampProvider = utils.timestamp_provider.ITimestampProvider;
const IMerkleTree = merkle_tree_zig.merkle_tree.IMerkleTree;
const SortIndex = sort_index.SortIndex;
const SortDirection = sort_index.SortDirection;
const MerkleRef = merkle_tree_ref.MerkleRef;
const BsonShard = shard_zig.BsonShard;
const IInternalRecord = shard_zig.IInternalRecord;
const Md5 = std.crypto.hash.Md5;

//
// A callback that tells the owner of an object that the object became dirty
// (TypeScript: the `onDirty: () => void` arrow functions passed to constructors).
//
pub const DirtyCallback = struct {
    // The object to notify.
    context: *anyopaque,

    // The function to call with the context.
    function: *const fn (context: *anyopaque) void,
};

//
// How many shards a collection keeps loaded before it starts dropping the ones it used longest ago.
//
// A shard holds every record in it, so this is the ceiling on how much of a collection is in memory
// at once. Eight is enough that the handful of shards a write touches together all stay, and small
// enough that walking a whole collection does not end up holding it: a sync's record merge visits
// every differing shard on both sides, and holding them all is what ran a phone out of memory.
//
const MAX_CACHED_SHARDS = 8;

// Not ported: ISortIndexCreationOptions, IRecord, Metadata, toInternal, toExternal, IGetAllResult (only used by
// insertOne, getOne, getAll, updateOne and replaceOne, which psi replicate and psi verify do not use).

//
// Number of shard buckets for record distribution (record id hash mod NUM_SHARDS).
//
const NUM_SHARDS = 100;

//
// BSON collection API: CRUD, sort indexes, sharding, and deferred commit/flush.
// (Zig: IBsonCollection has a single implementation, so callers use *BsonCollection directly.)
//
pub const IBsonCollection = BsonCollection;

//
// The field and direction of a sort index (TypeScript: the anonymous `{ fieldName, direction }` type).
//
pub const ISortIndexInfo = struct {
    // The indexed field.
    fieldName: []const u8,

    // The sort direction.
    direction: SortDirection,
};

//
// Iterates all records of a collection shard by shard (TypeScript: the iterateRecords async generator).
//
pub const RecordIterator = struct {
    // The collection being iterated.
    collection: *BsonCollection,

    // The next shard to load.
    shardId: u32 = 0,

    // The records of the current shard.
    shardRecords: []IInternalRecord = &.{},

    // The index of the next record in the current shard.
    recordIndex: usize = 0,

    //
    // Returns the next record, or null when every shard has been iterated.
    //
    pub fn next(self: *RecordIterator, io: std.Io) !?IInternalRecord {
        while (self.recordIndex >= self.shardRecords.len) {
            if (self.shardId >= NUM_SHARDS) {
                return null;
            }
            const shardName = try std.fmt.allocPrint(self.collection.allocator, "{d}", .{self.shardId});
            const shard = try self.collection.shard(shardName);
            const recordMap = try shard.records(io);
            self.shardRecords = recordMap.values();
            self.recordIndex = 0;
            self.shardId += 1;
        }
        const record = self.shardRecords[self.recordIndex];
        self.recordIndex += 1;
        return record;
    }
};

//
// Iterates the non-empty shards of a collection (TypeScript: the iterateShards async generator).
//
pub const ShardIterator = struct {
    // The collection being iterated.
    collection: *BsonCollection,

    // The next shard to load.
    shardId: u32 = 0,

    // The ids of the shards to read; null until the first call to next() lists them.
    shardIdsToRead: ?std.StringHashMapUnmanaged(void) = null,

    //
    // Returns the records of the next shard that has records, or null when every shard has been iterated.
    //
    pub fn next(self: *ShardIterator, io: std.Io) !?[]IInternalRecord {
        const allocator = self.collection.allocator;
        if (self.shardIdsToRead == null) {
            // The shards that exist are listed once, rather than reading all NUM_SHARDS of them to find
            // out. A shard file that was never written still costs a storage read to discover, and on a
            // remote store that read is a network round trip: scanning an empty collection cost 100 of
            // them, and building the two sort indexes a new database starts with cost 200.
            //
            // That is what made 41-s3-database-lifecycle fail in CI. Creating a database on S3 from an
            // emulator on QEMU's NAT spent over five minutes on those round trips and was killed before
            // it finished, while the same test takes 24 seconds against a bridged emulator where the
            // host is a fast hop away. One list in place of a hundred reads removes the difference
            // rather than widening the timeout until it fits.
            const shardsPath = try pathJoin(allocator, &.{ self.collection.bsonDbPath, "collections", self.collection.name, "shards" });
            var shardIdsToRead: std.StringHashMapUnmanaged(void) = .empty;
            var nextToken: ?[]const u8 = null;
            while (true) {
                const listed: IListResult = try self.collection.storage.listFiles(allocator, io, shardsPath, NUM_SHARDS, nextToken);
                for (listed.names) |name| {
                    try shardIdsToRead.put(allocator, name, {});
                }
                nextToken = listed.next;
                if (nextToken == null) {
                    break;
                }
            }

            // Shards already held in memory are included whether or not they have been written yet.
            // Records live in the shard cache from the moment they are inserted until a commit flushes
            // them, so a listing on its own would miss everything written since the last commit.
            for (self.collection.shardCache.keys()) |cachedShardId| {
                try shardIdsToRead.put(allocator, cachedShardId, {});
            }

            self.shardIdsToRead = shardIdsToRead;
        }

        while (self.shardId < NUM_SHARDS) {
            const shardName = try std.fmt.allocPrint(allocator, "{d}", .{self.shardId});
            self.shardId += 1;
            if (!self.shardIdsToRead.?.contains(shardName)) {
                continue;
            }
            const shard = try self.collection.shard(shardName);
            const recordMap = try shard.records(io);
            if (recordMap.count() > 0) {
                return recordMap.values();
            }
        }
        return null;
    }
};

//
// Sharded BSON document store: records partitioned into shard files, sort indexes, and merkle trees.
// Writes are buffered until commit(); flush() drops caches after a successful commit.
// (Zig: the collection must stay at the same address, because its shards, sort indexes and merkle ref point back
// at it. The database allocates its collections on the heap.)
//
pub const BsonCollection = struct {
    //
    // Allocates the caches and everything the collection keeps (normally an arena).
    //
    allocator: std.mem.Allocator,

    //
    // Collection id.
    //
    name: []const u8,

    //
    // Database root in storage (shard/merkle paths use bsonDbPath/collections/name/...).
    //
    bsonDbPath: []const u8,

    //
    // Backing storage for shard files, merkle files, and sort indexes.
    //
    storage: IStorage,

    //
    // Root passed to sort indexes (indexes/...); usually the same path as bsonDbPath.
    //
    baseDirectory: []const u8,

    //
    // UUID generator for creating unique identifiers.
    //
    uuidGenerator: IUuidGenerator,

    //
    // Timestamp provider for generating timestamps.
    //
    timestampProvider: ITimestampProvider,

    //
    // Cache of sort indexes, keyed by "fieldName_direction".
    // Each sort index lazily loads from disk on first use.
    //
    sortIndexCache: std.StringArrayHashMapUnmanaged(*SortIndex) = .empty,

    // Shard cache; each shard carries a dirty flag until commit (BSON + merkle).
    //
    // Bounded, and least-recently-used first out. A shard holds every record in it, so an unbounded
    // cache holds the whole collection once enough of it has been touched, and a sync's record merge
    // touches every differing shard on both sides. Measured on a Pixel 6 against a database of 8,231
    // photos, that merge aborted the app three times: "Scudo ERROR: internal map failure (error
    // desc=Out of memory)", `malloc` failing inside the embedded engine, thirteen to eighteen minutes
    // in, having pushed nothing.
    shardCache: std.StringArrayHashMapUnmanaged(*BsonShard) = .empty,

    // Lazily-created ref for this collection's merkle tree.
    _merkleRef: ?*MerkleRef = null,

    // Aggregate dirty flag: true if any child is dirty since last commit
    _dirty: bool = false,

    // Callback to notify the database when this collection first becomes dirty.
    onDirtyCallback: DirtyCallback,

    //
    // name: collection id; bsonDbPath: database root in storage (shard/merkle paths use bsonDbPath/collections/name/...).
    // baseDirectory: BSON root passed to sort indexes (usually same as bsonDbPath).
    // onDirty: invoked on first transition to dirty each commit cycle.
    //
    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        bsonDbPath: []const u8,
        storage: IStorage,
        baseDirectory: []const u8,
        uuidGenerator: IUuidGenerator,
        timestampProvider: ITimestampProvider,
        onDirty: DirtyCallback,
    ) BsonCollection {
        return .{
            .allocator = allocator,
            .name = name,
            .bsonDbPath = bsonDbPath,
            .storage = storage,
            .baseDirectory = baseDirectory,
            .uuidGenerator = uuidGenerator,
            .timestampProvider = timestampProvider,
            .onDirtyCallback = onDirty,
        };
    }

    //
    // True if this collection has uncommitted changes since the last commit.
    //
    pub fn dirty(self: *const BsonCollection) bool {
        return self._dirty;
    }

    //
    // Sets the dirty flag and fires the onDirty callback on first transition per commit cycle.
    //
    fn markDirty(self: *BsonCollection) void {
        if (!self._dirty) {
            self._dirty = true;
            self.onDirtyCallback.function(self.onDirtyCallback.context);
        }
    }

    //
    // The onDirty callback given to sort indexes (TypeScript: `() => this.markDirty()`).
    //
    fn markDirtyCallback(context: *anyopaque) void {
        const self: *BsonCollection = @ptrCast(@alignCast(context));
        self.markDirty();
    }

    //
    // Clears the dirty flag after a successful commit or drop.
    //
    fn clearDirty(self: *BsonCollection) void {
        self._dirty = false;
    }

    //
    // Returns the sort index for the given field and direction (lazily loaded on first use).
    // The sort index is created and cached synchronously; disk access is deferred until first operation.
    //
    pub fn sortIndex(self: *BsonCollection, fieldName: []const u8, direction: SortDirection) !*SortIndex {
        const cacheKey = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ fieldName, @tagName(direction) });
        if (self.sortIndexCache.get(cacheKey)) |cached| {
            return cached;
        }
        const newSortIndex = try self.allocator.create(SortIndex);
        newSortIndex.* = try SortIndex.init(
            self.allocator,
            self.storage,
            self.baseDirectory,
            self.name,
            fieldName,
            direction,
            self.uuidGenerator,
            null, //todo: Might be good if the data type was passed into sortIndex as well!
            .{ .context = self, .function = markDirtyCallback },
        );
        // Not ported: the onDrop callback (drop is not used by psi replicate or psi verify).

        try self.sortIndexCache.put(self.allocator, cacheKey, newSortIndex);
        return newSortIndex;
    }

    // Not ported: addRecordToSortIndexes (only used by insertOne).

    //
    // Updates a record in all sort indexes.
    //
    fn updateRecordInSortIndexes(self: *BsonCollection, io: std.Io, updatedRecord: IInternalRecord, oldRecord: ?IInternalRecord) !void {
        const indexes = try self.sortIndexes(io);
        for (indexes) |indexInfo| {
            const index = try self.sortIndex(indexInfo.fieldName, indexInfo.direction);
            try index.updateRecord(io, updatedRecord, oldRecord);
        }
    }

    //
    // Deletes a record from all existing sort indexes.
    //
    fn deleteRecordFromSortIndexes(self: *BsonCollection, io: std.Io, recordId: []const u8, record: IInternalRecord) !void {
        const indexes = try self.sortIndexes(io);
        for (indexes) |indexInfo| {
            const index = try self.sortIndex(indexInfo.fieldName, indexInfo.direction);
            try index.deleteRecord(io, recordId, record);
        }
    }

    //
    // Returns the collection merkle ref (lazily loads from disk or builds on first use).
    //
    pub fn merkleTree(self: *BsonCollection) !*MerkleRef {
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
        const self: *BsonCollection = @ptrCast(@alignCast(context));
        return try merkle_tree.loadCollectionMerkleTree(allocator, io, self.storage, self.bsonDbPath, self.name);
    }

    //
    // The merkle ref saver.
    //
    fn merkleSaver(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io, tree: *IMerkleTree) anyerror!void {
        const self: *BsonCollection = @ptrCast(@alignCast(context));
        return merkle_tree.saveCollectionMerkleTree(allocator, io, self.storage, self.bsonDbPath, self.name, tree);
    }

    //
    // The merkle ref deleter.
    //
    fn merkleDeleter(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!void {
        const self: *BsonCollection = @ptrCast(@alignCast(context));
        return merkle_tree.deleteCollectionMerkleTree(allocator, io, self.storage, self.bsonDbPath, self.name);
    }

    //
    // The merkle ref creator.
    //
    fn merkleCreator(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!IMerkleTree {
        const self: *BsonCollection = @ptrCast(@alignCast(context));
        return merkle_tree_zig.merkle_tree.createTree(try self.uuidGenerator.generate(allocator, io));
    }

    //
    // Returns the shard bucket for shardId (creates and caches a BsonShard; BSON reads are lazy).
    //
    pub fn shard(self: *BsonCollection, shardId: []const u8) !*BsonShard {
        if (self.shardCache.getEntry(shardId)) |entry| {
            const cachedShardId = entry.key_ptr.*;
            const cached = entry.value_ptr.*;
            // Re-inserted so the map's iteration order is least-recently-used first, which is the
            // order evictShards drops them in.
            _ = self.shardCache.orderedRemove(cachedShardId);
            try self.shardCache.put(self.allocator, cachedShardId, cached);
            return cached;
        }
        const bsonShard = try self.allocator.create(BsonShard);
        const ownedShardId = try self.allocator.dupe(u8, shardId);
        bsonShard.* = BsonShard.init(self.allocator, ownedShardId, self.storage, self.bsonDbPath, self.name, self.uuidGenerator);
        try self.shardCache.put(self.allocator, ownedShardId, bsonShard);
        try self.evictShards();
        return bsonShard;
    }

    //
    // Drops cached shards, oldest first, until the cache is inside its quota.
    //
    // A dirty shard is never dropped, because its records are the only copy of writes that have not
    // been committed yet. So the quota is a target rather than a guarantee: a caller that dirties more
    // shards than the quota keeps them all, which is what commit() exists to end.
    //
    fn evictShards(self: *BsonCollection) !void {
        if (self.shardCache.count() <= MAX_CACHED_SHARDS) {
            return;
        }

        // (Zig: an index walk stands in for iterating the Map while deleting from it; a removed entry
        // shifts the next one into its slot.)
        var cacheIndex: usize = 0;
        while (cacheIndex < self.shardCache.count()) {
            if (self.shardCache.count() <= MAX_CACHED_SHARDS) {
                return;
            }
            const cachedShard = self.shardCache.values()[cacheIndex];
            if (cachedShard.dirty()) {
                cacheIndex += 1;
                continue;
            }
            try cachedShard.flush();
            self.shardCache.orderedRemoveAt(cacheIndex);
        }
    }

    //
    // Returns the shard id for a record (hash of id mod numShards).
    //
    pub fn getShardId(self: *BsonCollection, recordId: []const u8) ![]const u8 {
        const recordIdBuffer = try shard_zig.recordIdToBuffer(self.allocator, recordId);
        if (recordIdBuffer.len != 16) {
            return errors.throwError("Invalid record ID {s} with length {d}", .{ recordId, recordIdBuffer.len });
        }

        var hash: [Md5.digest_length]u8 = undefined;
        Md5.hash(recordIdBuffer, &hash, .{});
        const decimal = std.mem.readInt(u32, hash[0..4], .big);
        return std.fmt.allocPrint(self.allocator, "{d}", .{decimal % NUM_SHARDS});
    }

    // Not ported: insertOne, getOne (not used by psi replicate or psi verify).

    //
    // Iterate all records in the collection without loading all into memory.
    //
    pub fn iterateRecords(self: *BsonCollection) RecordIterator {
        return .{ .collection = self };
    }

    //
    // Iterate each shard in the collection without loading all into memory.
    // Yields only shards that have records.
    //
    pub fn iterateShards(self: *BsonCollection) ShardIterator {
        return .{ .collection = self };
    }

    // Not ported: getAll, updateOne, replaceOne (not used by psi replicate or psi verify).

    //
    // Sets an internal record directly, preserving all timestamps and metadata.
    // This is useful for sync operations where timestamps must be preserved exactly.
    // Always upserts (creates if doesn't exist, updates if it does).
    //
    pub fn setInternalRecord(self: *BsonCollection, io: std.Io, record: IInternalRecord) !void {
        const shardId = try self.getShardId(record._id);
        const recordShard = try self.shard(shardId);

        const existingRecord = try recordShard.record(io, record._id);

        // Set the record directly with all its metadata preserved
        try recordShard.setRecord(io, record._id, record);
        try self.updateRecordInSortIndexes(io, record, existingRecord);

        self.markDirty();
    }

    //
    // Deletes a record.
    //
    pub fn deleteOne(self: *BsonCollection, io: std.Io, recordId: []const u8) !bool {
        const shardId = try self.getShardId(recordId);
        const recordShard = try self.shard(shardId);

        //
        // Find the record to delete.
        //
        const existingRecord = try recordShard.record(io, recordId) orelse {
            return false; // Record not found
        };

        //
        // Delete the record.
        //
        try recordShard.deleteRecord(io, recordId);
        try self.deleteRecordFromSortIndexes(io, recordId, existingRecord);
        self.markDirty();

        return true;
    }

    //
    // Returns the field name and direction of a sort index directory named "fieldname_direction"
    // (TypeScript: `dir.match(/^(.+)_(asc|desc)$/)`), or null when the name does not match.
    //
    fn parseSortIndexDirectory(directoryName: []const u8) ?ISortIndexInfo {
        if (std.mem.endsWith(u8, directoryName, "_asc") and directoryName.len > "_asc".len) {
            return .{ .fieldName = directoryName[0 .. directoryName.len - "_asc".len], .direction = .asc };
        }
        if (std.mem.endsWith(u8, directoryName, "_desc") and directoryName.len > "_desc".len) {
            return .{ .fieldName = directoryName[0 .. directoryName.len - "_desc".len], .direction = .desc };
        }
        return null;
    }

    //
    // List all sort indexes for this collection
    //
    pub fn sortIndexes(self: *BsonCollection, io: std.Io) ![]ISortIndexInfo {
        const collectionIndexPath = try std.fmt.allocPrint(self.allocator, "{s}/indexes/{s}", .{ self.baseDirectory, self.name });

        if (!try self.storage.dirExists(self.allocator, io, collectionIndexPath)) {
            return &.{};
        }

        const result = try self.storage.listDirs(self.allocator, io, collectionIndexPath, 1000, null);
        const directories = result.names;

        var indexes: std.ArrayList(ISortIndexInfo) = .empty;

        for (directories) |directory| {
            // Parse the directory name, which should be in format "fieldname_direction"
            if (parseSortIndexDirectory(directory)) |indexInfo| {
                try indexes.append(self.allocator, indexInfo);
            }
        }

        return indexes.items;
    }

    // Not ported: drop (not used by psi replicate or psi verify).

    //
    // Flushes all pending writes to disk: dirty shards, merkle trees, and sort index pages.
    // Dirty flags are cleared; the in-memory cache remains populated for fast subsequent reads.
    // Returns the current collection merkle tree for the database to incorporate.
    //
    pub fn commit(self: *BsonCollection, io: std.Io) !void {

        for (self.shardCache.keys(), self.shardCache.values()) |shardId, cachedShard| {
            if (!cachedShard.dirty()) {
                continue;
            }

            try cachedShard.commit(io);

            const shardMerkleRef = try cachedShard.merkleTree();
            const shardTree = try shardMerkleRef.get(io);
            const collectionMerkleRef = try self.merkleTree();
            if (shardTree != null and shardTree.?.merkle != null) {
                try collectionMerkleRef.upsert(io, .{
                    .name = shardId,
                    .hash = shardTree.?.merkle.?.hash,
                    .length = shardTree.?.merkle.?.nodeCount,
                    .lastModified = std.Io.Clock.real.now(io).toMilliseconds(),
                });
            }
            else {
                try collectionMerkleRef.remove(io, shardId);
            }
        }

        for (self.sortIndexCache.values()) |cachedSortIndex| {
            try cachedSortIndex.commit(io);
        }

        const merkleRef = try self.merkleTree();
        try merkleRef.commit(io);

        self.clearDirty();
    }

    // Not ported: flush (psi replicate and psi verify never flush a database).
};
