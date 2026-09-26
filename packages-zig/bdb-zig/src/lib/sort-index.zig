//
// Sort index that defers all writes until commit(). All loaded data is cached in memory;
// writes only update the cache and set dirty flags. Call commit() to flush to disk.
//

const std = @import("std");
const utils = @import("utils-zig");
const serialization_zig = @import("serialization-zig");
const storage_zig = @import("storage-zig");
const collection_zig = @import("collection.zig");
const shard_zig = @import("shard.zig");
const js_value = @import("js-value.zig");
const locale_compare = @import("locale-compare.zig");
const errors = utils.errors;
const serialization = serialization_zig.serialization;
const bson = serialization_zig.bson;
const BsonValue = bson.BsonValue;
const BsonDocument = bson.BsonDocument;
const ISerializer = serialization.ISerializer;
const IDeserializer = serialization.IDeserializer;
const IStorage = storage_zig.storage.IStorage;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const IBsonCollection = collection_zig.IBsonCollection;
const DirtyCallback = collection_zig.DirtyCallback;
const IInternalRecord = shard_zig.IInternalRecord;
const JsPrimitive = js_value.JsPrimitive;

//
// The direction of a sort index (TypeScript: 'asc' | 'desc'; @tagName gives the string).
//
pub const SortDirection = enum {
    // Ascending.
    asc,

    // Descending.
    desc,
};

//
// The data type of a sorted field (TypeScript: 'date' | 'string' | 'number').
//
pub const SortDataType = enum {
    // Dates (Date objects or date strings).
    date,

    // Strings (compared with localeCompare).
    string,

    // Numbers.
    number,
};

//
// The tree nodes of a sort index keyed by page id (TypeScript: Map<string, IBTreeNode>).
//
pub const TreeNodeMap = std.StringArrayHashMapUnmanaged(*IBTreeNode);

//
// Interface for tree data structure
//
const ITreeData = struct {
    // Total number of entries stored across all leaf nodes.
    totalEntries: u32,

    // Total number of pages (nodes) in the tree.
    totalPages: u32,

    // ID of the root B-tree node.
    rootPageId: []const u8,

    // Name of the field this index is sorted by.
    fieldName: []const u8,

    // Sort direction for this index (Zig: kept as the string read from the file).
    direction: []const u8,

    // Data type of the sorted field, if known.
    type: ?SortDataType,

    // In-memory cache of all loaded B-tree nodes, keyed by page ID.
    treeNodes: TreeNodeMap,
};

// Not ported: IRangeOptions (findByRange is not used by psi replicate or psi verify).

//
// Split internal nodes when they exceed 1.2x the key size.
//
const SPLIT_KEYS_THRESHOLD = 1.2;

//
// Split leaf nodes when they exceed 1.5x the page size
//
const LEAF_SPLIT_THRESHOLD = 1.5;

//
// Maximum number of keys per internal B-tree node.
//
pub const DEFAULT_KEY_SIZE = 100;

//
// Number of records to process per batch during index build.
//
const BUILD_BATCH_SIZE = 10000;

// Not ported: BUILD_PROGRESS_INTERVAL (the progress callback is not ported, see build).

//
// Number of records per leaf page.
//
const PAGE_SIZE = 1000;

//
// Represents a single entry in the sorted index, including its ID, fields, and sort value.
//
pub const ISortedIndexEntry = struct {
    // The record ID.
    _id: []const u8,

    // The record fields.
    fields: BsonDocument,

    // The value used for sorting
    value: BsonValue,

    // (Zig only: stands in for JavaScript object identity. Points at the record field the value was taken from when
    // the entry was added in this session (so it is the same JS object as that field); null when the entry was loaded
    // from storage (a distinct JS object). See strictEqualsValue.)
    valueIdentity: ?*const BsonValue = null,
};

//
// A field value together with the address of the field it came from (its JS object identity).
//
const IFieldValue = struct {
    // The value of the field.
    value: BsonValue,

    // The field slot the value lives in (shared by every copy of the same record, like a JS object reference).
    identity: *const BsonValue,
};

//
// Gets a record field (TypeScript: `record.fields[fieldName]`) with its identity; null when the field is missing or
// undefined.
//
fn getFieldValue(fields: BsonDocument, fieldName: []const u8) ?IFieldValue {
    for (fields.fields.items) |*field| {
        if (std.mem.eql(u8, field.key, fieldName)) {
            if (field.value == .undefined) {
                return null;
            }
            return .{ .value = field.value, .identity = &field.value };
        }
    }
    return null;
}

//
// Evaluates `left === right` for sort values: primitives compare by value, objects (dates, documents, arrays, ...)
// by identity, which is emulated with the address of the record field they came from. This matches JavaScript when
// the same record object is indexed and later passed as the old record (the replicate case); it does not model an
// object shared between two different records (for example after `{ ...fields }`), which is treated as distinct.
//
fn strictEqualsValue(left: BsonValue, leftIdentity: ?*const BsonValue, right: BsonValue, rightIdentity: ?*const BsonValue) bool {
    if (std.mem.eql(u8, js_value.typeOf(left), "object") and left != .null) {
        return leftIdentity != null and leftIdentity == rightIdentity;
    }
    return js_value.strictEquals(left, right);
}

//
// A record returned from a sort index query, with fields expanded to the top level
// (Zig: a document whose first field is _id, followed by the record fields).
//
pub const ISortIndexRecord = BsonDocument;

// Not ported: ISortIndexResult, INodeKeyDistribution, ILeafStats, IInternalStats, ITreeAnalysis (only used by
// getPage and analyzeTreeStructure, which psi replicate and psi verify do not use).

//
// The records of one leaf page (TypeScript: an array, shared by reference between the caches).
//
pub const LeafRecords = std.ArrayList(ISortedIndexEntry);

//
// A cached leaf page entry, holding its records and a dirty flag.
//
const ILeafCacheEntry = struct {
    // The records stored in this leaf page.
    records: *LeafRecords,

    // True if the records have been modified and need to be persisted.
    dirty: bool,
};

//
// Interface for a sort index that supports paginated, sorted queries over a collection of records.
// (Zig: ISortIndex has a single implementation, so callers use *SortIndex directly.)
//
pub const ISortIndex = SortIndex;

// B-tree node interface
pub const IBTreeNode = struct {
    // Values that divide ranges
    keys: std.ArrayList(BsonValue) = .empty,

    // For internal nodes, pageIds of children (empty array means this is a leaf node)
    children: std.ArrayList([]const u8) = .empty,

    // For leaf nodes, pageId of next leaf for sequential scans
    nextLeaf: ?[]const u8 = null,

    // For leaf nodes, pageId of previous leaf for reverse traversal
    previousLeaf: ?[]const u8 = null,

    // Reference to parent node
    parentId: ?[]const u8 = null,
    // A node is a leaf if children.length === 0, and NOT a leaf if children.length > 0
};

// Build checkpoint for incremental builds
const IBuildCheckpoint = struct {
    // Shard IDs that have been fully processed
    completedShards: []f64,

    // Current shard being processed (if build was interrupted)
    currentShard: ?f64,

    // Record index within current shard to resume from
    currentShardRecordIndex: f64,

    // Total records processed so far
    totalRecordsProcessed: f64,

    // Timestamp when checkpoint was created/updated
    lastUpdated: f64,
};

//
// Returns true when a page id is set (TypeScript: a truthy string; the empty string counts as not set).
//
fn isSet(pageId: ?[]const u8) bool {
    return pageId != null and pageId.?.len > 0;
}

//
// Returns true when two optional page ids are the same string (TypeScript: `===` on string | undefined).
//
fn samePageId(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) {
        return left == null and right == null;
    }
    return std.mem.eql(u8, left.?, right.?);
}

//
// Returns the index of a page id in a list of children, or null (TypeScript: `children.indexOf(id)` returning -1).
//
fn indexOfChild(children: []const []const u8, pageId: []const u8) ?usize {
    for (children, 0..) |childId, childIndex| {
        if (std.mem.eql(u8, childId, pageId)) {
            return childIndex;
        }
    }
    return null;
}

//
// Returns the index of the entry with the given record id, or null (TypeScript: findIndex returning -1).
//
fn findEntryIndex(leafRecords: *const LeafRecords, recordId: []const u8) ?usize {
    for (leafRecords.items, 0..) |entry, entryIndex| {
        if (std.mem.eql(u8, entry._id, recordId)) {
            return entryIndex;
        }
    }
    return null;
}

//
// Sort index: add/update/delete only update in-memory state; call commit() to persist.
//
pub const SortIndex = struct {
    // Allocates the tree nodes, leaf records and everything else the index keeps (normally an arena).
    allocator: std.mem.Allocator,

    // Storage backend used to persist index pages.
    storage: IStorage,

    // Directory path within storage where index pages are stored.
    indexDirectory: []const u8,

    // The record field name used as the sort key.
    fieldName: []const u8,

    // The sort direction (ascending or descending).
    direction: SortDirection,

    // Total number of entries across all leaf pages.
    totalEntries: u32 = 0,

    // Tracks only leaf nodes (user-facing pages).
    totalPages: u32 = 0,

    // Whether the index has been loaded from storage.
    loaded: bool = false,

    // The ID of the root page of the B-tree.
    rootPageId: ?[]const u8 = null,

    // Optional type for value conversion.
    type: ?SortDataType,

    // Path to the single file that contains all tree nodes and metadata
    treeFilePath: []const u8,

    // Path to the checkpoint file for incremental builds
    checkpointFilePath: []const u8,

    // Map of all tree nodes
    treeNodes: TreeNodeMap = .empty,

    // UUID generator for creating unique identifiers
    uuidGenerator: IUuidGenerator,

    // In-memory cache of leaf page entries, keyed by page ID.
    leafCache: std.StringArrayHashMapUnmanaged(ILeafCacheEntry) = .empty,

    // Aggregate dirty flag: true if any dirty state exists since last commit
    _dirty: bool = false,

    // True once a load attempt has been made, preventing repeated disk reads on unbuilt indexes.
    _loadAttempted: bool = false,

    // Callback fired on first dirty transition per commit cycle
    onDirtyCallback: ?DirtyCallback,

    // Not ported: onDropCallback (drop is not used by psi replicate or psi verify).

    //
    // Creates a sort index. All writes are deferred until commit().
    // type: optional type for value conversion before comparison.
    // Supports 'date' for ISO string date parsing, 'string' for string comparison, 'number' for numeric comparison.
    // If not set, type will be inferred from the values.
    // onDirty: called when the sort index first transitions from clean to dirty (has uncommitted changes).
    // Used by BsonCollection to propagate the dirty flag upward.
    //
    pub fn init(
        allocator: std.mem.Allocator,
        storage: IStorage,
        baseDirectory: []const u8,
        collectionName: []const u8,
        fieldName: []const u8,
        direction: SortDirection,
        uuidGenerator: IUuidGenerator,
        sortDataType: ?SortDataType,
        onDirty: ?DirtyCallback,
    ) !SortIndex {
        const indexDirectory = try std.fmt.allocPrint(allocator, "{s}/indexes/{s}/{s}_{s}", .{ baseDirectory, collectionName, fieldName, @tagName(direction) });
        return .{
            .allocator = allocator,
            .storage = storage,
            .indexDirectory = indexDirectory,
            .fieldName = fieldName,
            .direction = direction,
            .type = sortDataType,
            .treeFilePath = try std.fmt.allocPrint(allocator, "{s}/tree.dat", .{indexDirectory}),
            .checkpointFilePath = try std.fmt.allocPrint(allocator, "{s}/build.checkpoint", .{indexDirectory}),
            .uuidGenerator = uuidGenerator,
            .onDirtyCallback = onDirty,
        };
    }

    //
    // Loads from disk on first access; subsequent calls are no-ops.
    //
    fn tryLoad(self: *SortIndex, io: std.Io) !void {
        if (self._loadAttempted or self.loaded) {
            return;
        }
        self._loadAttempted = true;
        _ = try self.load(io);
    }

    // Not ported: exists (not used by psi replicate or psi verify).

    //
    // Ensures the index is loaded; builds it from collection data if it does not exist on disk.
    // (Zig: the progressCallback parameter is not ported; ensureSortIndex passes none.)
    //
    pub fn ensure(self: *SortIndex, io: std.Io, collection: *IBsonCollection, sortDataType: SortDataType) !void {
        if (self.loaded) {
            return;
        }
        self.type = sortDataType;
        if (!try self.load(io)) {
            try self.build(io, collection);
        }
    }

    //
    // Sets the dirty flag and fires the onDirty callback on first transition per commit cycle.
    //
    fn markDirty(self: *SortIndex) void {
        if (!self._dirty) {
            self._dirty = true;
            if (self.onDirtyCallback) |callback| {
                callback.function(callback.context);
            }
        }
    }

    //
    // Deserializer function for tree data
    //
    fn deserializeTree(allocator: std.mem.Allocator, self: *SortIndex, deserializer: IDeserializer) anyerror!ITreeData {
        _ = self;
        // Read metadata directly as binary data
        const totalEntries = try deserializer.readUInt32();
        const totalPages = try deserializer.readUInt32();

        // Read rootPageId with length prefix
        const rootPageId = try allocator.dupe(u8, try deserializer.readBuffer());

        // Read fieldName with length prefix
        const fieldName = try allocator.dupe(u8, try deserializer.readBuffer());

        // Read direction with length prefix
        const direction = try allocator.dupe(u8, try deserializer.readBuffer());

        // Read type as a single byte: 0 for no type, 1 for date, 2 for string, 3 for number
        const typeValue = try deserializer.readUInt8();
        var sortDataType: ?SortDataType = null;
        if (typeValue == 1) {
            sortDataType = .date;
        }
        else if (typeValue == 2) {
            sortDataType = .string;
        }
        else if (typeValue == 3) {
            sortDataType = .number;
        }
        else {
            sortDataType = null;
        }

        // Skip what used to be the lastUpdatedAt timestamp (8 bytes LE)
        _ = try deserializer.readUInt64();

        // Read number of nodes (4 bytes LE)
        const nodeCount = try deserializer.readUInt32();

        // Read each node
        var treeNodes: TreeNodeMap = .empty;
        var nodeIndex: u32 = 0;
        while (nodeIndex < nodeCount) : (nodeIndex += 1) {
            // Read pageId with length prefix
            const pageId = try allocator.dupe(u8, try deserializer.readBuffer());

            // Deserialize node directly from the deserializer
            const node = try deserializeNode(allocator, deserializer);
            try treeNodes.put(allocator, pageId, node);
        }

        return .{
            .totalEntries = totalEntries,
            .totalPages = totalPages,
            .rootPageId = rootPageId,
            .fieldName = fieldName,
            .direction = direction,
            .type = sortDataType,
            .treeNodes = treeNodes,
        };
    }

    //
    // The deserializers for every supported version of the tree file.
    //
    const tree_deserializers = [_]serialization.DeserializerEntry(ITreeData, *SortIndex){
        .{ .version = 2, .deserializer = deserializeTree },
    };

    //
    // Loads the sort index metadata and tree nodes from disk.
    // Returns false if the sort index is not built.
    //
    pub fn load(self: *SortIndex, io: std.Io) !bool {
        if (self.loaded) {
            return true; // Already loaded
        }

        const treeData = try serialization.load(
            ITreeData,
            self.allocator,
            io,
            self.storage,
            self.treeFilePath,
            "IDXT",
            self,
            &tree_deserializers,
        ) orelse {
            return false;
        };

        self.totalEntries = treeData.totalEntries;
        self.totalPages = treeData.totalPages;
        if (treeData.rootPageId.len > 0) {
            self.rootPageId = treeData.rootPageId;
        }
        self.treeNodes = treeData.treeNodes;
        self.type = treeData.type;

        self.reconstructParentChildRelationships();

        self.loaded = true;
        return true;
    }

    // Reconstruct parent-child relationships for all nodes
    fn reconstructParentChildRelationships(self: *SortIndex) void {
        const rootPageId = self.rootPageId orelse {
            return;
        };

        // Start with the root node, which has no parent
        const rootNode = self.treeNodes.get(rootPageId) orelse {
            return;
        };

        // Root node has no parent
        rootNode.parentId = null;

        // Start the recursion from the root
        self.setParentsForChildren(rootPageId);
    }

    //
    // Recursively set parents for all children (TypeScript: the setParentsForChildren arrow function).
    //
    fn setParentsForChildren(self: *SortIndex, nodeId: []const u8) void {
        const node = self.treeNodes.get(nodeId) orelse {
            return;
        };
        if (node.children.items.len == 0) {
            return;
        }

        // For each child of this node, set its parent to this node
        for (node.children.items) |childId| {
            if (self.treeNodes.get(childId)) |childNode| {
                childNode.parentId = nodeId;

                // If the child is an internal node, process its children
                if (childNode.children.items.len > 0) {
                    self.setParentsForChildren(childId);
                }
            }
        }
    }

    // Serialize a single node to a buffer
    fn serializeNode(allocator: std.mem.Allocator, node: *const IBTreeNode, serializer: ISerializer) !void {

        try serializer.writeUInt32(0); // Each node used to store a buffer prefixed with the length. Write this for backward compatibility.

        // Serialize keys as BSON
        const keysDocument = try BsonDocument.fromFields(allocator, &.{.{ .key = "keys", .value = .{ .array = node.keys.items } }});
        try serializer.writeBSON(keysDocument);

        // Write children count (4 bytes) and children data
        // Note: A node is a leaf if children.length === 0, no need for separate isLeaf flag
        try serializer.writeUInt32(@intCast(node.children.items.len));

        for (node.children.items) |child| {
            try serializer.writeString(child);
        }

        // Write nextLeaf (empty string if undefined)
        try serializer.writeString(node.nextLeaf orelse "");

        // Write previousLeaf (empty string if undefined)
        try serializer.writeString(node.previousLeaf orelse "");

        // parentId is deliberately not serialized - it will be reconstructed during load
    }

    // Deserialize a single node from a deserializer
    fn deserializeNode(allocator: std.mem.Allocator, deserializer: IDeserializer) !*IBTreeNode {

        _ = try deserializer.readUInt32(); // Each node use to be stored a buffer prefixed with the lenght. Need to drop this.

        // Read keys as BSON
        const keysData = try deserializer.readBSON();
        var keys: std.ArrayList(BsonValue) = .empty;
        if (keysData.get("keys")) |keysValue| {
            if (keysValue == .array) {
                try keys.appendSlice(allocator, keysValue.array);
            }
        }

        // Read children count and data
        const childrenCount = try deserializer.readUInt32();
        var children: std.ArrayList([]const u8) = .empty;

        var childIndex: u32 = 0;
        while (childIndex < childrenCount) : (childIndex += 1) {
            try children.append(allocator, try allocator.dupe(u8, try deserializer.readString()));
        }

        // Read nextLeaf (empty string becomes undefined)
        const nextLeafText = try deserializer.readString();
        const nextLeaf: ?[]const u8 = if (nextLeafText.len > 0) try allocator.dupe(u8, nextLeafText) else null;

        // Read previousLeaf (empty string becomes undefined)
        const previousLeafText = try deserializer.readString();
        const previousLeaf: ?[]const u8 = if (previousLeafText.len > 0) try allocator.dupe(u8, previousLeafText) else null;

        // parentId is not present in the serialized format anymore
        // It will be reconstructed after loading all nodes

        const node = try allocator.create(IBTreeNode);
        node.* = .{
            .keys = keys,
            .children = children,
            .nextLeaf = nextLeaf,
            .previousLeaf = previousLeaf,
            // parentId is initially undefined
            // A node is a leaf if children.length === 0
        };
        return node;
    }

    //
    // Sort predicate for tree entries: `a.localeCompare(b)` on the page ids.
    //
    fn pageIdLessThan(context: void, left: []const u8, right: []const u8) bool {
        _ = context;
        return locale_compare.localeCompare(left, right) < 0;
    }

    //
    // Serializer function for tree data (without version, as save() handles that)
    //
    fn serializeTree(allocator: std.mem.Allocator, treeData: ITreeData, serializer: ISerializer) anyerror!void {
        // Sort entries by pageId for deterministic ordering
        const sortedPageIds = try allocator.dupe([]const u8, treeData.treeNodes.keys());
        std.mem.sort([]const u8, sortedPageIds, {}, pageIdLessThan);

        // Write metadata directly as binary data
        try serializer.writeUInt32(treeData.totalEntries);
        try serializer.writeUInt32(treeData.totalPages);

        // Write rootPageId with length prefix
        try serializer.writeBuffer(treeData.rootPageId);

        // Write fieldName with length prefix
        try serializer.writeBuffer(treeData.fieldName);

        // Write direction with length prefix
        try serializer.writeBuffer(treeData.direction);

        // Write type as a single byte: 0 for no type, 1 for date, 2 for string, 3 for number
        var typeValue: u8 = 0;
        if (treeData.type == .date) {
            typeValue = 1;
        }
        else if (treeData.type == .string) {
            typeValue = 2;
        }
        else if (treeData.type == .number) {
            typeValue = 3;
        }
        try serializer.writeUInt8(typeValue);

        // Write lastUpdatedAt timestamp (8 bytes LE) - now set to 0n for compatibility
        try serializer.writeUInt64(0);

        // Write number of nodes (4 bytes LE)
        try serializer.writeUInt32(@intCast(treeData.treeNodes.count()));

        // Write each node
        for (sortedPageIds) |pageId| {
            // Write pageId with length prefix
            try serializer.writeBuffer(pageId);

            // Serialize node directly to the serializer (no length prefix wrapper needed)
            try serializeNode(allocator, treeData.treeNodes.get(pageId).?, serializer);
        }
    }

    // Save checkpoint for incremental builds
    fn saveCheckpoint(self: *SortIndex, io: std.Io, checkpoint: *IBuildCheckpoint) !void {
        checkpoint.lastUpdated = @floatFromInt(std.Io.Clock.real.now(io).toMilliseconds());
        var json: std.Io.Writer.Allocating = .init(self.allocator);
        const writer = &json.writer;
        try writer.writeAll("{\"completedShards\":[");
        for (checkpoint.completedShards, 0..) |completedShard, shardIndex| {
            if (shardIndex > 0) {
                try writer.writeAll(",");
            }
            try js_value.writeNumber(writer, completedShard);
        }
        try writer.writeAll("],\"currentShard\":");
        if (checkpoint.currentShard) |currentShard| {
            try js_value.writeNumber(writer, currentShard);
        }
        else {
            try writer.writeAll("null");
        }
        try writer.writeAll(",\"currentShardRecordIndex\":");
        try js_value.writeNumber(writer, checkpoint.currentShardRecordIndex);
        try writer.writeAll(",\"totalRecordsProcessed\":");
        try js_value.writeNumber(writer, checkpoint.totalRecordsProcessed);
        try writer.writeAll(",\"lastUpdated\":");
        try js_value.writeNumber(writer, checkpoint.lastUpdated);
        try writer.writeAll("}");
        try self.storage.write(self.allocator, io, self.checkpointFilePath, "application/json", json.written());
    }

    // Load checkpoint for incremental builds
    fn loadCheckpoint(self: *SortIndex, io: std.Io) !?IBuildCheckpoint {
        const buffer = try self.storage.read(self.allocator, io, self.checkpointFilePath) orelse {
            return null;
        };
        return std.json.parseFromSliceLeaky(IBuildCheckpoint, self.allocator, buffer, .{ .ignore_unknown_fields = true }) catch {
            // Corrupted checkpoint, return null to start fresh
            return null;
        };
    }

    // Delete checkpoint file (called when build completes successfully)
    fn deleteCheckpoint(self: *SortIndex, io: std.Io) void {
        self.storage.deleteFile(self.allocator, io, self.checkpointFilePath) catch {
            // Ignore errors if file doesn't exist
        };
    }

    //
    // The state shared by the helper functions of build (TypeScript: the locals captured by its arrow functions).
    //
    const BuildState = struct {
        // Local cache for batched writes - only keeps pages being actively modified
        leafRecordsCache: std.StringArrayHashMapUnmanaged(*LeafRecords) = .empty,

        // The leaf pages changed since the last flush.
        dirtyLeafNodes: std.StringArrayHashMapUnmanaged(void) = .empty,

        // True when the tree structure changed since the last flush.
        treeStructureChanged: bool = false,

        // The number of records added so far.
        recordsAdded: u32 = 0,

        // Not ported: the performance timers and counters (only reported through the progress callback).
    };

    // Helper function to flush dirty nodes to disk
    fn flushDirtyNodes(self: *SortIndex, state: *BuildState) !void {
        for (state.dirtyLeafNodes.keys()) |leafId| {
            if (state.leafRecordsCache.get(leafId)) |leafRecords| {
                try self.updateLeaf(leafId, leafRecords);
                // Remove from cache once written (page is full or being flushed)
                _ = state.leafRecordsCache.orderedRemove(leafId);
            }
        }
        state.dirtyLeafNodes.clearRetainingCapacity();

        if (state.treeStructureChanged) {
            self.markDirty();
            state.treeStructureChanged = false;
        }
    }

    // Helper function to add a record with batching
    fn addRecordBatched(self: *SortIndex, io: std.Io, state: *BuildState, record: IInternalRecord) !void {
        const recordId = record._id;
        const fieldValue = getFieldValue(record.fields, self.fieldName) orelse {
            return;
        };
        const value = fieldValue.value;

        const newEntry: ISortedIndexEntry = .{
            ._id = recordId,
            .value = value,
            .fields = record.fields,
            .valueIdentity = fieldValue.identity,
        };

        // Find the leaf node where this record belongs
        const leafId = try self.findLeafForValue(value) orelse {
            return;
        };

        const leafNode = self.getNode(leafId) orelse {
            return;
        };
        if (leafNode.children.items.len > 0) {
            return;
        }

        // Get leaf records from cache or load from disk
        var leafRecords: *LeafRecords = undefined;
        if (state.leafRecordsCache.get(leafId)) |cached| {
            leafRecords = cached;
        }
        else {
            if (try self.loadLeafRecords(io, leafId)) |loaded| {
                leafRecords = loaded;
            }
            else {
                leafRecords = try self.allocator.create(LeafRecords);
                leafRecords.* = .empty;
            }
            try state.leafRecordsCache.put(self.allocator, leafId, leafRecords);
        }

        // Binary search to find insertion point
        var left: i64 = 0;
        var right: i64 = @as(i64, @intCast(leafRecords.items.len)) - 1;
        var insertIndex: usize = leafRecords.items.len;

        while (left <= right) {
            const mid = @divFloor(left + right, 2);
            const compareResult = try self.compareValues(value, leafRecords.items[@intCast(mid)].value);
            if (compareResult < 0) {
                insertIndex = @intCast(mid);
                right = mid - 1;
            }
            else {
                left = mid + 1;
            }
        }

        try leafRecords.insert(self.allocator, insertIndex, newEntry);
        try state.dirtyLeafNodes.put(self.allocator, leafId, {});

        // If inserted at beginning, mark tree structure as changed
        if (insertIndex == 0 and leafRecords.items.len > 1) {
            state.treeStructureChanged = true;
        }

        self.totalEntries += 1;
        state.recordsAdded += 1;

        // If leaf exceeds split threshold, split it (keep in cache, don't save yet)
        if (@as(f64, @floatFromInt(leafRecords.items.len)) > PAGE_SIZE * LEAF_SPLIT_THRESHOLD) {
            // Not ported: the progress callback message.

            // Split the node (splitLeafNodeInternal modifies leafRecords in place and returns the new node ID and entries)
            const splitResult = try self.splitLeafNodeInternal(io, leafId, leafNode, leafRecords);

            // Update cache with both split nodes
            // leafRecords now contains the first half (modified in place by splitLeafNode)
            try state.leafRecordsCache.put(self.allocator, leafId, leafRecords);
            try state.leafRecordsCache.put(self.allocator, splitResult.newNodeId, splitResult.newEntries);
            try state.dirtyLeafNodes.put(self.allocator, leafId, {});
            try state.dirtyLeafNodes.put(self.allocator, splitResult.newNodeId, {});

            state.treeStructureChanged = true;
        }

        // Flush at configured batch size
        if (state.recordsAdded % BUILD_BATCH_SIZE == 0) {
            try self.flushDirtyNodes(state);
        }
    }

    //
    // Returns true when the checkpoint lists a shard index as completed (`completedShards.includes(shardIndex)`).
    //
    fn isShardCompleted(checkpoint: *const IBuildCheckpoint, shardIndex: u32) bool {
        for (checkpoint.completedShards) |completedShard| {
            if (completedShard == @as(f64, @floatFromInt(shardIndex))) {
                return true;
            }
        }
        return false;
    }

    //
    // Builds the sort index by directly inserting records from the collection.
    // (Zig: the progressCallback parameter and the timing report it receives are not ported; ensureSortIndex passes
    // no callback.)
    //
    pub fn build(self: *SortIndex, io: std.Io, collection: *IBsonCollection) !void {
        // Load checkpoint if it exists (incremental build)
        var loadedCheckpoint = try self.loadCheckpoint(io);

        // If no checkpoint and index is already loaded, return early
        if (loadedCheckpoint == null and self.loaded) {
            return;
        }

        // Initialize or load index
        if (!self.loaded) {
            // Try to load existing index first (in case we're resuming from checkpoint)
            const loaded = try self.load(io);

            if (!loaded) {
                // No existing index - if checkpoint exists, it's stale (e.g., after rebuild)
                // Delete the stale checkpoint and start fresh
                if (loadedCheckpoint != null) {
                    self.deleteCheckpoint(io);
                    loadedCheckpoint = null;
                }

                // Create new index
                // Clear any existing tree nodes to start fresh
                self.treeNodes.clearRetainingCapacity();

                // Create an empty root leaf node to start with (empty children array means it's a leaf)
                const emptyRoot = try self.allocator.create(IBTreeNode);
                emptyRoot.* = .{};

                const rootPageId = try self.uuidGenerator.generate(self.allocator, io); // Generate a new UUID for the root page ID.
                self.rootPageId = rootPageId;

                // Store in the tree nodes map
                try self.treeNodes.put(self.allocator, rootPageId, emptyRoot);

                // Create empty leaf records array
                const emptyRecords = try self.allocator.create(LeafRecords);
                emptyRecords.* = .empty;
                try self.updateLeaf(rootPageId, emptyRecords);

                self.totalEntries = 0;
                self.totalPages = 1; // Start with a single leaf page
            }
            // If loaded successfully, use existing index state
            // Note: this.loaded is set to true by load(), but we continue building if checkpoint exists
        }

        // Create initial checkpoint if it doesn't exist
        var checkpoint: IBuildCheckpoint = undefined;
        if (loadedCheckpoint) |existing| {
            checkpoint = existing;
        }
        else {
            checkpoint = .{
                .completedShards = &.{},
                .currentShard = null,
                .currentShardRecordIndex = 0,
                .totalRecordsProcessed = @floatFromInt(self.totalEntries),
                .lastUpdated = @floatFromInt(std.Io.Clock.real.now(io).toMilliseconds()),
            };
            try self.saveCheckpoint(io, &checkpoint);
        }
        var completedShards: std.ArrayList(f64) = .empty;
        try completedShards.appendSlice(self.allocator, checkpoint.completedShards);

        // Temporarily set loaded to false to allow building to continue
        // We'll set it back to true at the end (or in finally block if aborted)
        self.loaded = false;

        var state: BuildState = .{};

        // Iterate through shards and process records with checkpoint support
        var shardIndex: u32 = 0;
        var shards = collection.iterateShards();
        while (try shards.next(io)) |shardRecords| {
            // Skip if shard is already completed
            if (isShardCompleted(&checkpoint, shardIndex)) {
                shardIndex += 1;
                continue;
            }

            // Determine starting record index for this shard
            var startIndex: f64 = 0;
            if (checkpoint.currentShard != null and checkpoint.currentShard.? == @as(f64, @floatFromInt(shardIndex))) {
                startIndex = checkpoint.currentShardRecordIndex;
            }

            // Process records in this shard starting from startIndex
            for (shardRecords, 0..) |shardRecord, recordIndex| {
                // Skip records before startIndex
                if (@as(f64, @floatFromInt(recordIndex)) < startIndex) {
                    continue;
                }

                // Process record
                try self.addRecordBatched(io, &state, shardRecord);

                // Save checkpoint every 1000 records (not every progress interval to avoid excessive I/O)
                if (state.recordsAdded % 1000 == 0) {
                    // Only flush if there are actually dirty nodes (avoid unnecessary I/O)
                    if (state.dirtyLeafNodes.count() > 0 or state.treeStructureChanged) {
                        try self.flushDirtyNodes(&state);
                    }

                    // Update checkpoint
                    checkpoint.currentShard = @floatFromInt(shardIndex);
                    checkpoint.currentShardRecordIndex = @floatFromInt(recordIndex + 1);
                    checkpoint.totalRecordsProcessed = @floatFromInt(state.recordsAdded);
                    checkpoint.completedShards = completedShards.items;
                    try self.saveCheckpoint(io, &checkpoint);

                    // Mark as loaded so getPage() works even after abort
                    if (isSet(self.rootPageId)) {
                        self.loaded = true;
                    }
                }

                // Not ported: the progress callback report.
            }

            // Shard complete - mark it and update checkpoint
            try completedShards.append(self.allocator, @floatFromInt(shardIndex));
            checkpoint.completedShards = completedShards.items;
            checkpoint.currentShard = null;
            checkpoint.currentShardRecordIndex = 0;
            try self.saveCheckpoint(io, &checkpoint);

            shardIndex += 1;
        }

        // Final flush of any remaining dirty nodes (into batch state)
        try self.flushDirtyNodes(&state);

        // Save tree nodes and metadata (deferred)
        self.markDirty();

        // Flush all deferred writes to storage
        try self.commit(io);

        // Delete checkpoint on successful completion
        self.deleteCheckpoint(io);

        // Ensure index is marked as loaded
        self.loaded = true;

        // Not ported: the final progress callback report.

        self.loaded = true;
    }

    // Find the leftmost leaf node in the B-tree
    fn findLeftmostLeaf(self: *SortIndex) ?[]const u8 {
        const rootPageId = self.rootPageId orelse {
            return null;
        };

        var currentId = rootPageId;
        var currentNode = self.getNode(currentId) orelse {
            return null;
        };

        // Traverse down the leftmost path to a leaf
        while (currentNode.children.items.len > 0) {
            currentId = currentNode.children.items[0];
            currentNode = self.getNode(currentId) orelse {
                return null;
            };
        }

        return currentId;
    }

    //
    // Returns the result of a comparison for the sort direction (TypeScript: `this.direction === 'asc' ? x : -x`).
    //
    // Compare values depending on the sort direction and type.
    // If type is 'date', string values will be converted to Date objects before comparison.
    // If type is 'string', values will be compared as strings.
    // If type is 'number', values will be compared as numbers.
    // If type is not set, it will be inferred from the values.
    // (Zig: the TypeScript parameters a and b are named first and second.)
    //
    fn compareValues(self: *SortIndex, first: BsonValue, second: BsonValue) !i32 {
        var valueA: JsPrimitive = undefined;
        var valueB: JsPrimitive = undefined;
        var inferredType = self.type;

        // If type is not set, infer it from the values
        if (inferredType == null) {
            // Check if first value is a Date object
            if (js_value.isDate(first)) {
                inferredType = .date;
            }
            // Check if first value is a number
            else if (std.mem.eql(u8, js_value.typeOf(first), "number")) {
                inferredType = .number;
            }
            // Check if first value is a string
            else if (std.mem.eql(u8, js_value.typeOf(first), "string")) {
                inferredType = .string;
            }

            // Verify both values are compatible types
            if (inferredType == .date) {
                if (!js_value.isDate(second) and !std.mem.eql(u8, js_value.typeOf(second), "string")) {
                    return errors.throwError("Type mismatch in compareValues: first value is Date, second value is {s},\n{s}\n{s}", .{
                        js_value.typeOf(second),
                        try js_value.jsonStringifyIndented(self.allocator, first),
                        try js_value.jsonStringifyIndented(self.allocator, second),
                    });
                }
            }
            else if (inferredType == .number) {
                if (!std.mem.eql(u8, js_value.typeOf(second), "number")) {
                    return errors.throwError("Type mismatch in compareValues: first value is number, second value is {s},\n{s}\n{s}", .{
                        js_value.typeOf(second),
                        try js_value.jsonStringifyIndented(self.allocator, first),
                        try js_value.jsonStringifyIndented(self.allocator, second),
                    });
                }
            }
            else if (inferredType == .string) {
                if (!std.mem.eql(u8, js_value.typeOf(second), "string")) {
                    return errors.throwError("Type mismatch in compareValues: first value is string, second value is {s},\n{s}\n{s}", .{
                        js_value.typeOf(second),
                        try js_value.jsonStringifyIndented(self.allocator, first),
                        try js_value.jsonStringifyIndented(self.allocator, second),
                    });
                }
            }
        }

        // Convert values based on the specified or inferred type
        if (inferredType == .date) {
            // (Zig: `new Date(string)` never throws, so the TypeScript try/catch fallbacks are not needed. A value that
            // is not converted is kept and converted with ToPrimitive, as the comparison operators below do.)
            valueA = try js_value.toPrimitive(self.allocator, first);
            if (first == .string) {
                valueA = .{ .number = js_value.parseDate(first.string) };
            }

            valueB = try js_value.toPrimitive(self.allocator, second);
            if (second == .string) {
                valueB = .{ .number = js_value.parseDate(second.string) };
            }
        }
        else if (inferredType == .string) {
            // Convert to strings for string comparison
            const stringA = try js_value.toString(self.allocator, first);
            const stringB = try js_value.toString(self.allocator, second);

            // Use localeCompare for proper string comparison
            const compareResult = locale_compare.localeCompare(stringA, stringB);
            if (compareResult < 0) {
                return if (self.direction == .asc) -1 else 1;
            }
            if (compareResult > 0) {
                return if (self.direction == .asc) 1 else -1;
            }
            return 0;
        }
        else if (inferredType == .number) {
            // Convert to numbers for numeric comparison
            const numberA = try js_value.toNumber(self.allocator, first);
            const numberB = try js_value.toNumber(self.allocator, second);

            // Handle NaN cases - treat NaN as smaller than any number
            if (std.math.isNan(numberA) and std.math.isNan(numberB)) {
                return 0;
            }
            if (std.math.isNan(numberA)) {
                return if (self.direction == .asc) -1 else 1;
            }
            if (std.math.isNan(numberB)) {
                return if (self.direction == .asc) 1 else -1;
            }
            valueA = .{ .number = numberA };
            valueB = .{ .number = numberB };
        }
        else {
            valueA = try js_value.toPrimitive(self.allocator, first);
            valueB = try js_value.toPrimitive(self.allocator, second);
        }

        if (js_value.primitiveLessThan(valueA, valueB)) {
            return if (self.direction == .asc) -1 else 1;
        }
        if (js_value.primitiveLessThan(valueB, valueA)) {
            return if (self.direction == .asc) 1 else -1;
        }
        return 0;
    }

    // Save leaf records to separate file using serialization library while preserving exact binary format
    //
    // Serializer function for leaf records (without version, as save() handles that)
    //
    fn serializeLeafRecords(allocator: std.mem.Allocator, leafRecords: *LeafRecords, serializer: ISerializer) anyerror!void {
        // Write record count (4 bytes LE)
        try serializer.writeUInt32(@intCast(leafRecords.items.len));

        // Write each record
        for (leafRecords.items) |entry| {
            // Write record ID with length prefix
            try serializer.writeBuffer(entry._id);

            // Write value as BSON with length prefix
            try serializer.writeBSON(try BsonDocument.fromFields(allocator, &.{.{ .key = "value", .value = entry.value }}));

            // Write record as BSON with length prefix
            try serializer.writeBSON(entry.fields);
        }
    }

    //
    // Updates the leaf records in the cache and marks it dirty for the next commit.
    //
    fn updateLeaf(self: *SortIndex, pageId: []const u8, leafRecords: *LeafRecords) !void {
        try self.leafCache.put(self.allocator, pageId, .{ .records = leafRecords, .dirty = true });
        self.markDirty();
    }

    //
    // Deserializer function for leaf records
    //
    fn deserializeLeafRecords(allocator: std.mem.Allocator, self: *SortIndex, deserializer: IDeserializer) anyerror!*LeafRecords {
        _ = self;
        // Read record count (4 bytes LE)
        const recordCount = try deserializer.readUInt32();

        const leafRecords = try allocator.create(LeafRecords);
        leafRecords.* = .empty;

        // Read each record
        var recordIndex: u32 = 0;
        while (recordIndex < recordCount) : (recordIndex += 1) {
            // Read record ID with length prefix
            const recordId = try allocator.dupe(u8, try deserializer.readBuffer());

            // Read value BSON with length prefix
            const valueObj = try deserializer.readBSON();
            const value = valueObj.get("value") orelse BsonValue.undefined;

            // Read record BSON with length prefix
            const fields = try deserializer.readBSON();

            try leafRecords.append(allocator, .{
                ._id = recordId,
                .value = value,
                .fields = fields,
            });
        }

        return leafRecords;
    }

    //
    // The deserializers for every supported version of a leaf page file.
    //
    const leaf_deserializers = [_]serialization.DeserializerEntry(*LeafRecords, *SortIndex){
        .{ .version = 1, .deserializer = deserializeLeafRecords },
    };

    //
    // Loads leaf records: from cache if present, else from storage (and caches the result).
    //
    fn loadLeafRecords(self: *SortIndex, io: std.Io, pageId: []const u8) !?*LeafRecords {
        if (self.leafCache.get(pageId)) |cached| {
            return cached.records;
        }
        const filePath = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.indexDirectory, pageId });
        const leafRecords = try serialization.load(
            *LeafRecords,
            self.allocator,
            io,
            self.storage,
            filePath,
            "IDXP",
            self,
            &leaf_deserializers,
        );
        if (leafRecords) |loaded| {
            try self.leafCache.put(self.allocator, pageId, .{ .records = loaded, .dirty = false });
        }
        return leafRecords;
    }

    //
    // Marks the leaf for deletion by setting its records to empty and dirty to true.
    // The file will be deleted from storage on the next commit.
    //
    fn markLeafForDelete(self: *SortIndex, leafId: []const u8) !void {
        const emptyRecords = try self.allocator.create(LeafRecords);
        emptyRecords.* = .empty;
        try self.leafCache.put(self.allocator, leafId, .{ .records = emptyRecords, .dirty = true });
        self.markDirty();
    }

    //
    // Returns true if there are uncommitted changes.
    //
    pub fn dirty(self: *const SortIndex) bool {
        return self._dirty;
    }

    //
    // Writes all dirty leaves and tree to storage, deletes marked leaves.
    // Dirty flags are cleared; the leaf cache remains populated for fast subsequent reads.
    //
    pub fn commit(self: *SortIndex, io: std.Io) !void {
        const rootPageId = self.rootPageId orelse {
            return errors.throwError("Root page ID is not set. Cannot save tree.", .{});
        };

        //
        // Save leaf nodes.
        //
        var deletedLeafIds: std.ArrayList([]const u8) = .empty;
        var leafEntries = self.leafCache.iterator();
        while (leafEntries.next()) |leafEntry| {
            const leafId = leafEntry.key_ptr.*;
            const entry = leafEntry.value_ptr;
            if (entry.dirty) {
                if (entry.records.items.len == 0) {
                    // Leaf was marked for deletion.
                    const filePath = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.indexDirectory, leafId });
                    try self.storage.deleteFile(self.allocator, io, filePath);
                    try deletedLeafIds.append(self.allocator, leafId);
                }
                else {
                    // Leaf records were updated.
                    try serialization.save(
                        self.allocator,
                        io,
                        self.storage,
                        try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.indexDirectory, leafId }),
                        entry.records,
                        1,
                        "IDXP",
                        serializeLeafRecords,
                    );
                    entry.dirty = false;
                }
            }
        }
        for (deletedLeafIds.items) |deletedLeafId| {
            _ = self.leafCache.orderedRemove(deletedLeafId);
        }

        //
        // Save the tree.
        //
        const treeData: ITreeData = .{
            .totalEntries = self.totalEntries,
            .totalPages = self.totalPages,
            .rootPageId = rootPageId,
            .fieldName = self.fieldName,
            .direction = @tagName(self.direction),
            .type = self.type,
            .treeNodes = self.treeNodes,
        };
        try serialization.save(
            self.allocator,
            io,
            self.storage,
            self.treeFilePath,
            treeData,
            2,
            "IDXT",
            serializeTree,
        );

        //
        // No longer dirty.
        //
        self._dirty = false;
    }

    // Not ported: flush (psi replicate and psi verify never flush a database).

    // Get a node from cache or map
    fn getNode(self: *SortIndex, pageId: []const u8) ?*IBTreeNode {
        return self.treeNodes.get(pageId);
    }

    // Not ported: getPage, drop (not used by psi replicate or psi verify).

    //
    // Updates a record in the index without rebuilding the entire index
    // If the indexed field value has changed, the record will be removed and added again
    //
    pub fn updateRecord(self: *SortIndex, io: std.Io, record: IInternalRecord, oldRecord: ?IInternalRecord) !void {
        try self.tryLoad(io);
        if (!self.loaded) {
            return;
        }

        const recordId = record._id;
        var oldField: ?IFieldValue = null;
        if (oldRecord) |existingRecord| {
            oldField = getFieldValue(existingRecord.fields, self.fieldName);
        }

        // First remove old record completely
        var recordRemoved = false;
        if (oldField != null) {
            const oldValue = oldField.?.value;
            // First try to quickly find the specific leaf
            if (try self.findLeafForValue(oldValue)) |leafId| {
                const leafNode = self.getNode(leafId);
                const leafRecords = try self.loadLeafRecords(io, leafId);

                if (leafNode != null and leafNode.?.children.items.len == 0 and leafRecords != null) {
                    // Find the entry with matching ID
                    const entryIndex = findEntryIndex(leafRecords.?, recordId);

                    if (entryIndex != null) {
                        // Remove the entry
                        _ = leafRecords.?.orderedRemove(entryIndex.?);

                        // Check if the leaf node is now empty and needs to be removed
                        if (leafRecords.?.items.len == 0 and self.totalPages > 1) {
                            // Find the previous and next leaf nodes to update pointers
                            // instead of loading all pages, we need to:
                            // 1. Find previous leaf (by navigating the tree and checking nextLeaf)
                            var prevLeafId: ?[]const u8 = null;

                            // Start from the leftmost leaf and follow nextLeaf pointers
                            var currentId = self.findLeftmostLeaf() orelse {
                                return errors.throwError("Left most leaf not found", .{});
                            };
                            var currentNode = self.getNode(currentId);

                            // Walk the chain until we find the leaf that points to our target
                            while (currentNode != null and !std.mem.eql(u8, currentId, leafId)) {
                                if (samePageId(currentNode.?.nextLeaf, leafId)) {
                                    prevLeafId = currentId;
                                    break;
                                }

                                if (!isSet(currentNode.?.nextLeaf)) {
                                    break;
                                }
                                currentId = currentNode.?.nextLeaf.?;
                                currentNode = self.getNode(currentId);
                            }

                            // If we found a previous leaf, update its nextLeaf pointer
                            if (isSet(prevLeafId)) {
                                const prevLeafNode = self.getNode(prevLeafId.?);
                                if (prevLeafNode != null and prevLeafNode.?.children.items.len == 0) {
                                    // Update the next pointer to skip this empty node
                                    prevLeafNode.?.nextLeaf = leafNode.?.nextLeaf;
                                    self.markDirty();
                                }
                            }

                            // Update the previousLeaf pointer of the next node
                            if (isSet(leafNode.?.nextLeaf)) {
                                const nextLeafNode = self.getNode(leafNode.?.nextLeaf.?);
                                if (nextLeafNode != null and nextLeafNode.?.children.items.len == 0) {
                                    nextLeafNode.?.previousLeaf = prevLeafId;
                                    self.markDirty();
                                }
                            }

                            // Remove leaf records file
                            try self.markLeafForDelete(leafId);

                            // Remove the node from the treeNodes map
                            _ = self.treeNodes.orderedRemove(leafId);

                            // Decrement total pages since we're effectively removing this page
                            self.totalPages -= 1;
                        }
                        else {
                            // Update leaf records
                            try self.updateLeaf(leafId, leafRecords.?);
                        }

                        // Decrement total entries
                        self.totalEntries -= 1;
                        recordRemoved = true;
                    }
                }
            }

            // If we didn't find the record in the expected leaf, we need to check all pages with the same value
            if (!recordRemoved) {
                // We need to find the pages that might contain records with this value
                // First, get all records with this value
                const matchingValues = try self.findByValue(io, oldValue, oldField.?.identity);
                if (matchingValues.len > 0) {
                    // Start with the leftmost leaf and traverse the chain
                    var currentId = self.findLeftmostLeaf() orelse {
                        return errors.throwError("Left most leaf not found.", .{});
                    };
                    var currentNode = self.getNode(currentId);

                    // Keep track of previous node for updating nextLeaf pointers
                    var prevNodeId: ?[]const u8 = null;

                    while (currentNode != null) {
                        if (currentNode.?.children.items.len == 0) {
                            const leafRecords = try self.loadLeafRecords(io, currentId);
                            if (leafRecords != null) {
                                // Find the entry with matching ID
                                const entryIndex = findEntryIndex(leafRecords.?, recordId);

                                if (entryIndex != null) {
                                    // Remove the entry
                                    _ = leafRecords.?.orderedRemove(entryIndex.?);

                                    // Check if the leaf node is now empty and needs to be removed
                                    if (leafRecords.?.items.len == 0 and self.totalPages > 1) {
                                        // If we have a previous node, update its nextLeaf pointer
                                        if (isSet(prevNodeId)) {
                                            const prevNode = self.getNode(prevNodeId.?);
                                            if (prevNode != null and prevNode.?.children.items.len == 0) {
                                                prevNode.?.nextLeaf = currentNode.?.nextLeaf;
                                                self.markDirty();
                                            }
                                        }

                                        // Update the previousLeaf pointer of the next node
                                        if (isSet(currentNode.?.nextLeaf)) {
                                            const nextNode = self.getNode(currentNode.?.nextLeaf.?);
                                            if (nextNode != null and nextNode.?.children.items.len == 0) {
                                                nextNode.?.previousLeaf = prevNodeId;
                                                self.markDirty();
                                            }
                                        }

                                        // Remove leaf records file
                                        try self.markLeafForDelete(currentId);

                                        // Remove the node from the treeNodes map
                                        _ = self.treeNodes.orderedRemove(currentId);

                                        // Decrement total pages since we're effectively removing this page
                                        self.totalPages -= 1;
                                    }
                                    else {
                                        // Update leaf records
                                        try self.updateLeaf(currentId, leafRecords.?);
                                    }

                                    // Decrement total entries
                                    self.totalEntries -= 1;
                                    recordRemoved = true;
                                    break; // Found and removed the record
                                }
                            }
                        }

                        // Move to the next leaf
                        if (!isSet(currentNode.?.nextLeaf)) {
                            break;
                        }
                        prevNodeId = currentId;
                        currentId = currentNode.?.nextLeaf.?;
                        currentNode = self.getNode(currentId);
                    }
                }
            }
        }

        // Now add the record with the new value
        try self.addRecord(io, record);
    }

    //
    // Deletes a record from the index without rebuilding the entire index
    // @param recordId The ID of the record to delete
    // @param value The value of the indexed field, used to help locate the record
    //
    pub fn deleteRecord(self: *SortIndex, io: std.Io, recordId: []const u8, oldRecord: IInternalRecord) !void {
        try self.tryLoad(io);
        if (!self.loaded) {
            return;
        }

        const field = getFieldValue(oldRecord.fields, self.fieldName) orelse {
            // Just assume the record is not indexed.
            return;
        };
        const value = field.value;

        var recordDeleted = false;

        // First try to find the record in the expected leaf
        if (try self.findLeafForValue(value)) |leafId| {
            const leafNode = self.getNode(leafId);
            const leafRecords = try self.loadLeafRecords(io, leafId);

            if (leafNode != null and leafNode.?.children.items.len == 0 and leafRecords != null) {
                // Find the entry with matching ID
                const entryIndex = findEntryIndex(leafRecords.?, recordId);

                if (entryIndex != null) {
                    // Remove the entry
                    _ = leafRecords.?.orderedRemove(entryIndex.?);

                    // If this was the first entry and there are more entries,
                    // update the key in parent nodes
                    if (entryIndex.? == 0 and leafRecords.?.items.len > 0) {
                        try self.updateKeyInParents(leafId, value, leafRecords.?.items[0].value);
                    }

                    // Check if the leaf node is now empty and needs to be removed
                    if (leafRecords.?.items.len == 0 and self.totalPages > 1) {
                        // Find the previous leaf (by navigating the tree and checking nextLeaf)
                        var prevLeafId: ?[]const u8 = "";

                        // Start from the leftmost leaf and follow nextLeaf pointers
                        var currentId = self.findLeftmostLeaf() orelse {
                            return errors.throwError("Left most leaf not found", .{});
                        };

                        var currentNode = self.getNode(currentId);

                        // Walk the chain until we find the leaf that points to our target
                        while (currentNode != null and !std.mem.eql(u8, currentId, leafId)) {
                            if (samePageId(currentNode.?.nextLeaf, leafId)) {
                                prevLeafId = currentId;
                                break;
                            }

                            if (!isSet(currentNode.?.nextLeaf)) {
                                break;
                            }
                            currentId = currentNode.?.nextLeaf.?;
                            currentNode = self.getNode(currentId);
                        }

                        // If we found a previous leaf, update its nextLeaf pointer
                        if (isSet(prevLeafId)) {
                            const prevLeafNode = self.getNode(prevLeafId.?);
                            if (prevLeafNode != null and prevLeafNode.?.children.items.len == 0) {
                                // Update the next pointer to skip this empty node
                                prevLeafNode.?.nextLeaf = leafNode.?.nextLeaf;
                                self.markDirty();
                            }
                        }

                        // Update the previousLeaf pointer of the next node
                        if (isSet(leafNode.?.nextLeaf)) {
                            const nextLeafNode = self.getNode(leafNode.?.nextLeaf.?);
                            if (nextLeafNode != null and nextLeafNode.?.children.items.len == 0) {
                                nextLeafNode.?.previousLeaf = prevLeafId;
                                self.markDirty();
                            }
                        }

                        // Remove leaf records file
                        try self.markLeafForDelete(leafId);

                        // Remove the node from the treeNodes map
                        _ = self.treeNodes.orderedRemove(leafId);

                        // Decrement total pages since we're effectively removing this page
                        self.totalPages -= 1;
                    }
                    else {
                        // Update the leaf records
                        try self.updateLeaf(leafId, leafRecords.?);
                    }

                    // Decrement total entries
                    self.totalEntries -= 1;

                    recordDeleted = true;
                }
            }
        }

        // If we didn't find the record in the expected leaf, try other leaves with matching values
        if (!recordDeleted) {
            // First, get all records with this value
            const matchingValues = try self.findByValue(io, value, field.identity);

            // If there are records with this value, we need to search through the leaves
            if (matchingValues.len > 0) {
                // Start with the leftmost leaf and traverse the chain
                var currentId = self.findLeftmostLeaf() orelse {
                    return errors.throwError("Left most leaf not found.", .{});
                };

                var currentNode = self.getNode(currentId);

                // Keep track of previous node for updating nextLeaf pointers
                var prevNodeId: ?[]const u8 = "";

                while (currentNode != null) {
                    if (currentNode.?.children.items.len == 0) {
                        const leafRecords = try self.loadLeafRecords(io, currentId);
                        if (leafRecords != null) {
                            // Find the entry with matching ID
                            const entryIndex = findEntryIndex(leafRecords.?, recordId);

                            if (entryIndex != null) {
                                // Remove the entry
                                _ = leafRecords.?.orderedRemove(entryIndex.?);

                                // If this was the first entry and there are more entries,
                                // update the key in parent nodes
                                if (entryIndex.? == 0 and leafRecords.?.items.len > 0) {
                                    try self.updateKeyInParents(currentId, value, leafRecords.?.items[0].value);
                                }

                                // Check if the leaf node is now empty and needs to be removed
                                if (leafRecords.?.items.len == 0 and self.totalPages > 1) {
                                    // If we have a previous node, update its nextLeaf pointer
                                    if (isSet(prevNodeId)) {
                                        const prevNode = self.getNode(prevNodeId.?);
                                        if (prevNode != null and prevNode.?.children.items.len == 0) {
                                            prevNode.?.nextLeaf = currentNode.?.nextLeaf;
                                            self.markDirty();
                                        }
                                    }

                                    // Update the previousLeaf pointer of the next node
                                    if (isSet(currentNode.?.nextLeaf)) {
                                        const nextNode = self.getNode(currentNode.?.nextLeaf.?);
                                        if (nextNode != null and nextNode.?.children.items.len == 0) {
                                            nextNode.?.previousLeaf = prevNodeId;
                                            self.markDirty();
                                        }
                                    }

                                    // Remove leaf records file
                                    try self.markLeafForDelete(currentId);

                                    // Remove the node from the treeNodes map
                                    _ = self.treeNodes.orderedRemove(currentId);

                                    // Decrement total pages since we're effectively removing this page
                                    self.totalPages -= 1;
                                }
                                else {
                                    // Update the leaf records
                                    try self.updateLeaf(currentId, leafRecords.?);
                                }

                                // Decrement total entries
                                self.totalEntries -= 1;

                                recordDeleted = true;
                                break; // Found and removed the record
                            }
                        }
                    }

                    // Move to the next leaf
                    if (!isSet(currentNode.?.nextLeaf)) {
                        break;
                    }
                    prevNodeId = currentId;
                    currentId = currentNode.?.nextLeaf.?;
                    currentNode = self.getNode(currentId);
                }
            }
        }

        // Update metadata if we found and removed a record
        if (recordDeleted) {
            self.markDirty();
        }
    }

    //
    // Finds the leaf node that would contain a value
    //
    fn findLeafForValue(self: *SortIndex, value: BsonValue) !?[]const u8 {
        const rootPageId = self.rootPageId orelse {
            return null;
        };

        const rootNode = self.getNode(rootPageId) orelse {
            return null;
        };

        var currentId = rootPageId;
        var currentNode = rootNode;

        // Traverse down to leaf
        while (currentNode.children.items.len > 0) {
            // Find the appropriate child based on the value
            var childIndex: usize = 0;

            for (currentNode.keys.items, 0..) |key, keyIndex| {
                if (try self.compareValues(value, key) > 0) {
                    childIndex = keyIndex + 1;
                }
                else {
                    break;
                }
            }

            if (childIndex >= currentNode.children.items.len) {
                childIndex = currentNode.children.items.len - 1;
            }

            currentId = currentNode.children.items[childIndex];
            currentNode = self.getNode(currentId) orelse {
                return null;
            };
        }

        return currentId;
    }

    //
    // Updates a key value in parent nodes when the first entry in a leaf changes
    // This is essential for maintaining the B-tree structure when the minimum key in a leaf node changes
    // Using parent references for efficient traversal
    //
    fn updateKeyInParents(self: *SortIndex, nodeId: []const u8, oldKey: BsonValue, newKey: BsonValue) !void {
        if (nodeId.len == 0) {
            return;
        }

        const node = self.getNode(nodeId) orelse {
            return;
        };
        const parentId = node.parentId orelse {
            return;
        };
        if (parentId.len == 0) {
            return;
        }

        const parentNode = self.getNode(parentId) orelse {
            return;
        };

        // Find the index of the key that references this node
        // If this isn't the leftmost child (i > 0), it has a key in the parent
        if (indexOfChild(parentNode.children.items, nodeId)) |childIndex| {
            if (childIndex > 0 and try self.compareValues(parentNode.keys.items[childIndex - 1], oldKey) == 0) {
                parentNode.keys.items[childIndex - 1] = newKey;
                self.markDirty();
            }
        }

        // Recursively update parent nodes if needed
        try self.updateKeyInParents(parentId, oldKey, newKey);
    }

    //
    // Adds a new record to the index without rebuilding the entire index
    //
    pub fn addRecord(self: *SortIndex, io: std.Io, record: IInternalRecord) !void {
        try self.tryLoad(io);
        if (!self.loaded) {
            return;
        }

        const recordId = record._id;

        // If the field doesn't exist in the record, don't add it to the index
        const fieldValue = getFieldValue(record.fields, self.fieldName) orelse {
            return;
        };
        const value = fieldValue.value;

        // Create the new entry
        const newEntry: ISortedIndexEntry = .{
            ._id = recordId,
            .value = value,
            .fields = record.fields,
            .valueIdentity = fieldValue.identity,
        };

        // Find the leaf node where this record belongs
        const leafId = try self.findLeafForValue(value) orelse {
            return; // Should not happen with a properly initialized tree
        };

        const leafNode = self.getNode(leafId) orelse {
            return;
        };
        if (leafNode.children.items.len > 0) {
            return;
        }

        // Get the leaf records
        var leafRecords: *LeafRecords = undefined;
        if (try self.loadLeafRecords(io, leafId)) |loaded| {
            leafRecords = loaded;
        }
        else {
            leafRecords = try self.allocator.create(LeafRecords);
            leafRecords.* = .empty;
        }

        // Insert the entry in the correct position using binary search
        var left: i64 = 0;
        var right: i64 = @as(i64, @intCast(leafRecords.items.len)) - 1;
        var insertIndex: usize = leafRecords.items.len; // Default to end of array

        // Binary search to find insertion point
        while (left <= right) {
            const mid = @divFloor(left + right, 2);
            const compareResult = try self.compareValues(value, leafRecords.items[@intCast(mid)].value);
            if (compareResult < 0) {
                // New value should go before the middle element
                // (compareValues already accounts for direction)
                insertIndex = @intCast(mid);
                right = mid - 1;
            }
            else {
                // New value should go after the middle element
                left = mid + 1;
            }
        }

        // Insert the entry at the found position
        try leafRecords.insert(self.allocator, insertIndex, newEntry);

        // If this was inserted at the beginning, update keys in parent nodes
        if (insertIndex == 0 and leafRecords.items.len > 1) {
            try self.updateKeyInParents(leafId, leafRecords.items[1].value, value);
        }

        // If the leaf is now too large, split it
        if (@as(f64, @floatFromInt(leafRecords.items.len)) > PAGE_SIZE * LEAF_SPLIT_THRESHOLD) {
            try self.splitLeafNode(io, leafId, leafNode, leafRecords); // Save immediately in regular addRecord
        }
        else {
            // Just update the leaf records
            try self.updateLeaf(leafId, leafRecords);
        }

        // Increment total entries
        self.totalEntries += 1;

        // Update metadata
        self.markDirty();
    }

    //
    // The result of splitLeafNodeInternal (TypeScript: an anonymous object type).
    //
    const ISplitResult = struct {
        // The id of the new leaf node.
        newNodeId: []const u8,

        // The entries of the new leaf node (the second half of the split).
        newEntries: *LeafRecords,
    };

    //
    // Sorts entries by value with a stable insertion sort (TypeScript: `records.sort((a, b) => compareValues(...))`;
    // Array.prototype.sort is stable and compareValues can throw, so std.mem.sort cannot be used).
    //
    fn sortEntries(self: *SortIndex, entries: []ISortedIndexEntry) !void {
        var index: usize = 1;
        while (index < entries.len) : (index += 1) {
            const current = entries[index];
            var position = index;
            while (position > 0 and try self.compareValues(entries[position - 1].value, current.value) > 0) {
                entries[position] = entries[position - 1];
                position -= 1;
            }
            entries[position] = current;
        }
    }

    //
    // Internal function that splits a leaf node without saving to disk
    // @returns An object with the new node ID and the new entries (second half of the split)
    //
    fn splitLeafNodeInternal(self: *SortIndex, io: std.Io, nodeId: []const u8, node: *IBTreeNode, leafRecords: *LeafRecords) !ISplitResult {
        if (node.children.items.len > 0) {
            return errors.throwError("Cannot split internal node as leaf node", .{});
        }

        // Ensure entries are properly sorted first
        try self.sortEntries(leafRecords.items);

        // Split point
        const splitIndex = leafRecords.items.len / 2;

        // Create new leaf node with the second half
        const newEntries = try self.allocator.create(LeafRecords);
        newEntries.* = .empty;
        try newEntries.appendSlice(self.allocator, leafRecords.items[splitIndex..]);
        leafRecords.shrinkRetainingCapacity(splitIndex);
        const newNodeId = try self.uuidGenerator.generate(self.allocator, io);

        const newNode = try self.allocator.create(IBTreeNode);
        newNode.* = .{
            // Node is a leaf (children array is empty)
            .nextLeaf = node.nextLeaf,
            .previousLeaf = nodeId,
            .parentId = node.parentId, // Copy parent from original node
        };
        try self.treeNodes.put(self.allocator, newNodeId, newNode);

        // Update pointers in the original node
        node.nextLeaf = newNodeId;

        // Update the previousLeaf pointer of the node that comes after the new node
        if (isSet(newNode.nextLeaf)) {
            if (self.getNode(newNode.nextLeaf.?)) |nextNode| {
                if (nextNode.children.items.len == 0) {
                    nextNode.previousLeaf = newNodeId;
                }
            }
        }

        // Create or update parent node to maintain the B-tree structure
        if (samePageId(nodeId, self.rootPageId) and node.children.items.len == 0) {
            // If we're splitting the root, we need to create a new root
            const newRootId = try self.uuidGenerator.generate(self.allocator, io);
            const newRoot = try self.allocator.create(IBTreeNode);
            newRoot.* = .{
                // Internal node (has children)
                .parentId = null,
            };
            try newRoot.keys.append(self.allocator, newEntries.items[0].value);
            try newRoot.children.append(self.allocator, nodeId);
            try newRoot.children.append(self.allocator, newNodeId);
            try self.treeNodes.put(self.allocator, newRootId, newRoot);

            // Update parent references for children
            node.parentId = newRootId;
            newNode.parentId = newRootId;

            // Update the root page ID
            self.rootPageId = newRootId;
        }
        else if (isSet(node.parentId)) {
            // Non-root node splitting - we need to insert the new node into the parent
            const parentId = node.parentId.?;
            if (self.getNode(parentId)) |parentNode| {
                if (parentNode.children.items.len > 0) {
                    // Find the position of the original node in the parent's children array
                    if (indexOfChild(parentNode.children.items, nodeId)) |childIndex| {
                        // Insert the new node after the original node in the parent's children array
                        try parentNode.children.insert(self.allocator, childIndex + 1, newNodeId);

                        // Insert the separator key (first key in new leaf) in the parent's keys array
                        try parentNode.keys.insert(self.allocator, childIndex, newEntries.items[0].value);

                        // If the parent node is now too large, we need to split it too
                        if (@as(f64, @floatFromInt(parentNode.keys.items.len)) > (DEFAULT_KEY_SIZE * SPLIT_KEYS_THRESHOLD)) {
                            try self.splitInternalNode(io, parentId, parentNode);
                        }
                    }
                }
            }
        }

        // Increment total pages since we created a new leaf page
        self.totalPages += 1;

        return .{ .newNodeId = newNodeId, .newEntries = newEntries };
    }

    //
    // Splits a leaf node when it gets too large and saves to disk
    //
    fn splitLeafNode(self: *SortIndex, io: std.Io, nodeId: []const u8, node: *IBTreeNode, leafRecords: *LeafRecords) !void {
        const splitResult = try self.splitLeafNodeInternal(io, nodeId, node, leafRecords);

        // Save leaf records for both nodes
        try self.updateLeaf(nodeId, leafRecords);
        try self.updateLeaf(splitResult.newNodeId, splitResult.newEntries);

        // Save both nodes
        self.markDirty();
    }

    //
    // Converts a leaf entry to a query result (TypeScript: `({ _id: entry._id, ...entry.fields })`).
    //
    fn toSortIndexRecord(self: *SortIndex, entry: ISortedIndexEntry) !ISortIndexRecord {
        var result: BsonDocument = .empty;
        try result.put(self.allocator, "_id", .{ .string = entry._id });
        for (entry.fields.fields.items) |field| {
            try result.put(self.allocator, field.key, field.value);
        }
        return result;
    }

    //
    // Appends the entries of a leaf whose value is strictly equal to value (TypeScript: `filter(entry => entry.value === value)`).
    // Returns the number of entries appended.
    //
    fn appendMatches(self: *SortIndex, matchingEntries: *std.ArrayList(ISortedIndexEntry), leafRecords: *const LeafRecords, value: BsonValue, valueIdentity: ?*const BsonValue) !usize {
        var matchCount: usize = 0;
        for (leafRecords.items) |entry| {
            if (strictEqualsValue(entry.value, entry.valueIdentity, value, valueIdentity)) {
                try matchingEntries.append(self.allocator, entry);
                matchCount += 1;
            }
        }
        return matchCount;
    }

    // Find records by exact value using binary search on the sorted index
    // (Zig: valueIdentity is the identity of the value when it is a JS object (see strictEqualsValue), or null.)
    pub fn findByValue(self: *SortIndex, io: std.Io, value: BsonValue, valueIdentity: ?*const BsonValue) ![]ISortIndexRecord {
        try self.tryLoad(io);
        if (!self.loaded) {
            return &.{};
        }

        var matchingEntries: std.ArrayList(ISortedIndexEntry) = .empty;

        // First try to find the specific leaf that should contain this value
        const leafId = try self.findLeafForValue(value) orelse {
            // No leaf found that might contain this value
            return &.{};
        };

        // Process the initial leaf node
        const maybeLeafNode = self.getNode(leafId);
        const maybeLeafRecords = try self.loadLeafRecords(io, leafId);

        if (maybeLeafNode != null and maybeLeafNode.?.children.items.len == 0 and maybeLeafRecords != null) {
            const leafNode = maybeLeafNode.?;
            // Find all entries with the exact value
            const matches = try self.appendMatches(&matchingEntries, maybeLeafRecords.?, value, valueIdentity);

            if (matches > 0) {
                // Due to B-tree split operations, records with the same value could potentially
                // be in different leaf nodes. We need to check adjacent nodes.

                // Check forward in the linked list for additional matches
                var nextId = leafNode.nextLeaf;
                while (isSet(nextId)) {
                    const nextNode = self.getNode(nextId.?) orelse {
                        break;
                    };
                    if (nextNode.children.items.len > 0) {
                        break;
                    }

                    const nextRecords = try self.loadLeafRecords(io, nextId.?) orelse {
                        break;
                    };
                    if (nextRecords.items.len == 0) {
                        break;
                    }

                    // Find any matching records in this leaf
                    const nextMatches = try self.appendMatches(&matchingEntries, nextRecords, value, valueIdentity);

                    if (nextMatches == 0 and try self.compareValues(nextRecords.items[0].value, value) > 0) {
                        // If first value > search value, we're done looking forward
                        // compareValues already accounts for direction
                        break;
                    }

                    nextId = nextNode.nextLeaf;
                }

                // Check backward in the linked list for additional matches
                var prevId = leafNode.previousLeaf;
                while (isSet(prevId)) {
                    const prevNode = self.getNode(prevId.?) orelse {
                        break;
                    };
                    if (prevNode.children.items.len > 0) {
                        break;
                    }

                    const prevRecords = try self.loadLeafRecords(io, prevId.?) orelse {
                        break;
                    };
                    if (prevRecords.items.len == 0) {
                        break;
                    }

                    // Find any matching records in this leaf
                    const prevMatches = try self.appendMatches(&matchingEntries, prevRecords, value, valueIdentity);

                    if (prevMatches == 0 and try self.compareValues(prevRecords.items[prevRecords.items.len - 1].value, value) < 0) {
                        // If last value < search value, we're done looking backward
                        // compareValues already accounts for direction
                        break;
                    }

                    prevId = prevNode.previousLeaf;
                }
            }
        }

        // If we still haven't found any matching records, we need to search all leaves
        // This is necessary because the B-tree structure might have sent us to the wrong leaf
        // especially in test scenarios with small datasets
        if (matchingEntries.items.len == 0) {
            // Start with the leftmost leaf
            var currentId = self.findLeftmostLeaf();
            while (isSet(currentId)) {
                const currentNode = self.getNode(currentId.?) orelse {
                    break;
                };
                if (currentNode.children.items.len > 0) {
                    break;
                }

                const currentRecords = try self.loadLeafRecords(io, currentId.?) orelse {
                    if (!isSet(currentNode.nextLeaf)) {
                        break;
                    }
                    currentId = currentNode.nextLeaf;
                    continue;
                };

                // Check each record
                _ = try self.appendMatches(&matchingEntries, currentRecords, value, valueIdentity);

                if (!isSet(currentNode.nextLeaf)) {
                    break;
                }
                currentId = currentNode.nextLeaf;
            }
        }

        // Return the matching records
        const results = try self.allocator.alloc(ISortIndexRecord, matchingEntries.items.len);
        for (matchingEntries.items, 0..) |entry, entryIndex| {
            results[entryIndex] = try self.toSortIndexRecord(entry);
        }
        return results;
    }

    // Not ported: findByRange (not used by psi replicate or psi verify).

    //
    // Splits an internal node when it gets too large
    //
    fn splitInternalNode(self: *SortIndex, io: std.Io, nodeId: []const u8, node: *IBTreeNode) !void {
        if (node.children.items.len == 0) {
            return; // Only process internal nodes
        }

        // Find the middle index
        const middleIndex = node.keys.items.len / 2;

        // The middle key will be promoted to the parent
        const middleKey = node.keys.items[middleIndex];

        // Create a new internal node for the right half
        const newNodeId = try self.uuidGenerator.generate(self.allocator, io);
        const newNode = try self.allocator.create(IBTreeNode);
        newNode.* = .{
            // Internal node (has children)
            .parentId = node.parentId,
        };
        // Take keys after the middle
        try newNode.keys.appendSlice(self.allocator, node.keys.items[middleIndex + 1 ..]);
        node.keys.shrinkRetainingCapacity(middleIndex + 1);
        // Take children after the middle
        if (middleIndex + 1 < node.children.items.len) {
            try newNode.children.appendSlice(self.allocator, node.children.items[middleIndex + 1 ..]);
            node.children.shrinkRetainingCapacity(middleIndex + 1);
        }
        try self.treeNodes.put(self.allocator, newNodeId, newNode);

        // Remove the middle key from the original node (it goes up to the parent)
        _ = node.keys.orderedRemove(middleIndex);

        // Update parent references for all children of the new node
        for (newNode.children.items) |childId| {
            if (self.getNode(childId)) |childNode| {
                childNode.parentId = newNodeId;
            }
        }

        // If this is the root node, create a new root
        if (samePageId(nodeId, self.rootPageId)) {
            const newRootId = try self.uuidGenerator.generate(self.allocator, io);
            const newRoot = try self.allocator.create(IBTreeNode);
            newRoot.* = .{
                // Internal node (has children)
                .parentId = null,
            };
            try newRoot.keys.append(self.allocator, middleKey);
            try newRoot.children.append(self.allocator, nodeId);
            try newRoot.children.append(self.allocator, newNodeId);
            try self.treeNodes.put(self.allocator, newRootId, newRoot);

            // Update parent references
            node.parentId = newRootId;
            newNode.parentId = newRootId;

            // Update the root page ID
            self.rootPageId = newRootId;
        }
        else if (isSet(node.parentId)) {
            // Insert into parent node
            const parentId = node.parentId.?;
            if (self.getNode(parentId)) |parentNode| {
                if (parentNode.children.items.len > 0) {
                    // Find the position of the original node in the parent's children array
                    if (indexOfChild(parentNode.children.items, nodeId)) |childIndex| {
                        // Insert the new node after the original node
                        try parentNode.children.insert(self.allocator, childIndex + 1, newNodeId);

                        // Insert the middle key
                        try parentNode.keys.insert(self.allocator, childIndex, middleKey);

                        // Check if the parent needs to be split
                        if (@as(f64, @floatFromInt(parentNode.keys.items.len)) > (DEFAULT_KEY_SIZE * SPLIT_KEYS_THRESHOLD)) {
                            try self.splitInternalNode(io, parentId, parentNode);
                        }
                    }
                }
            }
        }
    }

    // Not ported: formatValueForDisplay, visualizeTree, analyzeTreeStructure (debugging helpers).
};
