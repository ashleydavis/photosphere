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
const tools = @import("tools-zig");
const Image = tools.Image;
const ILocation = utils.reverse_geocode.ILocation;

//
// Extract dominant color from thumbnail buffer using ImageMagick
//
pub fn extractDominantColorFromThumbnail(allocator: std.mem.Allocator, io: std.Io, inputPath: []const u8) !?[3]f64 {
    var image = Image.init(inputPath);
    return try image.getDominantColor(allocator, io);
}

// Not ported: FileValidator (not used by the ported commands).

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

//
// Size of the micro thumbnail.
//
pub const MICRO_MIN_SIZE: f64 = 40;

//
// Quality of the micro thumbnail.
//
pub const MICRO_QUALITY: f64 = 75;

//
// Size of the thumbnail.
//
pub const THUMBNAIL_MIN_SIZE: f64 = 300;

//
// Quality of the thumbnail.
//
pub const THUMBNAIL_QUALITY: f64 = 90;

//
// Size of the display image.
//
pub const DISPLAY_MIN_SIZE: f64 = 1000;

//
// Quality of the display image.
//
pub const DISPLAY_QUALITY: f64 = 95;

// Not ported: DatabaseMode, IDatabaseSummary (psi summary).

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

//
// The counts of an import.
//
pub const IAddSummary = struct {
    //
    // The number of files added to the database.
    //
    filesAdded: f64 = 0,

    //
    // The number of files already in the database.
    //
    filesAlreadyAdded: f64 = 0,

    //
    // The number of files ignored (because they are not media files).
    //
    filesIgnored: f64 = 0,

    //
    // The number of files that failed to be added to the database.
    //
    filesFailed: f64 = 0,

    //
    // The number of files that were processed (completed or failed).
    //
    filesProcessed: f64 = 0,

    //
    // The total size of the files added to the database.
    //
    totalSize: f64 = 0,

    //
    // The average size of the files added to the database.
    //
    averageSize: f64 = 0,
};

//
// How long each part of producing an asset's details took.
//
// Carried out with the details themselves so an import can say where its time went. The three
// derivative images are reported apart from each other because each is a separate decode of the full
// size original today, and whether that is worth changing is a question only the numbers answer.
//
pub const IAssetDetailTimings = struct {
    // Asking the media tool for the image dimensions, which spawns it once per file.
    probeMs: f64 = 0,

    // Reading the item's own metadata: the EXIF block on a photo, the probe on a video.
    metadataMs: f64 = 0,

    // Producing each of the three derivative images.
    microMs: f64 = 0,
    thumbnailMs: f64 = 0,
    displayMs: f64 = 0,
};

//
// Represents the resolution of the image or video (TypeScript: IResolution in image.ts).
//
pub const IResolution = struct {
    //
    // The width of the image or video.
    //
    width: f64,

    //
    // The height of the image or video.
    //
    height: f64,
};

//
// Collects the details of an asset.
//
pub const IAssetDetails = struct {
    //
    // The resolution of the image/video.
    //
    resolution: IResolution,

    //
    // Where the time went producing these details.
    //
    detailTimings: IAssetDetailTimings,

    //
    // The generated micro thumbnail of the image/video.
    //
    microPath: []const u8,

    //
    // The generated thumbnail of the image/video.
    //
    thumbnailPath: []const u8,

    //
    // The content type of the thumbnail.
    //
    thumbnailContentType: []const u8,

    //
    // The display image.
    //
    displayPath: ?[]const u8 = null,

    //
    // The content type of the display image.
    //
    displayContentType: ?[]const u8 = null,

    //
    // Metadata, if any.
    //
    metadata: ?BsonValue = null,

    //
    // GPS coordinates of the asset.
    //
    coordinates: ?ILocation = null,

    //
    // Date of the asset.
    //
    photoDate: ?[]const u8 = null,

    //
    // Duration of the video, if known.
    //
    duration: ?f64 = null,
};

//
// `() => rawStorage.write('README.md', 'text/markdown', Buffer.from(DATABASE_README_CONTENT, 'utf8'))`.
//
const WriteReadmeOperation = retry_operations.WriteOperation("() => rawStorage.write(\"README.md\", \"text/markdown\", Buffer.from(DATABASE_README_CONTENT, \"utf8\"))");

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

    var infoOperation: retry_operations.InfoOperation("() => rawStorage.info(\"README.md\")") = .{ .allocator = allocator, .storage = rawStorage, .fileName = "README.md" };
    const readmeInfo = try retry(io, &infoOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwError("README.md file not found after creation.", .{});
    };

    var hashOperation: retry_operations.ComputeStorageHashOperation("async () => computeHash(await rawStorage.readStream(\"README.md\"))") = .{ .allocator = allocator, .storage = rawStorage, .fileName = "README.md" };
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

    if (!try assetStorage.isEmpty(allocator, io, "/")) {
        return errors.throwError("Cannot create new media file database in {s}. This storage location already contains files! Please create your database in a new empty directory.", .{assetStorage.location});
    }

    const treeId = if (databaseId != null and databaseId.?.len > 0) databaseId.? else try uuidGenerator.generate(allocator, io);
    var merkleTree = merkle_tree.createTree(treeId);
    merkleTree.databaseMetadata = try emptyDatabaseMetadata(allocator);

    try ensureSortIndex(io, metadataCollection);

    merkleTree = try createReadme(allocator, io, rawStorage, merkleTree);

    var saveOperation: retry_operations.SaveMerkleTreeOperation("() => saveMerkleTree(merkleTree, assetStorage)") = .{ .allocator = allocator, .merkleTree = &merkleTree, .storage = assetStorage };
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
fn EnsureSortIndexOperation(comptime sourceText: []const u8) type {
    return struct {
        // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
        pub const source = sourceText;

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
        pub fn run(self: *@This(), io: std.Io) !void {
            const sortIndex = try self.metadataCollection.sortIndex(self.fieldName, self.direction);
            try sortIndex.ensure(io, self.metadataCollection, self.sortDataType);
        }
    };
}

//
// Ensures the sort index exists.
//
pub fn ensureSortIndex(io: std.Io, metadataCollection: *IBsonCollection) !void {
    var hashOperation: EnsureSortIndexOperation("() => metadataCollection.sortIndex(\"hash\", \"asc\").ensure(metadataCollection, \"string\")") = .{ .metadataCollection = metadataCollection, .fieldName = "hash", .direction = .asc, .sortDataType = .string };
    try retry(io, &hashOperation, 3, 1_000, 2, 30_000, null);
    var photoDateOperation: EnsureSortIndexOperation("() => metadataCollection.sortIndex(\"photoDate\", \"desc\").ensure(metadataCollection, \"date\")") = .{ .metadataCollection = metadataCollection, .fieldName = "photoDate", .direction = .desc, .sortDataType = .date };
    try retry(io, &photoDateOperation, 3, 1_000, 2, 30_000, null);
}

// Not ported: getDatabaseSummary, streamAsset, writeAsset, writeAssetStream, writeAssetStreamVerified, removeAsset,
// isDatabasePartial, createLazyDatabaseStorage, openLazyOriginStorage, checkDatabaseExists (not reached by psi replicate or psi verify).

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
