const std = @import("std");
const utils = @import("utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const storage_zig = @import("storage-zig");
const serialization_zig = @import("serialization-zig");
const bdb = @import("bdb-zig");
const media_file_database = @import("media-file-database.zig");
const hash_module = @import("hash.zig");
const tree = @import("tree.zig");
const retry_operations = @import("retry-operations.zig");
const errors = utils.errors;
const log = &utils.log.log;
const retry = utils.retry.retry;
const ProgressCallback = media_file_database.ProgressCallback;
const getDatabaseSummary = media_file_database.getDatabaseSummary;
const computeHash = hash_module.computeHash;
const computeAssetHash = hash_module.computeAssetHash;
const IMerkleTree = merkle_tree_zig.merkle_tree.IMerkleTree;
const SortNode = merkle_tree_zig.merkle_tree.SortNode;
const traverseTreeAsync = merkle_tree_zig.traverse.traverseTreeAsync;
const IStorage = storage_zig.storage.IStorage;
const BsonDatabase = bdb.database.BsonDatabase;
const IBsonCollection = bdb.collection.IBsonCollection;
const BsonDocument = serialization_zig.bson.BsonDocument;
const BsonValue = serialization_zig.bson.BsonValue;
const js_date = serialization_zig.js_date;

//
// Options for repairing the media file database.
//
pub const IRepairOptions = struct {
    //
    // The source database path to repair from.
    //
    source: []const u8,

    //
    // The source key file.
    //
    sourceKey: ?[]const u8 = null,

    //
    // Enables full verification where all files are re-hashed.
    //
    full: ?bool = null,
};

//
// Result of the repair process.
//
pub const IRepairResult = struct {
    //
    // The total number of files imported into the database.
    //
    totalImports: u64,

    //
    // The total number of files verified (including thumbnails, display, BSON, etc.).
    //
    totalFiles: u64,

    //
    // The total database size.
    //
    totalSize: u64,

    //
    // The number of files that were unmodified.
    //
    numUnmodified: u64,

    //
    // The list of files that were modified.
    //
    modified: []const []const u8,

    //
    // The list of new files that were added to the database.
    //
    new: []const []const u8,

    //
    // The list of files that were removed from the database.
    //
    removed: []const []const u8,

    //
    // The list of files that were successfully repaired.
    //
    repaired: []const []const u8,

    //
    // The list of files that could not be repaired.
    //
    unrepaired: []const []const u8,

    //
    // The number of files processed.
    //
    filesProcessed: u64,

    //
    // The number of nodes processed in the merkle tree.
    //
    nodesProcessed: u64,

    //
    // Asset paths whose database record was repaired (wrong or missing hash, or missing record).
    //
    recordsRepaired: []const []const u8,
};

//
// Calls the progress callback with a formatted message, when there is one.
//
fn reportProgress(progressCallback: ?ProgressCallback, comptime format: []const u8, args: anytype) void {
    const callback = progressCallback orelse {
        return;
    };
    var buffer: [1024]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, format, args) catch buffer[0..];
    callback.call(message);
}

//
// The state of a repair (TypeScript: the variables the repairFile and checkFile closures capture).
//
const RepairState = struct {
    // Allocates the lists and messages.
    allocator: std.mem.Allocator,

    // The io of the repair.
    io: std.Io,

    // The storage of the database being repaired.
    assetStorage: IStorage,

    // The storage of the database files are restored from.
    sourceAssetStorage: IStorage,

    // The metadata collection of the database being repaired.
    metadataCollection: *IBsonCollection,

    // The repair options.
    options: IRepairOptions,

    // Reports progress.
    progressCallback: ?ProgressCallback,

    // The total number of files in the database's summary.
    summaryTotalFiles: u64,

    // The counts of the result.
    result: IRepairResult,

    // result.modified.
    modified: std.ArrayList([]const u8) = .empty,

    // result.removed.
    removed: std.ArrayList([]const u8) = .empty,

    // result.repaired.
    repaired: std.ArrayList([]const u8) = .empty,

    // result.unrepaired.
    unrepaired: std.ArrayList([]const u8) = .empty,

    // result.recordsRepaired.
    recordsRepaired: std.ArrayList([]const u8) = .empty,

    // The hash of each database record by id.
    recordIdToHash: std.StringHashMapUnmanaged([]const u8) = .empty,

    //
    // Repairs a single file.
    //
    fn repairFile(self: *RepairState, fileName: []const u8, expectedHash: []const u8) bool {
        return self.tryRepairFile(fileName, expectedHash) catch |err| {
            log.@"error"(std.fmt.allocPrint(self.allocator, "Error repairing file {s}: {s}", .{ fileName, errors.errorMessage(err) }) catch "Error repairing file");
            return false;
        };
    }

    //
    // The body of repairFile's try block.
    //
    fn tryRepairFile(self: *RepairState, fileName: []const u8, expectedHash: []const u8) !bool {
        const allocator = self.allocator;
        const io = self.io;

        // Check if file exists in source
        if (!try self.sourceAssetStorage.fileExists(allocator, io, fileName)) {
            log.warn(try std.fmt.allocPrint(allocator, "Source file not found for repair: {s}", .{fileName}));
            return false;
        }

        // Get source file info
        const sourceFileInfo = try self.sourceAssetStorage.info(allocator, io, fileName) orelse {
            log.warn(try std.fmt.allocPrint(allocator, "Source file info not available: {s}", .{fileName}));
            return false;
        };

        // Verify source file hash matches expected
        const hashStream = try self.sourceAssetStorage.readStream(allocator, io, fileName);
        const sourceHash = computeHash(hashStream.reader());
        hashStream.destroy(io);
        if (!std.mem.eql(u8, &(try sourceHash), expectedHash)) {
            log.warn(try std.fmt.allocPrint(allocator, "Source file hash mismatch for: {s}", .{fileName}));
            return false;
        }

        // Copy file from source to target
        const readStream = try self.sourceAssetStorage.readStream(allocator, io, fileName);
        defer readStream.destroy(io);

        //
        // A write lock isn't needed here unless we think multiple repairs might try to operate on the tree at the same time.
        // TODO: Maybe a "repair lock" will be in order at some point in the future.
        //
        try self.assetStorage.writeStream(allocator, io, fileName, sourceFileInfo.contentType, readStream.reader(), null);

        // Verify copied file
        const copiedFileInfo = try self.assetStorage.info(allocator, io, fileName) orelse {
            log.warn(try std.fmt.allocPrint(allocator, "Failed to get info for repaired file: {s}", .{fileName}));
            return false;
        };

        const copiedStream = try self.assetStorage.readStream(allocator, io, fileName);
        defer copiedStream.destroy(io);
        const copiedHash = try computeAssetHash(allocator, copiedStream.reader(), .{
            .contentType = copiedFileInfo.contentType,
            .length = copiedFileInfo.length,
            .lastModified = copiedFileInfo.lastModified,
        });
        if (!std.mem.eql(u8, copiedHash.hash, expectedHash)) {
            log.warn(try std.fmt.allocPrint(allocator, "Repaired file hash mismatch: {s}", .{fileName}));
            return false;
        }

        return true;
    }

    //
    // Check nodes in the merkle to find corrupted/missing files.
    //
    fn checkFile(self: *RepairState, node: *SortNode) !void {
        const allocator = self.allocator;
        const io = self.io;

        self.result.filesProcessed += 1;

        reportProgress(self.progressCallback, "Checking file {d} of {d}", .{ self.result.filesProcessed, self.summaryTotalFiles });

        const fileName = node.name.?;
        const fileInfo = try self.assetStorage.info(allocator, io, fileName) orelse {
            // File is missing - try to repair.
            reportProgress(self.progressCallback, "Repairing missing file: {s}", .{fileName});

            const repaired = self.repairFile(fileName, node.contentHash.?);
            if (repaired) {
                try self.repaired.append(allocator, fileName);
            }
            else {
                try self.removed.append(allocator, fileName);
                try self.unrepaired.append(allocator, fileName);
            }
            return;
        };

        // Check if file is corrupted.
        if (node.size != fileInfo.length or node.lastModified.? != fileInfo.lastModified or (self.options.full orelse false)) {

            // Verify the actual hash.
            const stream = try self.assetStorage.readStream(allocator, io, fileName);
            const freshHash = computeAssetHash(allocator, stream.reader(), .{
                .contentType = fileInfo.contentType,
                .length = fileInfo.length,
                .lastModified = fileInfo.lastModified,
            });
            stream.destroy(io);
            if (!std.mem.eql(u8, (try freshHash).hash, node.contentHash.?)) {
                // File is corrupted - try to repair.
                reportProgress(self.progressCallback, "Repairing corrupted file: {s}", .{fileName});

                const repaired = self.repairFile(fileName, node.contentHash.?);
                if (repaired) {
                    try self.repaired.append(allocator, fileName);
                }
                else {
                    try self.modified.append(allocator, fileName);
                    try self.unrepaired.append(allocator, fileName);
                }
            }
            else {
                self.result.numUnmodified += 1;
            }
        }
        else {
            self.result.numUnmodified += 1;
        }
    }

    //
    // Checks a node and its asset's database record (TypeScript: the arrow function passed to traverseTreeAsync).
    //
    fn visitNode(self: *RepairState, node: *SortNode) anyerror!bool {
        const allocator = self.allocator;
        const io = self.io;
        self.result.nodesProcessed += 1;

        if (node.name) |nodeName| {
            try self.checkFile(node);

            //
            // Check asset nodes have a database record with the correct id and hash; repair if not.
            //
            if (std.mem.startsWith(u8, nodeName, "asset/") and node.contentHash != null) {
                const assetId = nodeName["asset/".len..];
                const expectedHashHex = try std.fmt.allocPrint(allocator, "{x}", .{node.contentHash.?});
                const dbHash = self.recordIdToHash.get(assetId);
                if (dbHash == null) {
                    //
                    // Record missing: synthesize a minimal database record.
                    //
                    reportProgress(self.progressCallback, "Repairing missing database record: {s}", .{nodeName});
                    var now: std.Io.Writer.Allocating = .init(allocator);
                    try js_date.writeIsoString(&now.writer, std.Io.Clock.real.now(io).toMilliseconds());
                    const color = try allocator.alloc(BsonValue, 3);
                    @memset(color, .{ .number = 0 });
                    var minimalRecord: BsonDocument = .empty;
                    try minimalRecord.put(allocator, "_id", .{ .string = assetId });
                    try minimalRecord.put(allocator, "origFileName", .{ .string = assetId });
                    try minimalRecord.put(allocator, "contentType", .{ .string = "application/octet-stream" });
                    try minimalRecord.put(allocator, "width", .{ .number = 0 });
                    try minimalRecord.put(allocator, "height", .{ .number = 0 });
                    try minimalRecord.put(allocator, "hash", .{ .string = expectedHashHex });
                    try minimalRecord.put(allocator, "fileDate", .{ .string = now.written() });
                    try minimalRecord.put(allocator, "uploadDate", .{ .string = now.written() });
                    try minimalRecord.put(allocator, "micro", .{ .string = "" });
                    try minimalRecord.put(allocator, "color", .{ .array = color });
                    var insertOperation: InsertOneOperation = .{ .metadataCollection = self.metadataCollection, .record = &minimalRecord };
                    try retry(io, &insertOperation, 3, 1_000, 2, 30_000, null);
                    try self.recordsRepaired.append(allocator, nodeName);
                    try self.recordIdToHash.put(allocator, assetId, expectedHashHex);
                }
                else if (!std.mem.eql(u8, dbHash.?, expectedHashHex)) {
                    //
                    // Hash wrong: update the record with the hash from the merkle tree.
                    //
                    reportProgress(self.progressCallback, "Repairing database record hash: {s}", .{nodeName});
                    var updates: BsonDocument = .empty;
                    try updates.put(allocator, "hash", .{ .string = expectedHashHex });
                    var updateOperation: UpdateOneOperation = .{ .metadataCollection = self.metadataCollection, .id = assetId, .updates = updates };
                    const updated = try retry(io, &updateOperation, 3, 1_000, 2, 30_000, null);
                    if (updated) {
                        try self.recordsRepaired.append(allocator, nodeName);
                        try self.recordIdToHash.put(allocator, assetId, expectedHashHex);
                    }
                }
            }
        }

        return true;
    }
};

//
// `() => metadataCollection.insertOne(minimalRecord)`.
//
const InsertOneOperation = struct {
    // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
    pub const source = "() => metadataCollection.insertOne(minimalRecord)";

    // The collection to insert into.
    metadataCollection: *IBsonCollection,

    // The record to insert.
    record: *BsonDocument,

    //
    // Inserts the record.
    //
    pub fn run(self: *InsertOneOperation, io: std.Io) !void {
        return self.metadataCollection.insertOne(io, self.record, null);
    }
};

//
// `() => metadataCollection.updateOne(assetId, { hash: expectedHashHex })`.
//
const UpdateOneOperation = struct {
    // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
    pub const source = "() => metadataCollection.updateOne(assetId, { hash: expectedHashHex })";

    // The collection to update.
    metadataCollection: *IBsonCollection,

    // The id of the record to update.
    id: []const u8,

    // The fields to update.
    updates: BsonDocument,

    //
    // Updates the record.
    //
    pub fn run(self: *UpdateOneOperation, io: std.Io) !bool {
        return self.metadataCollection.updateOne(io, self.id, self.updates, .{});
    }
};

//
// Repairs the media file database by restoring corrupted or missing files from a source database.
// Also checks that each asset in the merkle tree has a database record with the correct id and hash,
// and repairs wrong or missing hashes and synthesizes missing records.
// (Zig: the TypeScript optional progressCallback is passed as null.)
//
pub fn repair(
    allocator: std.mem.Allocator,
    io: std.Io,
    assetStorage: IStorage,
    rawStorage: IStorage,
    sourceAssetStorage: IStorage,
    bsonDatabase: *BsonDatabase,
    metadataCollection: *IBsonCollection,
    options: IRepairOptions,
    progressCallback: ?ProgressCallback,
) !IRepairResult {
    const summary = try getDatabaseSummary(allocator, io, assetStorage);
    var state: RepairState = .{
        .allocator = allocator,
        .io = io,
        .assetStorage = assetStorage,
        .sourceAssetStorage = sourceAssetStorage,
        .metadataCollection = metadataCollection,
        .options = options,
        .progressCallback = progressCallback,
        .summaryTotalFiles = summary.totalFiles,
        .result = .{
            .totalImports = summary.totalImports,
            .totalFiles = summary.totalFiles,
            .totalSize = summary.totalSize,
            .numUnmodified = 0,
            .modified = &.{},
            .new = &.{},
            .removed = &.{},
            .repaired = &.{},
            .unrepaired = &.{},
            .filesProcessed = 0,
            .nodesProcessed = 0,
            .recordsRepaired = &.{},
        },
    };

    reportProgress(progressCallback, "Checking for missing or corrupt files in merkle tree...", .{});

    var loadOperation: retry_operations.LoadMerkleTreeOperation("() => loadMerkleTree(assetStorage)") = .{ .allocator = allocator, .storage = assetStorage };
    const merkleTree: IMerkleTree = try retry(io, &loadOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwError("Failed to load merkle tree", .{});
    };

    //
    // Build id->hash map from the database for asset record check and repair.
    //
    var records = metadataCollection.iterateRecords();
    while (try records.next(io)) |record| {
        if (record.fields.get("hash")) |recordHash| {
            if (recordHash == .string) {
                try state.recordIdToHash.put(allocator, record._id, recordHash.string);
            }
        }
    }

    try traverseTreeAsync(SortNode, merkleTree.sort, &state, RepairState.visitNode);

    try bsonDatabase.commit(io);

    if (state.recordsRepaired.items.len > 0 or state.repaired.items.len > 0) {
        var now: std.Io.Writer.Allocating = .init(allocator);
        try js_date.writeIsoString(&now.writer, std.Io.Clock.real.now(io).toMilliseconds());
        // (TypeScript passes "repair" as the session id.)
        try tree.stampDatabaseStateLocked(allocator, io, assetStorage, rawStorage, "repair", .{ .lastModifiedAt = now.written() });
    }

    var result = state.result;
    result.modified = state.modified.items;
    result.removed = state.removed.items;
    result.repaired = state.repaired.items;
    result.unrepaired = state.unrepaired.items;
    result.recordsRepaired = state.recordsRepaired.items;
    return result;
}
