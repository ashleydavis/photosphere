const std = @import("std");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const serialization_zig = @import("serialization-zig");
const bdb = @import("bdb-zig");
const api = @import("api-zig");
const tree = @import("tree.zig");
const retry_operations = @import("retry-operations.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const bson = serialization_zig.bson;
const errors = utils.errors;
const log = &utils.log.log;
const retry = utils.retry.retry;
const IStorage = storage_zig.storage.IStorage;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const ITimestampProvider = utils.timestamp_provider.ITimestampProvider;
const IMerkleTree = merkle_tree.IMerkleTree;
const BsonDatabase = bdb.database.BsonDatabase;
const IBsonCollection = bdb.collection.IBsonCollection;
const BsonDocument = bson.BsonDocument;
const BsonValue = bson.BsonValue;

// Not ported: extractDominantColorFromThumbnail, FileValidator (psi add, not psi replicate or psi verify).

//
// Progress callback for the add operation.
// (Zig: a closure; `function` is called with `context`. The message is only valid during the call.)
//
pub const ProgressCallback = struct {
    // The state of the callback, passed to function.
    context: ?*anyopaque,

    // The callback function.
    function: *const fn (context: ?*anyopaque, currentlyScanning: ?[]const u8) void,

    //
    // Invokes the callback.
    //
    pub fn call(self: ProgressCallback, currentlyScanning: ?[]const u8) void {
        self.function(self.context, currentlyScanning);
    }
};

// Not ported: MICRO_MIN_SIZE, MICRO_QUALITY, THUMBNAIL_MIN_SIZE, THUMBNAIL_QUALITY, DISPLAY_MIN_SIZE, DISPLAY_QUALITY,
// IDatabaseSummary (psi add and psi summary, not psi replicate or psi verify).

//
// Database metadata that gets embedded in the merkle tree
// (Zig: IMerkleTree.databaseMetadata is a BSON document, because that is how the metadata is stored in the tree
// file. The document has these keys:
//   filesImported: number     Number of files imported into the database
//   deletedAssetIds?: string[] List of asset IDs that have been deleted from the database
//   isPartial?: boolean       If true, this database is a partial copy (only thumb directory assets are present)
// The functions below read and create it.)
//

//
// Equivalent of `databaseMetadata?.filesImported || 0`. (No TypeScript counterpart: the expression is inline.)
//
pub fn getFilesImported(databaseMetadata: ?BsonDocument) u64 {
    const metadata = databaseMetadata orelse {
        return 0;
    };
    const value = metadata.get("filesImported") orelse {
        return 0;
    };
    const number: f64 = switch (value) {
        .number => |number| number,
        .double => |number| number,
        .int32 => |number| @floatFromInt(number),
        .int64 => |number| @floatFromInt(number),
        else => 0,
    };
    if (!(number > 0) or !std.math.isFinite(number)) {
        return 0;
    }
    return @intFromFloat(number);
}

//
// Equivalent of `databaseMetadata?.isPartial === true`. (No TypeScript counterpart: the expression is inline.)
//
pub fn isPartialDatabase(databaseMetadata: ?BsonDocument) bool {
    const metadata = databaseMetadata orelse {
        return false;
    };
    const value = metadata.get("isPartial") orelse {
        return false;
    };
    return switch (value) {
        .boolean => |boolean| boolean,
        else => false,
    };
}

//
// Creates the metadata object literal `{ filesImported: 0 }`. (No TypeScript counterpart: the literal is inline.)
//
pub fn emptyDatabaseMetadata(allocator: std.mem.Allocator) !BsonDocument {
    var metadata: BsonDocument = .empty;
    try metadata.put(allocator, "filesImported", .{ .number = 0 });
    return metadata;
}

//
// Copies a metadata document like the object spread `{ ...databaseMetadata }` (same keys in the same order).
// (No TypeScript counterpart: the spread is inline.)
//
pub fn copyDatabaseMetadata(allocator: std.mem.Allocator, databaseMetadata: BsonDocument) !BsonDocument {
    var copy: BsonDocument = .empty;
    for (databaseMetadata.fields.items) |field| {
        try copy.put(allocator, field.key, field.value);
    }
    return copy;
}

// Not ported: IAddSummary, IAssetDetails (psi add, not psi replicate or psi verify).

//
// `() => rawStorage.write('README.md', 'text/markdown', Buffer.from(DATABASE_README_CONTENT, 'utf8'))`.
//
const WriteReadmeOperation = retry_operations.WriteOperation;

//
// Creates the README.md file in the database.
// Returns the updated merkle tree with the README.md file added.
//
pub fn createReadme(
    allocator: std.mem.Allocator,
    io: std.Io,
    rawStorage: IStorage,
    merkleTree: IMerkleTree,
) !IMerkleTree {
    // Create README.md file with warning about manual modifications
    var writeOperation: WriteReadmeOperation = .{
        .allocator = allocator,
        .storage = rawStorage,
        .fileName = "README.md",
        .contentType = "text/markdown",
        .data = DATABASE_README_CONTENT,
    };
    try retry(io, &writeOperation, 3, 1_000, 2, 30_000, null);

    var infoOperation: retry_operations.InfoOperation = .{ .allocator = allocator, .storage = rawStorage, .fileName = "README.md" };
    const readmeInfo = try retry(io, &infoOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwError("README.md file not found after creation.", .{});
    };

    var hashOperation: retry_operations.ComputeStorageHashOperation = .{ .allocator = allocator, .storage = rawStorage, .fileName = "README.md" };
    const readmeHash = try retry(io, &hashOperation, 3, 1_000, 2, 30_000, null);

    return try merkle_tree.addItem(allocator, &merkleTree, .{
        .name = "README.md",
        .hash = try allocator.dupe(u8, &readmeHash),
        .length = readmeInfo.length,
        .lastModified = readmeInfo.lastModified,
    });
}

//
// The database dependencies returned by createMediaFileDatabase.
// (TypeScript: the anonymous object type returned by createMediaFileDatabase.)
//
pub const IMediaFileDatabase = struct {
    // The storage the database was created with.
    assetStorage: IStorage,

    // The BSON database stored under .db/bson.
    bsonDatabase: *BsonDatabase,

    // The metadata collection of the BSON database.
    metadataCollection: *IBsonCollection,
};

//
// Creates database dependencies. Uses v6 layout (BSON under .db/bson).
// Only psi upgrade reads the old "metadata/" layout when migrating v5 → v6.
// (Zig: the database is allocated with the allocator and keeps it.)
//
pub fn createMediaFileDatabase(
    allocator: std.mem.Allocator,
    assetStorage: IStorage,
    uuidGenerator: IUuidGenerator,
    timestampProvider: ITimestampProvider,
) !IMediaFileDatabase {
    const bsonDatabase = try BsonDatabase.init(allocator, assetStorage, ".db/bson", uuidGenerator, timestampProvider);

    const metadataCollection = try bsonDatabase.collection("metadata");

    return .{
        .assetStorage = assetStorage,
        .bsonDatabase = bsonDatabase,
        .metadataCollection = metadataCollection,
    };
}

//
// Creates a new media file database.
//
pub fn createDatabase(
    allocator: std.mem.Allocator,
    io: std.Io,
    assetStorage: IStorage,
    rawStorage: IStorage,
    uuidGenerator: IUuidGenerator,
    metadataCollection: *IBsonCollection,
    databaseId: ?[]const u8,
) !void {

    if (!try assetStorage.isEmpty(allocator, io, "./")) {
        return errors.throwError("Cannot create new media file database in {s}. This storage location already contains files! Please create your database in a new empty directory.", .{assetStorage.location});
    }

    const treeId = if (databaseId != null and databaseId.?.len > 0) databaseId.? else try uuidGenerator.generate(allocator, io);
    var merkleTree = merkle_tree.createTree(treeId);
    merkleTree.databaseMetadata = try emptyDatabaseMetadata(allocator);

    try ensureSortIndex(io, metadataCollection);

    merkleTree = try createReadme(allocator, io, rawStorage, merkleTree);

    var saveOperation: retry_operations.SaveMerkleTreeOperation = .{ .allocator = allocator, .merkleTree = &merkleTree, .storage = assetStorage };
    try retry(io, &saveOperation, 3, 1_000, 2, 30_000, null);

    try api.database_config.saveDatabaseConfig(allocator, io, rawStorage, api.database_config.IDatabaseConfig{});

    log.verbose("Created new media file database.");
}

//
// Loads sort indexes for an existing media file database.
//
pub fn loadSortIndexes(
    allocator: std.mem.Allocator,
    assetStorage: IStorage,
    _metadataCollection: *IBsonCollection,
) !void {
    _ = _metadataCollection;
    log.verbose(try std.fmt.allocPrint(allocator, "Loaded existing media file database from: {s}", .{assetStorage.location}));
}

//
// `() => metadataCollection.sortIndex(fieldName, direction).ensure(metadataCollection, sortDataType)`.
//
const EnsureSortIndexOperation = struct {
    // The collection that owns the sort index.
    metadataCollection: *IBsonCollection,

    // The field the index sorts by.
    fieldName: []const u8,

    // The sort direction.
    direction: bdb.sort_index.SortDirection,

    // The type of the sorted values.
    sortDataType: bdb.sort_index.SortDataType,

    //
    // Loads the sort index, building it when it does not exist.
    //
    pub fn run(self: *EnsureSortIndexOperation, io: std.Io) !void {
        const sortIndex = try self.metadataCollection.sortIndex(self.fieldName, self.direction);
        try sortIndex.ensure(io, self.metadataCollection, self.sortDataType);
    }
};

//
// Ensures the sort index exists.
//
pub fn ensureSortIndex(io: std.Io, metadataCollection: *IBsonCollection) !void {
    var hashOperation: EnsureSortIndexOperation = .{ .metadataCollection = metadataCollection, .fieldName = "hash", .direction = .asc, .sortDataType = .string };
    try retry(io, &hashOperation, 3, 1_000, 2, 30_000, null);
    var photoDateOperation: EnsureSortIndexOperation = .{ .metadataCollection = metadataCollection, .fieldName = "photoDate", .direction = .desc, .sortDataType = .date };
    try retry(io, &photoDateOperation, 3, 1_000, 2, 30_000, null);
}

// Not ported: getDatabaseSummary, streamAsset, writeAsset, writeAssetStream, writeAssetStreamVerified, removeAsset,
// isDatabasePartial, createLazyDatabaseStorage, checkConnectivity (not reached by psi replicate or psi verify).

//
// README content for database directories
//
pub const DATABASE_README_CONTENT =
    \\# Photosphere Database Directory
    \\
    \\⚠️  **WARNING: Do not modify any files in this directory manually!**
    \\
    \\This directory contains a Photosphere media file database. The files and folders here are managed automatically by the Photosphere CLI tool (`psi`).
    \\
    \\## Important rules
    \\
    \\- **Never edit, delete, or move files in this directory manually**
    \\- **Always use the `psi` command-line tool to make changes to your database**
    \\- **Manual modifications can corrupt your database and cause data loss**
    \\
    \\## Common operations
    \\
    \\To work with your media database, use these commands:
    \\
    \\- Add photos/videos: `psi add <source-directory>`
    \\- View database summary: `psi summary`
    \\- Check database integrity: `psi verify`
    \\- Backup/replicate: `psi replicate --dest <destination>`
    \\- Compare databases: `psi compare --dest <other-database>`
    \\
    \\For more help: `psi --help`
    \\
    \\---
    \\*This file was automatically generated by Photosphere CLI*
    \\
;
