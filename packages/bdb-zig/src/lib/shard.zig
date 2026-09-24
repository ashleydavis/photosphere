const std = @import("std");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const storage_zig = @import("storage-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_tree = @import("merkle-tree.zig");
const merkle_tree_ref = @import("merkle-tree-ref.zig");
const locale_compare = @import("locale-compare.zig");
const errors = utils.errors;
const serialization = serialization_zig.serialization;
const bson = serialization_zig.bson;
const ISerializer = serialization.ISerializer;
const IDeserializer = serialization.IDeserializer;
const IStorage = storage_zig.storage.IStorage;
const pathJoin = storage_zig.storage_factory.pathJoin;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const IMerkleTree = merkle_tree_zig.merkle_tree.IMerkleTree;
const MerkleRef = merkle_tree_ref.MerkleRef;

//
// On-disk shard file format (SHAR).
//
const SHARD_FILE_VERSION = 2;

//
// Internal record structure with fields separated into a subobject.
// Used internally for storage, but converted to/from IRecord at API boundaries.
//
pub const IInternalRecord = struct {
    //
    // The record id (UUID string).
    //
    _id: []const u8,

    //
    // Payload fields (everything except id and metadata envelope).
    //
    fields: bson.BsonDocument,

    //
    // Field-level timestamps and tombstones for merge/sync.
    // (Zig: the Metadata object is kept as the BSON document it is stored as.)
    //
    metadata: bson.BsonDocument,
};

//
// Decodes a record id like `Buffer.from(id.replace(/-/g, ''), 'hex')`: dashes are removed, then pairs of hex digits are
// decoded until the first pair that is not hex (Node truncates there instead of failing).
// (No TypeScript counterpart: the TypeScript code calls Node's Buffer.)
//
pub fn recordIdToBuffer(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    var hexDigits: std.ArrayList(u8) = .empty;
    for (id) |character| {
        if (character != '-') {
            try hexDigits.append(allocator, character);
        }
    }
    var bytes: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index + 1 < hexDigits.items.len) : (index += 2) {
        const high = std.fmt.charToDigit(hexDigits.items[index], 16) catch {
            break;
        };
        const low = std.fmt.charToDigit(hexDigits.items[index + 1], 16) catch {
            break;
        };
        try bytes.append(allocator, high * 16 + low);
    }
    return bytes.items;
}

//
// Normalizes a record id to the map key used within shards (32-char hex, no dashes).
//
pub fn getRecordKey(allocator: std.mem.Allocator, id: []const u8) ![]const u8 {
    const idBuffer = try recordIdToBuffer(allocator, id);
    if (idBuffer.len != 16) {
        return errors.throwError("Invalid record ID {s} with length {d}", .{ id, idBuffer.len });
    }
    const hex = std.fmt.bytesToHex(idBuffer[0..16].*, .lower);
    return allocator.dupe(u8, &hex);
}

//
// One bucket of records within a collection.
// (Zig: IShard has a single implementation, so callers use *BsonShard directly.)
//
pub const IShard = BsonShard;

//
// The records of a shard keyed by normalized id, in insertion order like a JS Map.
//
pub const RecordMap = std.StringArrayHashMapUnmanaged(IInternalRecord);

//
// Mutable shard instance held in the collection shard cache.
// (Zig: the shard must stay at the same address once merkleTree() has been called, because its merkle ref points
// back at it. The collection allocates its shards on the heap.)
//
pub const BsonShard = struct {

    //
    // Allocates the records, the merkle tree and everything else the shard keeps (normally an arena).
    //
    allocator: std.mem.Allocator,

    //
    // Set to true when the shard is changed and must eventually be written to storage.
    //
    _dirty: bool = false,

    //
    // In-memory records; undefined until load() or the first setRecord().
    //
    _records: ?RecordMap = null,

    //
    // Lazily-created ref for this shard's merkle tree.
    //
    _merkleRef: ?*MerkleRef = null,

    //
    // The id of the shard (the shard file name).
    //
    shardId: []const u8,

    //
    // The storage holding the shard files.
    //
    storage: IStorage,

    //
    // The database root in storage.
    //
    bsonDbPath: []const u8,

    //
    // The collection the shard belongs to.
    //
    collectionName: []const u8,

    //
    // Generates ids for new merkle trees.
    //
    uuidGenerator: IUuidGenerator,

    //
    // Creates a shard (TypeScript: the constructor).
    //
    pub fn init(allocator: std.mem.Allocator, shardId: []const u8, storage: IStorage, bsonDbPath: []const u8, collectionName: []const u8, uuidGenerator: IUuidGenerator) BsonShard {
        return .{
            .allocator = allocator,
            .shardId = shardId,
            .storage = storage,
            .bsonDbPath = bsonDbPath,
            .collectionName = collectionName,
            .uuidGenerator = uuidGenerator,
        };
    }

    //
    // True when the shard has uncommitted changes.
    //
    pub fn dirty(self: *const BsonShard) bool {
        return self._dirty;
    }

    //
    // Marks this shard as having uncommitted BSON and/or shard merkle changes.
    //
    pub fn markDirty(self: *BsonShard) void {
        self._dirty = true;
    }

    //
    // Clears dirty after this shard's data has been written on commit.
    //
    pub fn markClean(self: *BsonShard) void {
        self._dirty = false;
    }

    //
    // Adds a record to this shard's in-memory map (keyed by normalized id).
    //
    pub fn setRecord(self: *BsonShard, io: std.Io, recordId: []const u8, newRecord: IInternalRecord) !void {
        try self.load(io); // Lazily load the shard.

        const key = try getRecordKey(self.allocator, recordId);

        //
        // Add the record to the shard.
        //
        try self._records.?.put(self.allocator, key, newRecord);

        //
        // Update the shard's merkle tree.
        //
        const merkleRef = try self.merkleTree();
        try merkleRef.upsert(io, try merkle_tree.hashRecord(self.allocator, io, recordId, newRecord.fields));

        self.markDirty();
    }

    //
    // Gets a record by logical id from this shard's map.
    //
    pub fn record(self: *BsonShard, io: std.Io, recordId: []const u8) !?IInternalRecord {
        try self.load(io); // Lazily load the shard.

        if (self._records.?.count() == 0) {
            // No records.
            return null;
        }

        const key = try getRecordKey(self.allocator, recordId);
        return self._records.?.get(key);
    }

    //
    // Get the map of record it to records.
    //
    pub fn records(self: *BsonShard, io: std.Io) !*RecordMap {
        try self.load(io); // Lazily load the shard.
        return &self._records.?;
    }

    //
    // Deletes a record by logical id from this shard's map.
    //
    pub fn deleteRecord(self: *BsonShard, io: std.Io, recordId: []const u8) !void {
        try self.load(io); // Lazily load the shard.

        if (self._records.?.count() == 0) {
            // No record to delete.
            return;
        }

        const key = try getRecordKey(self.allocator, recordId);

        //
        // Remove the record from the shard.
        //
        _ = self._records.?.orderedRemove(key);

        //
        // Update the shard merkle tree.
        //
        const merkleRef = try self.merkleTree();
        try merkleRef.remove(io, recordId);
        self.markDirty();
    }

    //
    // Returns this shard's merkle ref (lazily loads from disk or builds from records on first use).
    //
    pub fn merkleTree(self: *BsonShard) !*MerkleRef {
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
        const self: *BsonShard = @ptrCast(@alignCast(context));
        return try merkle_tree.loadShardMerkleTree(allocator, io, self.storage, self.bsonDbPath, self.collectionName, self.shardId);
    }

    //
    // The merkle ref saver.
    //
    fn merkleSaver(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io, tree: *IMerkleTree) anyerror!void {
        const self: *BsonShard = @ptrCast(@alignCast(context));
        return merkle_tree.saveShardMerkleTree(allocator, io, self.storage, self.bsonDbPath, self.collectionName, self.shardId, tree);
    }

    //
    // The merkle ref deleter.
    //
    fn merkleDeleter(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!void {
        const self: *BsonShard = @ptrCast(@alignCast(context));
        return merkle_tree.deleteShardMerkleTree(allocator, io, self.storage, self.bsonDbPath, self.collectionName, self.shardId);
    }

    //
    // The merkle ref creator.
    //
    fn merkleCreator(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!IMerkleTree {
        const self: *BsonShard = @ptrCast(@alignCast(context));
        return try merkle_tree.buildShardMerkleTree(allocator, io, &.{}, self.uuidGenerator);
    }

    //
    // Persists dirty shard data (BSON and merkle tree) to storage; no-op when not dirty.
    //
    pub fn commit(self: *BsonShard, io: std.Io) !void {
        if (!self._dirty) {
            return;
        }

        const shardFilePath = try pathJoin(self.allocator, &.{ self.bsonDbPath, "collections", self.collectionName, "shards", self.shardId });
        if (self._records == null or self._records.?.count() == 0) {
            if (try self.storage.fileExists(self.allocator, io, shardFilePath)) {
                try self.storage.deleteFile(self.allocator, io, shardFilePath);
            }
        }
        else {
            try self.writeBsonFile(io, shardFilePath);
        }

        const merkleRef = try self.merkleTree();
        try merkleRef.commit(io);

        self.markClean();
    }

    // Not ported: flush (psi replicate and psi verify never flush a database).

    //
    // Serializes a single record for shard file format v2+.
    //
    fn serializeRecord(allocator: std.mem.Allocator, recordToWrite: IInternalRecord, serializer: ISerializer) !void {
        const recordIdBuffer = try recordIdToBuffer(allocator, recordToWrite._id);
        if (recordIdBuffer.len != 16) {
            return errors.throwError("Invalid record ID {s} with length {d}", .{ recordToWrite._id, recordIdBuffer.len });
        }
        try serializer.writeBytes(recordIdBuffer);
        try serializer.writeBSON(recordToWrite.fields);
        try serializer.writeBSON(recordToWrite.metadata);
    }

    //
    // Sort predicate for records: `recordA._id.localeCompare(recordB._id)`.
    //
    fn recordLessThan(context: void, recordA: IInternalRecord, recordB: IInternalRecord) bool {
        _ = context;
        return locale_compare.localeCompare(recordA._id, recordB._id) < 0;
    }

    //
    // Writes all records in this shard to the serializer in a deterministic order.
    //
    fn serializeShard(allocator: std.mem.Allocator, self: *BsonShard, serializer: ISerializer) anyerror!void {
        const recordMap = self._records orelse {
            return errors.throwError("Cannot serialize shard without a records map", .{});
        };
        try serializer.writeUInt32(@intCast(recordMap.count()));
        const sortedRecords = try allocator.dupe(IInternalRecord, recordMap.values());
        std.mem.sort(IInternalRecord, sortedRecords, {}, recordLessThan);
        for (sortedRecords) |sortedRecord| {
            try serializeRecord(allocator, sortedRecord, serializer);
        }
    }

    //
    // Writes the shard BSON blob to storage.
    //
    fn writeBsonFile(self: *BsonShard, io: std.Io, filePath: []const u8) !void {
        try serialization.save(
            self.allocator,
            io,
            self.storage,
            filePath,
            self,
            SHARD_FILE_VERSION,
            "SHAR",
            serializeShard,
        );
    }

    //
    // Migrates old flat format to new format with fields subobject
    // Deserializer function for version 1 shard data
    //
    fn deserializeShardV1(allocator: std.mem.Allocator, self: *BsonShard, deserializer: IDeserializer) anyerror![]IInternalRecord {
        _ = self;
        var loadedRecords: std.ArrayList(IInternalRecord) = .empty;

        // Read record count (4 bytes LE)
        const recordCount = try deserializer.readUInt32();

        var recordIndex: u32 = 0;
        while (recordIndex < recordCount) : (recordIndex += 1) {
            try loadedRecords.append(allocator, try deserializeRecordV1(allocator, deserializer));
        }

        return loadedRecords.items;
    }

    //
    // Deserializer function for version 2 shard data
    // Returns records in internal format.
    //
    fn deserializeShardV2(allocator: std.mem.Allocator, self: *BsonShard, deserializer: IDeserializer) anyerror![]IInternalRecord {
        _ = self;
        var loadedRecords: std.ArrayList(IInternalRecord) = .empty;

        // Read record count (4 bytes LE)
        const recordCount = try deserializer.readUInt32();

        var recordIndex: u32 = 0;
        while (recordIndex < recordCount) : (recordIndex += 1) {
            try loadedRecords.append(allocator, try deserializeRecordV2(allocator, deserializer));
        }

        return loadedRecords.items;
    }

    //
    // Deserializes a version 2 record (fields and metadata)
    //
    fn deserializeRecordV2(allocator: std.mem.Allocator, deserializer: IDeserializer) !IInternalRecord {
        // Read 16 byte uuid
        const recordIdBuffer = try deserializer.readBytes(16);
        const hexString = std.fmt.bytesToHex(recordIdBuffer[0..16].*, .lower);
        const recordId = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}-{s}-{s}", .{
            hexString[0..8],
            hexString[8..12],
            hexString[12..16],
            hexString[16..20],
            hexString[20..],
        });

        // Read and deserialize the record fields
        const fields = try deserializer.readBSON();

        // Read and deserialize metadata
        const metadata = try deserializer.readBSON();

        return .{
            ._id = recordId,
            .fields = fields,
            .metadata = metadata,
        };
    }

    //
    // Deserializes a version 1 record (fields only, no metadata)
    //
    fn deserializeRecordV1(allocator: std.mem.Allocator, deserializer: IDeserializer) !IInternalRecord {
        // Read 16 byte uuid
        const recordIdBuffer = try deserializer.readBytes(16);
        const hexString = std.fmt.bytesToHex(recordIdBuffer[0..16].*, .lower);
        const recordId = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}-{s}-{s}", .{
            hexString[0..8],
            hexString[8..12],
            hexString[12..16],
            hexString[16..20],
            hexString[20..],
        });

        // Read and deserialize the record fields
        const fields = try deserializer.readBSON();

        return .{
            ._id = recordId,
            .fields = fields,
            .metadata = .empty,
        };
    }

    //
    // The deserializers for every supported version of the shard file (TypeScript: the object passed to load()).
    //
    const shard_deserializers = [_]serialization.DeserializerEntry([]IInternalRecord, *BsonShard){
        .{ .version = 1, .deserializer = deserializeShardV1 },
        .{ .version = 2, .deserializer = deserializeShardV2 },
    };

    //
    // Loads all records from a shard file.
    // Supports version 1 and 2.
    // Returns records in internal format.
    //
    fn loadRecords(self: *BsonShard, io: std.Io, shardFilePath: []const u8) ![]IInternalRecord {
        const loadedRecords = try serialization.load(
            []IInternalRecord,
            self.allocator,
            io,
            self.storage,
            shardFilePath,
            "SHAR",
            self,
            &shard_deserializers,
        );

        // Return empty array if file doesn't exist (load returns undefined)
        return loadedRecords orelse &.{};
    }

    //
    // Loads records from a shard file into this shard's map (replaces prior contents).
    //
    pub fn load(self: *BsonShard, io: std.Io) !void {
        if (self._records != null) {
            // Already loaded.
            return;
        }
        const shardFilePath = try pathJoin(self.allocator, &.{ self.bsonDbPath, "collections", self.collectionName, "shards", self.shardId });
        const loaded = try self.loadRecords(io, shardFilePath);
        var recordMap: RecordMap = .empty;
        for (loaded) |loadedRecord| {
            const key = try getRecordKey(self.allocator, loadedRecord._id);
            try recordMap.put(self.allocator, key, loadedRecord);
        }
        self._records = recordMap;
        self._merkleRef = null;
    }
};
