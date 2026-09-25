const std = @import("std");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const bdb = @import("bdb-zig");
const api = @import("api-zig");
const media_file_database = @import("media-file-database.zig");
const tree = @import("tree.zig");
const retry_operations = @import("retry-operations.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const merkle_diff = merkle_tree_zig.merkle_diff;
const errors = utils.errors;
const log = &utils.log.log;
const retry = utils.retry.retry;
const IStorage = storage_zig.storage.IStorage;
const walkDirectory = storage_zig.walk_directory.walkDirectory;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const ITimestampProvider = utils.timestamp_provider.ITimestampProvider;
const LARGE_FILE_TIMEOUT = api.constants.LARGE_FILE_TIMEOUT;
const ProgressCallback = media_file_database.ProgressCallback;
const createMediaFileDatabase = media_file_database.createMediaFileDatabase;
const loadSortIndexes = media_file_database.loadSortIndexes;
const createDatabase = media_file_database.createDatabase;
const updateDatabaseConfig = api.database_config.updateDatabaseConfig;
const BsonDatabase = bdb.database.BsonDatabase;
const IBsonCollection = bdb.collection.IBsonCollection;
const IInternalRecord = bdb.shard.IInternalRecord;
const compareTrees = merkle_tree_zig.compare.compareTrees;
const deleteItem = merkle_tree.deleteItem;
const findDifferingNodes = merkle_diff.findDifferingNodes;
const getItemInfo = merkle_tree.getItemInfo;
const IMerkleTree = merkle_tree.IMerkleTree;
const MerkleNode = merkle_tree.MerkleNode;
const upsertItem = merkle_tree.upsertItem;
const loadMerkleTree = tree.loadMerkleTree;
const merkleTreeExists = tree.merkleTreeExists;
const saveMerkleTree = tree.saveMerkleTree;
const stampDatabaseStateLocked = tree.stampDatabaseStateLocked;
const loadCollectionMerkleTree = tree.loadCollectionMerkleTree;
const loadShardMerkleTree = tree.loadShardMerkleTree;
const loadDatabaseMerkleTree = bdb.merkle_tree.loadDatabaseMerkleTree;
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// Result of the replication process.
//
pub const IReplicationResult = struct {
    //
    // The total number of files imported.
    //
    filesImported: u64,

    //
    // The number of files copied to the destination storage.
    //
    copiedFiles: u64,

    //
    // The number of BSON database records copied/updated in the destination database.
    //
    copiedRecords: u64,

    //
    // List of file names that were pruned from the destination.
    //
    prunedFiles: []const []const u8,

    //
    // Names of files the source's merkle tree describes but the source does not hold.
    //
    // Only ever non-empty for a partial replica, which is exactly what a phone holds: its tree is the
    // whole origin's, and the files it has are a subset. Reported rather than silently dropped, so a
    // replication that copied less than the tree describes says how much less.
    //
    missingFromSource: []const []const u8,
};

//
// The isCancelled option of IReplicateOptions (TypeScript: `() => boolean`).
// (Zig: a closure; `function` is called with `context`.)
//
pub const IsCancelledCallback = struct {
    // The state of the callback, passed to function.
    context: ?*anyopaque,

    // The callback function.
    function: *const fn (context: ?*anyopaque) bool,

    //
    // Invokes the callback.
    //
    pub fn call(self: IsCancelledCallback) bool {
        return self.function(self.context);
    }
};

//
// Options for the replication process.
// (Zig: the TypeScript optional booleans default to false, which is how TypeScript treats undefined.)
//
pub const IReplicateOptions = struct {
    //
    // Path filter to only replicate files matching this path (file or directory).
    //
    pathFilter: ?[]const u8 = null,

    //
    // If true, allows replication even if source and destination have different database IDs.
    //
    force: bool = false,

    //
    // If true, only copy thumb directory assets. Asset and display files will be lazily copied when needed.
    //
    partial: bool = false,

    //
    // Answers whether the caller has asked for the replication to stop. Checked at every file and
    // every record, so pressing Cancel on the job stops the copy rather than waiting for a database
    // of any size to finish copying itself.
    //
    isCancelled: ?IsCancelledCallback = null,
};

//
// Formats a progress message into a buffer (the messages are only valid during the progress callback).
// (No TypeScript counterpart: TypeScript uses template strings.)
//
fn reportProgress(progressCallback: ?ProgressCallback, comptime format: []const u8, args: anytype) void {
    const callback = progressCallback orelse {
        return;
    };
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, format, args) catch buffer[0..];
    callback.call(message);
}

//
// Stops a replication that has been cancelled, at the next file or record it reaches.
//
// It throws rather than returning, so a cancel takes the whole run down at once. Returning would
// leave each loop to notice separately and hand back a half-copied database described by a result
// that says it finished.
//
fn throwIfCancelled(isCancelled: ?IsCancelledCallback) !void {
    if (isCancelled != null and isCancelled.?.call()) {
        return errors.throwError("Replication was cancelled.", .{});
    }
}

//
// The state that the copyAsset and processFile closures of replicateFiles capture.
// (No TypeScript counterpart: TypeScript closures capture the variables of replicateFiles.)
//
const ReplicateFilesState = struct {
    // Allocates everything replicateFiles creates.
    allocator: std.mem.Allocator,

    // Used for the storage calls.
    io: std.Io,

    // The source files tree.
    merkleTree: *IMerkleTree,

    // The destination files tree (TypeScript: the destMerkleTree parameter, reassigned by the closures).
    destMerkleTree: *IMerkleTree,

    // The storage the files are copied to.
    destAssetStorage: IStorage,

    // The storage the destination files tree is saved to.
    destMetadataStorage: IStorage,

    // The storage the files are copied from.
    sourceAssetStorage: IStorage,

    // The replication options.
    options: ?IReplicateOptions,

    // Reports progress.
    progressCallback: ?ProgressCallback,

    // The replication result being accumulated.
    result: *IReplicationResult,

    // The names of the files the source does not hold (result.missingFromSource is a view of these).
    missingFromSource: *std.ArrayList([]const u8),

    // Whether the source holds every file its tree describes.
    sourceIsPartial: bool,

    // What the copied count stood at when the destination tree was last saved part way through.
    copiedFilesAtLastSave: u64,

    //
    // Copies an asset from the source storage to the destination storage.
    // But only when necessary.
    //
    fn copyAsset(self: *ReplicateFilesState, fileName: []const u8, sourceHash: []const u8) !void {
        const allocator = self.allocator;
        const io = self.io;

        // Check if file already exists in destination tree with matching hash.
        const destFileInfo = try getItemInfo(self.destMerkleTree, fileName);
        if (destFileInfo != null and std.mem.eql(u8, destFileInfo.?.hash, sourceHash)) {
            log.verbose(try std.fmt.allocPrint(allocator, "File already exists with correct hash, skipping copy: {s}", .{fileName}));

            // File already exists with correct hash, skip copying.
            // This assumes the file is non-corrupted. To find corrupted files, a verify would be needed.
            reportProgress(self.progressCallback, "Copied {d}", .{self.result.copiedFiles});
            return;
        }

        log.verbose(try std.fmt.allocPrint(allocator, "Copying file: {s}", .{fileName}));
        const assetStorage = self.sourceAssetStorage;
        var srcInfoOperation: retry_operations.InfoOperation("() => assetStorage.info(fileName)") = .{ .allocator = allocator, .storage = assetStorage, .fileName = fileName };
        const srcFileInfo = try retry(io, &srcInfoOperation, 3, 1_000, 2, 30_000, null) orelse {
            // A partial replica's merkle tree is the whole origin's, so it describes files the
            // replica does not hold: that is what makes it partial, and it is what every phone has.
            // Treating the first of those as fatal made a partial replica impossible to replicate or
            // consolidate from at all, which is the one copy of a database that exists when the
            // origin has been lost.
            //
            // So a file the source does not hold is left out and recorded, the way sync.ts already
            // leaves a file it cannot copy rather than ending the pass. A file missing from a source
            // that is NOT partial is still fatal: there the tree and the files should agree, and a
            // gap between them is damage rather than design.
            if (self.sourceIsPartial) {
                log.verbose(try std.fmt.allocPrint(allocator, "Source file \"{s}\" is not in this partial replica, leaving it out.", .{fileName}));
                try self.missingFromSource.append(allocator, fileName);
                self.result.missingFromSource = self.missingFromSource.items;
                return;
            }
            return errors.throwError("Source file \"{s}\" does not exist in the source database.", .{fileName});
        };

        //
        // Copy the file from source to dest.
        //
        var copyOperation: retry_operations.CopyStreamOperation("async () => {\n      const readStream = await assetStorage.readStream(fileName);\n      await destAssetStorage.writeStream(fileName, srcFileInfo.contentType, readStream);\n    }") = .{
            .allocator = allocator,
            .sourceStorage = assetStorage,
            .destStorage = self.destAssetStorage,
            .fileName = fileName,
            .contentType = srcFileInfo.contentType,
        };
        try retry(io, &copyOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, null);

        log.verbose(try std.fmt.allocPrint(allocator, "Copied file: {s}", .{fileName}));

        //
        // Compute hash for the copied file.
        //
        var hashOperation: retry_operations.ComputeStorageHashOperation("async () => computeHash(await destAssetStorage.readStream(fileName))") = .{ .allocator = allocator, .storage = self.destAssetStorage, .fileName = fileName };
        const copiedHash = try retry(io, &hashOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, null);
        if (!std.mem.eql(u8, &copiedHash, sourceHash)) {
            return errors.throwError(
                "Copied file \"{s}\" hash does not match the source hash.\nSource hash: {x}\nCopied hash: {x}\n",
                .{ fileName, sourceHash, &copiedHash },
            );
        }

        log.verbose(try std.fmt.allocPrint(allocator, "Destination file {s} matches source hash {x}", .{ fileName, sourceHash }));

        //
        // Get the info for the copied file.
        //
        var copiedInfoOperation: retry_operations.InfoOperation("() => destAssetStorage.info(fileName)") = .{ .allocator = allocator, .storage = self.destAssetStorage, .fileName = fileName };
        const copiedFileInfo = try retry(io, &copiedInfoOperation, 3, 1_000, 2, 30_000, null) orelse {
            return errors.throwError("Failed to read dest info for file: {s}", .{fileName});
        };

        //
        // Add or update the file in the destination merkle tree.
        //
        self.destMerkleTree.* = try upsertItem(allocator, self.destMerkleTree, .{
            .name = fileName,
            .hash = try allocator.dupe(u8, &copiedHash),
            .length = copiedFileInfo.length,
            .lastModified = copiedFileInfo.lastModified,
        });

        self.result.copiedFiles += 1;

        log.verbose(try std.fmt.allocPrint(allocator, "Added file to destination merkle tree: {s}", .{fileName}));

        reportProgress(self.progressCallback, "Copied {d}", .{self.result.copiedFiles});
    }

    //
    // Copies one of the files the comparison named.
    //
    fn processFile(self: *ReplicateFilesState, fileName: []const u8) !void {
        try throwIfCancelled(if (self.options) |options| options.isCancelled else null);

        // Skip files that don't match the path filter
        if (self.options != null and self.options.?.pathFilter != null and self.options.?.pathFilter.?.len > 0) {
            const pathFilter = try self.allocator.dupe(u8, self.options.?.pathFilter.?);
            std.mem.replaceScalar(u8, pathFilter, '\\', '/'); // Normalize path separators
            const normalizedFileName = try self.allocator.dupe(u8, fileName);
            std.mem.replaceScalar(u8, normalizedFileName, '\\', '/');

            // Check if the file matches the filter (exact match or starts with filter + '/')
            const filterPrefix = try std.fmt.allocPrint(self.allocator, "{s}/", .{pathFilter});
            if (!std.mem.eql(u8, normalizedFileName, pathFilter) and !std.mem.startsWith(u8, normalizedFileName, filterPrefix)) {
                return;
            }
        }

        const sourceFileInfo = try getItemInfo(self.merkleTree, fileName) orelse {
            return errors.throwError("The source tree compared as holding {s} and then did not have it.", .{fileName});
        };

        // The long timeout is the one the copy inside copyAsset already asks for, and it has
        // to be repeated here or it counts for nothing: this wrapper starts a 30 second
        // timer around the whole of copyAsset, so the generous allowances inside it can
        // never be reached. Replicating a real library from S3 failed on the first file
        // that took longer than 30 seconds to move, retried it twice and gave up, and the
        // copy ended there. sync.ts already passes the long timeout at exactly this point,
        // for the same reason.
        var copyAssetOperation: CopyAssetOperation = .{ .state = self, .fileName = fileName, .sourceHash = sourceFileInfo.hash };
        try retry(self.io, &copyAssetOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, try std.fmt.allocPrint(self.allocator, "Failed to copy file {s}", .{fileName}));

        if (self.result.copiedFiles % 100 == 0 and self.result.copiedFiles != self.copiedFilesAtLastSave) {
            // Save the destination merkle tree periodically. The tree of a large database is
            // itself a large file, so it gets the same allowance as one.
            self.copiedFilesAtLastSave = self.result.copiedFiles;
            var saveOperation: retry_operations.SaveMerkleTreeOperation("() => saveMerkleTree(destMerkleTree, destMetadataStorage)") = .{ .allocator = self.allocator, .merkleTree = self.destMerkleTree, .storage = self.destMetadataStorage };
            try retry(self.io, &saveOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, "Failed to save the destination merkle tree part way through a replication");
        }
    }
};

//
// `() => copyAsset(fileName, sourceFileInfo.hash)`.
//
const CopyAssetOperation = struct {
    // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
    pub const source = "() => copyAsset(fileName, sourceFileInfo.hash)";

    // The replicateFiles state that copyAsset uses.
    state: *ReplicateFilesState,

    // The file to copy.
    fileName: []const u8,

    // The hash of the source file.
    sourceHash: []const u8,

    //
    // Copies the asset.
    //
    pub fn run(self: *CopyAssetOperation, io: std.Io) !void {
        _ = io;
        return self.state.copyAsset(self.fileName, self.sourceHash);
    }
};

//
// Replicates files from source to destination.
// (Zig: destMerkleTree is updated through the pointer, where TypeScript reassigns its parameter.)
//
fn replicateFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    merkleTree: *IMerkleTree,
    destMerkleTree: *IMerkleTree,
    destAssetStorage: IStorage,
    destMetadataStorage: IStorage,
    sourceAssetStorage: IStorage,
    options: ?IReplicateOptions,
    progressCallback: ?ProgressCallback,
    result: *IReplicationResult,
) !void {

    // Whether the source holds every file its tree describes. A partial replica does not, by
    // definition, and copyAsset below leaves out what it cannot find rather than failing.
    const sourceIsPartial = media_file_database.isPartialDatabase(merkleTree.databaseMetadata);

    // What the copied count stood at when the destination tree was last saved part way through.
    // The save is meant to happen every hundred files, and it is reached once per leaf, while a
    // leaf that is already at the destination, or that a partial source does not hold, copies
    // nothing. So a count resting on a multiple of a hundred saved the whole tree again for every
    // one of those leaves, and at zero it did so from the first leaf of a pass that had copied
    // nothing yet. The sync's push had the same fault, measured on a Pixel 6 at a megabyte of
    // merkle tree written back per leaf.
    const copiedFilesAtLastSave: u64 = 0;

    //
    // What differs between the source's tree and the destination's, by name: the names to copy
    // across are the ones the destination lacks or holds under another hash, and the names to prune
    // are the ones only the destination has.
    //
    // By name, and not by the merkle diff, for the reason given at compareTrees: the diff matches
    // by hash, so of two files with the same content under different names it copied whichever it
    // visited second and pruned whichever it visited second, which is the wrong one half the time.
    // The sync's push had the same fault, measured at 243 files left behind on a phone.
    //
    const comparison = try compareTrees(allocator, merkleTree, destMerkleTree, null);
    const namesToCopy = try std.mem.concat(allocator, []const u8, &.{ comparison.onlyInA, comparison.modified });
    log.verbose(try std.fmt.allocPrint(allocator, "Found {d} files to copy, {d} files to prune", .{ namesToCopy.len, comparison.onlyInB.len }));

    // (Zig: the names pushed to result.missingFromSource are collected here.)
    var missingFromSource: std.ArrayList([]const u8) = .empty;

    var state: ReplicateFilesState = .{
        .allocator = allocator,
        .io = io,
        .merkleTree = merkleTree,
        .destMerkleTree = destMerkleTree,
        .destAssetStorage = destAssetStorage,
        .destMetadataStorage = destMetadataStorage,
        .sourceAssetStorage = sourceAssetStorage,
        .options = options,
        .progressCallback = progressCallback,
        .result = result,
        .missingFromSource = &missingFromSource,
        .sourceIsPartial = sourceIsPartial,
        .copiedFilesAtLastSave = copiedFilesAtLastSave,
    };

    if (namesToCopy.len > 0 or comparison.onlyInB.len > 0) {
        //
        // Process only the files that differ.
        //

        for (namesToCopy) |fileName| {
            try state.processFile(fileName);
        }

        //
        // Prune from the destination's tree the names only it has.
        //
        for (comparison.onlyInB) |fileName| {
            try deleteItem(allocator, destMerkleTree, fileName);
        }
        result.prunedFiles = comparison.onlyInB;

        //
        // Saves the dest database.
        //
        var saveOperation: retry_operations.SaveMerkleTreeOperation("() => saveMerkleTree(destMerkleTree, destMetadataStorage)") = .{ .allocator = allocator, .merkleTree = destMerkleTree, .storage = destMetadataStorage };
        try retry(io, &saveOperation, 3, 1_000, 2, 30_000, null);
    }
}

//
// Generator to extract leaf node names from MerkleNode arrays.
// (Zig: returns an iterator; call `next` for each name, like iterating the TypeScript generator.)
//
pub fn iterateLeaves(allocator: std.mem.Allocator, nodes: []const *MerkleNode) LeafNameIterator { //todo: move this to the merkle-tree package and test it.
    return .{ .allocator = allocator, .nodes = nodes, .nodeIndex = 0, .stack = .empty };
}

//
// The iterator returned by iterateLeaves. Yields the leaf names of each node in turn, in the same order as the
// TypeScript generator (the node itself when it is a leaf, otherwise the leaves of its left then right subtree).
//
pub const LeafNameIterator = struct {
    // Allocates the stack.
    allocator: std.mem.Allocator,

    // The nodes whose leaves are yielded.
    nodes: []const *MerkleNode,

    // The index of the next node of `nodes` to visit.
    nodeIndex: usize,

    // The nodes of the current subtree still to visit (the next one is at the end).
    stack: std.ArrayList(*MerkleNode),

    //
    // Returns the next leaf name, or null when every leaf has been yielded.
    // Throws "Leaf node has no name" when a leaf without a name is reached.
    //
    pub fn next(self: *LeafNameIterator) !?[]const u8 {
        while (true) {
            if (self.stack.items.len == 0) {
                if (self.nodeIndex >= self.nodes.len) {
                    return null;
                }
                try self.stack.append(self.allocator, self.nodes[self.nodeIndex]);
                self.nodeIndex += 1;
            }
            const node = self.stack.pop().?;
            if (node.left == null and node.right == null) {
                if (node.name == null or node.name.?.len == 0) {
                    return errors.throwError("Leaf node has no name", .{});
                }
                return node.name.?;
            }
            else {
                if (node.right) |right| {
                    try self.stack.append(self.allocator, right);
                }
                if (node.left) |left| {
                    try self.stack.append(self.allocator, left);
                }
            }
        }
    }
};

//
// Identifies a record by collection name and record ID, used as the yield type for database diff generators.
//
pub const ICollectionRecord = struct {
    // The name of the collection holding the record.
    collectionName: []const u8,

    // The ID of the record.
    recordId: []const u8,
};

//
// `() => loadShardMerkleTree(storage, collectionName, shardId)`.
//
fn LoadShardMerkleTreeOperation(comptime sourceText: []const u8) type {
    return struct {
        // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
        pub const source = sourceText;

        // Allocates the loaded tree.
        allocator: std.mem.Allocator,

        // The storage holding the database.
        storage: IStorage,

        // The collection of the shard.
        collectionName: []const u8,

        // The shard.
        shardId: []const u8,

        //
        // Loads the shard tree.
        //
        pub fn run(self: *@This(), io: std.Io) !?IMerkleTree {
            return loadShardMerkleTree(self.allocator, io, self.storage, self.collectionName, self.shardId);
        }
    };
}

//
// `() => loadCollectionMerkleTree(storage, collectionName)`.
//
fn LoadCollectionMerkleTreeOperation(comptime sourceText: []const u8) type {
    return struct {
        // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
        pub const source = sourceText;

        // Allocates the loaded tree.
        allocator: std.mem.Allocator,

        // The storage holding the database.
        storage: IStorage,

        // The collection.
        collectionName: []const u8,

        //
        // Loads the collection tree.
        //
        pub fn run(self: *@This(), io: std.Io) !?IMerkleTree {
            return loadCollectionMerkleTree(self.allocator, io, self.storage, self.collectionName);
        }
    };
}

//
// `() => loadDatabaseMerkleTree(storage, ".db/bson")`.
//
fn LoadDatabaseMerkleTreeOperation(comptime sourceText: []const u8) type {
    return struct {
        // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
        pub const source = sourceText;

        // Allocates the loaded tree.
        allocator: std.mem.Allocator,

        // The storage holding the database.
        storage: IStorage,

        //
        // Loads the database tree.
        //
        pub fn run(self: *@This(), io: std.Io) !?IMerkleTree {
            return loadDatabaseMerkleTree(self.allocator, io, self.storage, ".db/bson");
        }
    };
}

//
// Yields record IDs from tree1 that differ from tree2.
// tree1 is the primary tree (source for pass 1, dest for pass 2).
// tree2 is the comparison tree (dest for pass 1, source for pass 2).
// tree1Storage and tree2Storage are the storage locations for tree1 and tree2 respectively.
// (Zig: loads the trees and returns an iterator over the records; call `next` for each record.)
//
pub fn iterateShardDifferences(
    allocator: std.mem.Allocator,
    io: std.Io,
    collectionName: []const u8,
    shardId: []const u8,
    tree1Storage: IStorage,
    tree2Storage: IStorage,
) !ShardDifferenceIterator {
    var tree1Operation: LoadShardMerkleTreeOperation("() => loadShardMerkleTree(tree1Storage, collectionName, shardId)") = .{ .allocator = allocator, .storage = tree1Storage, .collectionName = collectionName, .shardId = shardId };
    const tree1 = try retry(io, &tree1Operation, 3, 1_000, 2, 30_000, null);
    if (tree1 == null or tree1.?.merkle == null) {
        // If primary tree doesn't exist, no records to process.
        return .{ .collectionName = collectionName, .recordIds = iterateLeaves(allocator, &.{}) };
    }

    var tree2Operation: LoadShardMerkleTreeOperation("() => loadShardMerkleTree(tree2Storage, collectionName, shardId)") = .{ .allocator = allocator, .storage = tree2Storage, .collectionName = collectionName, .shardId = shardId };
    const tree2 = try retry(io, &tree2Operation, 3, 1_000, 2, 30_000, null);
    if (tree2 == null or tree2.?.merkle == null) {
        // If comparison tree doesn't exist, all records in primary tree need to be processed
        const nodes = try allocator.alloc(*MerkleNode, 1);
        nodes[0] = tree1.?.merkle.?;
        return .{ .collectionName = collectionName, .recordIds = iterateLeaves(allocator, nodes) };
    }

    // Find records in tree1 that differ from tree2
    const differingNodes = try findDifferingNodes(allocator, tree1.?.merkle.?, tree2.?.merkle.?);
    return .{ .collectionName = collectionName, .recordIds = iterateLeaves(allocator, differingNodes) };
}

//
// The iterator returned by iterateShardDifferences.
//
pub const ShardDifferenceIterator = struct {
    // The collection of the shard.
    collectionName: []const u8,

    // The IDs of the records that differ.
    recordIds: LeafNameIterator,

    //
    // Returns the next differing record, or null when there are no more.
    //
    pub fn next(self: *ShardDifferenceIterator) !?ICollectionRecord {
        const recordId = try self.recordIds.next() orelse {
            return null;
        };
        return .{
            .collectionName = self.collectionName,
            .recordId = recordId,
        };
    }
};

//
// Yields record IDs from tree1 collection that differ from tree2 collection.
// tree1 is the primary tree (source for pass 1, dest for pass 2).
// tree2 is the comparison tree (dest for pass 1, source for pass 2).
// tree1Storage and tree2Storage are the storage locations for tree1 and tree2 respectively.
// (Zig: loads the collection trees and returns an iterator; the shard trees are loaded as the iterator reaches them.)
//
pub fn iterateCollectionDifferences(
    allocator: std.mem.Allocator,
    io: std.Io,
    collectionName: []const u8,
    tree1Storage: IStorage,
    tree2Storage: IStorage,
) !CollectionDifferenceIterator {
    var iterator: CollectionDifferenceIterator = .{
        .allocator = allocator,
        .io = io,
        .collectionName = collectionName,
        .tree1Storage = tree1Storage,
        .tree2Storage = tree2Storage,
        .shardIds = iterateLeaves(allocator, &.{}),
        .current = null,
    };

    var tree1Operation: LoadCollectionMerkleTreeOperation("() => loadCollectionMerkleTree(tree1Storage, collectionName)") = .{ .allocator = allocator, .storage = tree1Storage, .collectionName = collectionName };
    const tree1 = try retry(io, &tree1Operation, 3, 1_000, 2, 30_000, null);
    if (tree1 == null or tree1.?.merkle == null) {
        // If primary collection tree doesn't exist, no records to process.
        return iterator;
    }

    var tree2Operation: LoadCollectionMerkleTreeOperation("() => loadCollectionMerkleTree(tree2Storage, collectionName)") = .{ .allocator = allocator, .storage = tree2Storage, .collectionName = collectionName };
    const tree2 = try retry(io, &tree2Operation, 3, 1_000, 2, 30_000, null);
    if (tree2 == null or tree2.?.merkle == null) {
        // If comparison collection tree doesn't exist, process all shards in primary tree
        const nodes = try allocator.alloc(*MerkleNode, 1);
        nodes[0] = tree1.?.merkle.?;
        iterator.shardIds = iterateLeaves(allocator, nodes);
        return iterator;
    }

    // Find shards in tree1 that differ from tree2
    const differingShards = try findDifferingNodes(allocator, tree1.?.merkle.?, tree2.?.merkle.?);
    iterator.shardIds = iterateLeaves(allocator, differingShards);
    return iterator;
}

//
// The iterator returned by iterateCollectionDifferences (the `yield*` of each shard's differences).
//
pub const CollectionDifferenceIterator = struct {
    // Allocates the shard iterators.
    allocator: std.mem.Allocator,

    // Used to load the shard trees.
    io: std.Io,

    // The collection being compared.
    collectionName: []const u8,

    // The storage of the primary tree.
    tree1Storage: IStorage,

    // The storage of the comparison tree.
    tree2Storage: IStorage,

    // The IDs of the shards that differ.
    shardIds: LeafNameIterator,

    // The differences of the shard being iterated.
    current: ?ShardDifferenceIterator,

    //
    // Returns the next differing record, or null when there are no more.
    //
    pub fn next(self: *CollectionDifferenceIterator) !?ICollectionRecord {
        while (true) {
            if (self.current) |*current| {
                if (try current.next()) |record| {
                    return record;
                }
                self.current = null;
            }
            const shardId = try self.shardIds.next() orelse {
                return null;
            };
            self.current = try iterateShardDifferences(self.allocator, self.io, self.collectionName, shardId, self.tree1Storage, self.tree2Storage);
        }
    }
};

//
// Yields record IDs from tree1 database that differ from tree2 database.
// tree1 is the primary tree (source for pass 1, dest for pass 2).
// tree2 is the comparison tree (dest for pass 1, source for pass 2).
// tree1Storage and tree2Storage are the storage locations for tree1 and tree2 respectively.
// (Zig: loads the database trees and returns an iterator; the collection and shard trees are loaded as the iterator
// reaches them.)
//
pub fn iterateDatabaseDifferences(allocator: std.mem.Allocator, io: std.Io, tree1Storage: IStorage, tree2Storage: IStorage) !DatabaseDifferenceIterator {
    var iterator: DatabaseDifferenceIterator = .{
        .allocator = allocator,
        .io = io,
        .tree1Storage = tree1Storage,
        .tree2Storage = tree2Storage,
        .collectionNames = iterateLeaves(allocator, &.{}),
        .current = null,
    };

    var tree1Operation: LoadDatabaseMerkleTreeOperation("() => loadDatabaseMerkleTree(tree1Storage, \".db/bson\")") = .{ .allocator = allocator, .storage = tree1Storage };
    const tree1 = try retry(io, &tree1Operation, 3, 1_000, 2, 30_000, null);
    if (tree1 == null or tree1.?.merkle == null) {
        // If primary database tree doesn't exist, no records to process.
        return iterator;
    }

    var tree2Operation: LoadDatabaseMerkleTreeOperation("() => loadDatabaseMerkleTree(tree2Storage, \".db/bson\")") = .{ .allocator = allocator, .storage = tree2Storage };
    const tree2 = try retry(io, &tree2Operation, 3, 1_000, 2, 30_000, null);
    if (tree2 == null or tree2.?.merkle == null) {
        // If comparison database tree doesn't exist, process all collections in primary tree
        const nodes = try allocator.alloc(*MerkleNode, 1);
        nodes[0] = tree1.?.merkle.?;
        iterator.collectionNames = iterateLeaves(allocator, nodes);
        return iterator;
    }

    // Find collections in tree1 that differ from tree2
    const differingCollections = try findDifferingNodes(allocator, tree1.?.merkle.?, tree2.?.merkle.?);
    iterator.collectionNames = iterateLeaves(allocator, differingCollections);
    return iterator;
}

//
// The iterator returned by iterateDatabaseDifferences (the `yield*` of each collection's differences).
//
pub const DatabaseDifferenceIterator = struct {
    // Allocates the collection iterators.
    allocator: std.mem.Allocator,

    // Used to load the trees.
    io: std.Io,

    // The storage of the primary tree.
    tree1Storage: IStorage,

    // The storage of the comparison tree.
    tree2Storage: IStorage,

    // The names of the collections that differ.
    collectionNames: LeafNameIterator,

    // The differences of the collection being iterated.
    current: ?CollectionDifferenceIterator,

    //
    // Returns the next differing record, or null when there are no more.
    //
    pub fn next(self: *DatabaseDifferenceIterator) !?ICollectionRecord {
        while (true) {
            if (self.current) |*current| {
                if (try current.next()) |record| {
                    return record;
                }
                self.current = null;
            }
            const collectionName = try self.collectionNames.next() orelse {
                return null;
            };
            self.current = try iterateCollectionDifferences(self.allocator, self.io, collectionName, self.tree1Storage, self.tree2Storage);
        }
    }
};

//
// A set of record IDs in insertion order (TypeScript: Set<string>).
//
const RecordIdSet = std.StringArrayHashMapUnmanaged(void);

//
// Record ID sets by collection name in insertion order (TypeScript: Map<string, Set<string>>).
//
const RecordIdSetsByCollection = std.StringArrayHashMapUnmanaged(RecordIdSet);

//
// `() => destColl.setInternalRecord(sourceRecord)`.
//
const SetInternalRecordOperation = struct {
    // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
    pub const source = "() => destColl.setInternalRecord(sourceRecord)";

    // The destination collection.
    collection: *IBsonCollection,

    // The record to set.
    record: IInternalRecord,

    //
    // Sets the record.
    //
    pub fn run(self: *SetInternalRecordOperation, io: std.Io) !void {
        return self.collection.setInternalRecord(io, self.record);
    }
};

//
// `() => destColl.deleteOne(recordId)`.
//
const DeleteOneOperation = struct {
    // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
    pub const source = "() => destColl.deleteOne(recordId)";

    // The destination collection.
    collection: *IBsonCollection,

    // The record to delete.
    recordId: []const u8,

    //
    // Deletes the record.
    //
    pub fn run(self: *DeleteOneOperation, io: std.Io) !bool {
        return self.collection.deleteOne(io, self.recordId);
    }
};

//
// Replicates BSON database records from source to destination.
// Builds a map of modified records per collection, then processes by shard: load source and dest shards,
// apply updates to dest shard's records map, update sort indexes, save shard once, update merkle trees.
//
fn replicateBsonDatabase(
    allocator: std.mem.Allocator,
    io: std.Io,
    sourceBsonDatabase: *BsonDatabase,
    destBsonDatabase: *BsonDatabase,
    sourceAssetStorage: IStorage,
    destAssetStorage: IStorage,
    progressCallback: ?ProgressCallback,
    isCancelled: ?IsCancelledCallback,
    result: *IReplicationResult,
) !void {

    //
    // Replicate BSON database records using merkle tree differences.
    // This walks the tree of trees (database -> collections -> shards -> records)
    // to efficiently identify only the records that need to be updated.
    //
    // Use v6 layout: BSON database merkle trees are stored under .db/bson
    // 1. Build map of modified records per collection: toCopy (source→dest) and toDelete (dest→source)
    var toCopyByCollection: RecordIdSetsByCollection = .empty;
    var toDeleteByCollection: RecordIdSetsByCollection = .empty;

    var copyDifferences = try iterateDatabaseDifferences(allocator, io, sourceAssetStorage, destAssetStorage);
    while (try copyDifferences.next()) |diff| {
        const entry = try toCopyByCollection.getOrPut(allocator, diff.collectionName);
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
        }
        try entry.value_ptr.put(allocator, diff.recordId, {});
    }

    var deleteDifferences = try iterateDatabaseDifferences(allocator, io, destAssetStorage, sourceAssetStorage);
    while (try deleteDifferences.next()) |diff| {
        const entry = try toDeleteByCollection.getOrPut(allocator, diff.collectionName);
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
        }
        try entry.value_ptr.put(allocator, diff.recordId, {});
    }

    var collectionNames: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (toCopyByCollection.keys()) |collectionName| {
        try collectionNames.put(allocator, collectionName, {});
    }
    for (toDeleteByCollection.keys()) |collectionName| {
        try collectionNames.put(allocator, collectionName, {});
    }

    for (collectionNames.keys()) |collectionName| {
        const sourceColl = try sourceBsonDatabase.collection(collectionName);
        const destColl = try destBsonDatabase.collection(collectionName);

        const toCopy = toCopyByCollection.get(collectionName) orelse RecordIdSet.empty;
        const toDelete = toDeleteByCollection.get(collectionName) orelse RecordIdSet.empty;

        for (toCopy.keys()) |recordId| {
            try throwIfCancelled(isCancelled);
            const shardId = try sourceColl.getShardId(recordId);
            const sourceShard = try sourceColl.shard(shardId);
            const sourceRecord = try sourceShard.record(io, recordId) orelse {
                continue;
            };
            var setOperation: SetInternalRecordOperation = .{ .collection = destColl, .record = sourceRecord };
            try retry(io, &setOperation, 3, 1_000, 2, 30_000, null); //todo: maybe database retries should below the api.
            result.copiedRecords += 1;
        }

        for (toDelete.keys()) |recordId| {
            try throwIfCancelled(isCancelled);
            var deleteOperation: DeleteOneOperation = .{ .collection = destColl, .recordId = recordId };
            _ = try retry(io, &deleteOperation, 3, 1_000, 2, 30_000, null);
            result.copiedRecords += 1;
        }

        reportProgress(progressCallback, "Copied {d} files, {d} records", .{ result.copiedFiles, result.copiedRecords });
    }

    try destBsonDatabase.commit(io);
}

//
// Copies a single file from source to dest storage if it exists in source.
//
fn copyFileIfExists(allocator: std.mem.Allocator, io: std.Io, fileName: []const u8, sourceStorage: IStorage, destStorage: IStorage) !void {
    if (!try sourceStorage.fileExists(allocator, io, fileName)) {
        return;
    }
    var infoOperation: retry_operations.InfoOperation("() => sourceStorage.info(fileName)") = .{ .allocator = allocator, .storage = sourceStorage, .fileName = fileName };
    const info = try retry(io, &infoOperation, 3, 1_000, 2, 30_000, null) orelse {
        return;
    };
    var copyOperation: retry_operations.CopyStreamOperation("async () => {\n    const readStream = await sourceStorage.readStream(fileName);\n    await destStorage.writeStream(fileName, info.contentType, readStream);\n  }") = .{
        .allocator = allocator,
        .sourceStorage = sourceStorage,
        .destStorage = destStorage,
        .fileName = fileName,
        .contentType = info.contentType,
    };
    try retry(io, &copyOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, null);
}

//
// Copies all BSON database merkle tree files (.dat) from source to dest storage.
// Skips shard data files (no extension): only the merkle trees are needed for a partial replica.
//
fn copyBsonMerkleTrees(allocator: std.mem.Allocator, io: std.Io, sourceStorage: IStorage, destStorage: IStorage) !void {
    var walker = try walkDirectory(allocator, io, sourceStorage, ".db/bson", &.{});
    while (try walker.next()) |orderedFile| {
        if (std.mem.endsWith(u8, orderedFile.fileName, ".dat")) {
            try copyFileIfExists(allocator, io, orderedFile.fileName, sourceStorage, destStorage);
        }
    }
}

//
// Replicates the media file database to another storage.
// (Zig: the TypeScript optional parameters are passed as null.)
//
pub fn replicate(
    allocator: std.mem.Allocator,
    io: std.Io,
    sourcePath: []const u8,
    sourceAssetStorage: IStorage,
    sourceBsonDatabase: *BsonDatabase,
    sourceUuidGenerator: IUuidGenerator,
    sourceTimestampProvider: ITimestampProvider,
    destAssetStorage: IStorage,
    destRawAssetStorage: IStorage,
    options: ?IReplicateOptions,
    progressCallback: ?ProgressCallback,
) !IReplicationResult {

    var loadSourceOperation: retry_operations.LoadMerkleTreeOperation("() => loadMerkleTree(sourceAssetStorage)") = .{ .allocator = allocator, .storage = sourceAssetStorage };
    var merkleTree = try retry(io, &loadSourceOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwError("Failed to load merkle tree", .{});
    };

    const filesImported = media_file_database.getFilesImported(merkleTree.databaseMetadata);

    var result: IReplicationResult = .{
        .filesImported = filesImported,
        .copiedFiles = 0,
        .copiedRecords = 0,
        .prunedFiles = &.{},
        .missingFromSource = &.{},
    };

    //
    // Create or load the destination MediaFileDatabase to ensure sort indexes are loaded/created.
    // This has to be created before files.dat is saved.
    //
    const destDb = try createMediaFileDatabase(
        allocator,
        destAssetStorage,
        sourceUuidGenerator,
        sourceTimestampProvider,
    );

    var existsOperation: retry_operations.MerkleTreeExistsOperation("() => merkleTreeExists(destAssetStorage)") = .{ .allocator = allocator, .storage = destAssetStorage };
    const treeExists = try retry(io, &existsOperation, 3, 1_000, 2, 30_000, null);
    if (treeExists) {
        log.verbose("Loading existing destination database...");
        try loadSortIndexes(allocator, destDb.assetStorage, destDb.metadataCollection);
    }
    else {
        log.verbose("Creating new destination database...");
        //
        // This is need because it will create the sort indexes and other things.
        //
        try createDatabase(allocator, io, destAssetStorage, destRawAssetStorage, sourceUuidGenerator, destDb.metadataCollection, merkleTree.id);
    }

    //
    // Load the destination database that might have been just created.
    //
    var loadDestOperation: retry_operations.LoadMerkleTreeOperation("() => loadMerkleTree(destAssetStorage)") = .{ .allocator = allocator, .storage = destAssetStorage };
    var destMerkleTree = try retry(io, &loadDestOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwFatalError("Failed to load merkle tree from destination database.", .{});
    };

    const force = options != null and options.?.force;
    if (!force and !std.mem.eql(u8, destMerkleTree.id, merkleTree.id)) {
        return errors.throwFatalError(
            "You are trying to replicate to a database that has a different ID than the source database.\n" ++
                "Source database ID: {s}\n" ++
                "Destination database ID: {s}\n" ++
                "The destination database is not related to the source database.\n" ++
                "Use the --force flag to proceed anyway.",
            .{ merkleTree.id, destMerkleTree.id },
        );
    }

    //
    // If force is used and IDs don't match, update destination files merkle tree UUID to match source.
    //
    if (force and !std.mem.eql(u8, destMerkleTree.id, merkleTree.id)) {
        destMerkleTree.id = merkleTree.id;
    }

    if (options != null and options.?.partial) {
        //
        // Partial mode: directly copy only the known small set of files rather than
        // traversing the entire merkle tree (which could be 100k+ entries).
        //
        try copyFileIfExists(allocator, io, "README.md", sourceAssetStorage, destAssetStorage);
        try copyFileIfExists(allocator, io, ".db/files.dat", sourceAssetStorage, destAssetStorage);
        try copyBsonMerkleTrees(allocator, io, sourceAssetStorage, destAssetStorage);

        //
        // Reload the dest merkle tree (now a copy of the source tree) and mark it partial.
        //
        var reloadOperation: retry_operations.LoadMerkleTreeOperation("() => loadMerkleTree(destAssetStorage)") = .{ .allocator = allocator, .storage = destAssetStorage };
        destMerkleTree = try retry(io, &reloadOperation, 3, 1_000, 2, 30_000, null) orelse {
            return errors.throwFatalError("Failed to load merkle tree from destination database after partial copy.", .{});
        };
        if (merkleTree.databaseMetadata) |sourceMetadata| {
            var partialMetadata = try media_file_database.copyDatabaseMetadata(allocator, sourceMetadata);
            try partialMetadata.put(allocator, "isPartial", .{ .boolean = true });
            destMerkleTree.databaseMetadata = partialMetadata;
        }
        else {
            var partialMetadata = try media_file_database.emptyDatabaseMetadata(allocator);
            try partialMetadata.put(allocator, "isPartial", .{ .boolean = true });
            destMerkleTree.databaseMetadata = partialMetadata;
        }
        var saveOperation: retry_operations.SaveMerkleTreeOperation("() => saveMerkleTree(destMerkleTree, destAssetStorage)") = .{ .allocator = allocator, .merkleTree = &destMerkleTree, .storage = destAssetStorage };
        try retry(io, &saveOperation, 3, 1_000, 2, 30_000, null);
    }
    else {
        //
        // Full mode: copy database metadata from source to destination, then replicate all files.
        //
        // Without the partial flag, whatever the source's says. A full replica is full by
        // definition: it holds everything its source could give it, and full is what was asked for
        // by name. Carrying the flag over from a partial source made a full copy of a phone's
        // replica, taken to rebuild a lost origin, come out marked partial, and every sync then
        // refused the originals and display versions pushed at it, for ever: measured on a Pixel 6,
        // the phone imported and pushed 1,937 photos and the origin ended up holding the 250
        // originals it started with, while its thumbnails went from 8,481 to 10,199.
        //
        if (merkleTree.databaseMetadata) |sourceMetadata| {
            var fullMetadata = try media_file_database.copyDatabaseMetadata(allocator, sourceMetadata);
            try fullMetadata.put(allocator, "isPartial", .{ .boolean = false });
            destMerkleTree.databaseMetadata = fullMetadata;
        }
        else {
            destMerkleTree.databaseMetadata = try media_file_database.emptyDatabaseMetadata(allocator);
        }

        try replicateFiles(
            allocator,
            io,
            &merkleTree,
            &destMerkleTree,
            destAssetStorage,
            destAssetStorage,
            sourceAssetStorage,
            options,
            progressCallback,
            &result,
        );

        try replicateBsonDatabase(
            allocator,
            io,
            sourceBsonDatabase,
            destDb.bsonDatabase,
            sourceAssetStorage,
            destAssetStorage,
            progressCallback,
            if (options) |replicateOptions| replicateOptions.isCancelled else null,
            &result,
        );

    }

    //
    // Generate or update config.json in the destination database (configuration only).
    //
    try updateDatabaseConfig(allocator, io, destRawAssetStorage, .{
        .origin = sourcePath,
    });

    //
    // Record the replication time and refresh the content hash in the destination state file.
    //
    try stampDatabaseStateLocked(allocator, io, destAssetStorage, destRawAssetStorage, "replicate", .{
        .lastReplicatedAt = try sourceTimestampProvider.dateNow(io).toISOString(allocator),
    });

    return result;
}
