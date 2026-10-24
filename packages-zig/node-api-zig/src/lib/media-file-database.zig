const std = @import("std");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const serialization_zig = @import("serialization-zig");
const bdb = @import("bdb-zig");
const api = @import("api-zig");
const tree = @import("tree.zig");
const open_storage = @import("open-storage.zig");
const retry_operations = @import("retry-operations.zig");
const resolve_storage_credentials = @import("resolve-storage-credentials.zig");
const lazy_origin_storage = @import("lazy-origin-storage.zig");
const encryption = @import("encryption-zig");
const LazyOriginStorage = lazy_origin_storage.LazyOriginStorage;
const merkle_tree = merkle_tree_zig.merkle_tree;
const bson = serialization_zig.bson;
const errors = utils.errors;
const log = &utils.log.log;
const retry = utils.retry.retry;
const retryOnce = utils.retry.retryOnce;
const DATABASE_REACHABLE_TIMEOUT = api.constants.DATABASE_REACHABLE_TIMEOUT;
const IStorage = storage_zig.storage.IStorage;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const ITimestampProvider = utils.timestamp_provider.ITimestampProvider;
const IMerkleTree = merkle_tree.IMerkleTree;
const BsonDatabase = bdb.database.BsonDatabase;
const IBsonCollection = bdb.collection.IBsonCollection;
const BsonDocument = bson.BsonDocument;
const BsonValue = bson.BsonValue;
const IFileStat = @import("file-scanner.zig").IFileStat;
const tools = @import("tools-zig");
const Image = tools.Image;
const InProcessRunner = @import("node-utils-zig").in_process_tools.InProcessRunner;
const ILocation = utils.reverse_geocode.ILocation;

//
// Extract dominant color from thumbnail buffer using ImageMagick
//
pub fn extractDominantColorFromThumbnail(allocator: std.mem.Allocator, io: std.Io, toolRunner: InProcessRunner, inputPath: []const u8) !?[3]f64 {
    var image = Image.init(inputPath);
    return try image.getDominantColor(allocator, io, toolRunner);
}

//
// A function that validates a file.
// (Zig: a closure; `function` is called with `context`. The strings are only valid during the call.)
//
pub const FileValidator = struct {
    // The state of the validator, passed to function.
    context: ?*anyopaque,

    // The validator function.
    function: *const fn (context: ?*anyopaque, io: std.Io, filePath: []const u8, fileStat: IFileStat, contentType: []const u8, zipFilePath: ?[]const u8) anyerror!bool,

    //
    // Invokes the validator.
    //
    pub fn call(self: FileValidator, io: std.Io, filePath: []const u8, fileStat: IFileStat, contentType: []const u8, zipFilePath: ?[]const u8) anyerror!bool {
        return self.function(self.context, io, filePath, fileStat, contentType, zipFilePath);
    }
};

//
// Progress callback for the add operation.
// (Zig: a closure; `function` is called with `context`. The message is only valid during the call.)
//
pub const ProgressCallback = struct {
    // The state of the callback, passed to function.
    context: ?*anyopaque,

    // The callback function.
    function: *const fn (context: ?*anyopaque, io: std.Io, currentlyScanning: ?[]const u8) void,

    //
    // Invokes the callback.
    //
    pub fn call(self: ProgressCallback, io: std.Io, currentlyScanning: ?[]const u8) void {
        self.function(self.context, io, currentlyScanning);
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

//
// Whether the database holds every asset or only a partial set.
// "partial" means only the thumb directory's assets are present locally and the rest are fetched
// lazily from the database's origin.
//
pub const DatabaseMode = enum {
    // Every asset is present.
    full,

    // Only the thumb directory's assets are present.
    partial,
};

//
// A summary of the database.
//
pub const IDatabaseSummary = struct {
    // Whether this database is a full copy or a partial replica.
    mode: DatabaseMode,

    // Total number of files imported into the database.
    totalImports: u64,

    // Total number of files in the database (including thumbnails, display images, BSON files, etc.).
    totalFiles: u64,

    // Total size of all files in bytes.
    totalSize: u64,

    // Total number of nodes in the merkle tree.
    totalNodes: u64,

    // Full hash of the tree root.
    fullHash: []const u8,

    // Root hash of the files merkle tree.
    filesHash: ?[]const u8,

    // Root hash of the BSON database merkle tree.
    databaseHash: ?[]const u8,

    // Database version from merkle tree.
    databaseVersion: u32,
};

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
// TODO: a filesImported that is not a whole number reads as 0 or truncated.
//
// Gets the number of files imported from the database metadata, or 0 when there is none.
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
// Whether the database metadata says the database is partial (`isPartial` is true).
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
// Creates the metadata document `{ filesImported: 0 }`.
//
pub fn emptyDatabaseMetadata(allocator: std.mem.Allocator) !BsonDocument {
    var metadata: BsonDocument = .empty;
    try metadata.put(allocator, "filesImported", .{
        .number = 0,
    });
    return metadata;
}

//
// Copies a metadata document (same keys in the same order).
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
// Represents the resolution of the image or video.
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

    var infoOperation: retry_operations.InfoOperation("() => rawStorage.info(\"README.md\")") = .{
        .allocator = allocator,
        .storage = rawStorage,
        .fileName = "README.md",
    };
    const readmeInfo = try retry(io, &infoOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwError("README.md file not found after creation.", .{});
    };

    var hashOperation: retry_operations.ComputeStorageHashOperation("async () => computeHash(await rawStorage.readStream(\"README.md\"))") = .{
        .allocator = allocator,
        .storage = rawStorage,
        .fileName = "README.md",
    };
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

    var saveOperation: retry_operations.SaveMerkleTreeOperation("() => saveMerkleTree(merkleTree, assetStorage)") = .{
        .allocator = allocator,
        .merkleTree = &merkleTree,
        .storage = assetStorage,
    };
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
        // The text that stands for this operation in the timeout message of retryOnce.
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
    var hashOperation: EnsureSortIndexOperation("() => metadataCollection.sortIndex(\"hash\", \"asc\").ensure(metadataCollection, \"string\")") = .{
        .metadataCollection = metadataCollection,
        .fieldName = "hash",
        .direction = .asc,
        .sortDataType = .string,
    };
    try retry(io, &hashOperation, 3, 1_000, 2, 30_000, null);
    var photoDateOperation: EnsureSortIndexOperation("() => metadataCollection.sortIndex(\"photoDate\", \"desc\").ensure(metadataCollection, \"date\")") = .{
        .metadataCollection = metadataCollection,
        .fieldName = "photoDate",
        .direction = .desc,
        .sortDataType = .date,
    };
    try retry(io, &photoDateOperation, 3, 1_000, 2, 30_000, null);
}

//
// `() => getDatabaseRootHash(assetStorage, ".db/bson")`.
//
const GetDatabaseRootHashOperation = struct {
    // The text that stands for this operation in the timeout message of retryOnce.
    pub const source = "() => getDatabaseRootHash(assetStorage, \".db/bson\")";

    // Allocates the loaded tree.
    allocator: std.mem.Allocator,

    // The database storage.
    assetStorage: IStorage,

    //
    // Gets the root hash of the BSON database tree.
    //
    pub fn run(self: *@This(), io: std.Io) !?[]const u8 {
        return bdb.merkle_tree.getDatabaseRootHash(self.allocator, io, self.assetStorage, ".db/bson");
    }
};

//
// Gets a summary of the entire media file database.
//
pub fn getDatabaseSummary(allocator: std.mem.Allocator, io: std.Io, assetStorage: IStorage) !IDatabaseSummary {
    var loadOperation: retry_operations.LoadMerkleTreeOperation("() => loadMerkleTree(assetStorage)") = .{
        .allocator = allocator,
        .storage = assetStorage,
    };
    const merkleTree = try retry(io, &loadOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwError("Failed to load merkle tree.", .{});
    };

    const filesImported = getFilesImported(merkleTree.databaseMetadata);

    // Get root hashes from both merkle trees (compute inline to avoid loading merkle tree again)
    const filesRootHash: ?[]const u8 = if (merkleTree.merkle) |merkle| merkle.hash else null;
    var rootHashOperation: GetDatabaseRootHashOperation = .{
        .allocator = allocator,
        .assetStorage = assetStorage,
    };
    const databaseRootHash = try retry(io, &rootHashOperation, 3, 1_000, 2, 30_000, null);

    // Compute aggregate root hash
    var fullHash: []const u8 = undefined;
    if (filesRootHash != null and databaseRootHash != null) {
        const aggregateHash = merkle_tree.combineHashes(filesRootHash.?, databaseRootHash.?);
        fullHash = try std.fmt.allocPrint(allocator, "{x}", .{&aggregateHash});
    }
    else if (filesRootHash) |hash| {
        fullHash = try std.fmt.allocPrint(allocator, "{x}", .{hash});
    }
    else if (databaseRootHash) |hash| {
        fullHash = try std.fmt.allocPrint(allocator, "{x}", .{hash});
    }
    else {
        fullHash = "empty";
    }

    return .{
        .mode = if (isPartialDatabase(merkleTree.databaseMetadata)) .partial else .full,
        .totalImports = filesImported,
        .totalFiles = if (merkleTree.sort) |sort| sort.leafCount else 0,
        .totalSize = if (merkleTree.sort) |sort| sort.size else 0,
        .totalNodes = if (merkleTree.sort) |sort| sort.nodeCount else 0,
        .fullHash = fullHash,
        .filesHash = if (filesRootHash) |hash| try std.fmt.allocPrint(allocator, "{x}", .{hash}) else null,
        .databaseHash = if (databaseRootHash) |hash| try std.fmt.allocPrint(allocator, "{x}", .{hash}) else null,
        .databaseVersion = merkleTree.version,
    };
}

//
// Streams an asset from the database.
// This is used by the REST API server to read assets.
// (Zig: the stream is destroyed by the caller, with IReadStream.destroy.)
//
pub fn streamAsset(allocator: std.mem.Allocator, io: std.Io, assetStorage: IStorage, assetId: []const u8, assetType: []const u8) !storage_zig.storage.IReadStream {
    const assetPath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ assetType, assetId });
    return assetStorage.readStream(allocator, io, assetPath);
}

//
// Writes an asset from a buffer with a specific asset ID.
// This is used by the REST API server to add assets uploaded via HTTP.
// (Zig: acquireWriteLock and retry are given their parameters in full, as Zig has no default parameter
// values; the lock is released before the failure of the try and catch blocks is returned.)
//
pub fn writeAsset(
    allocator: std.mem.Allocator,
    io: std.Io,
    assetStorage: IStorage,
    rawStorage: IStorage,
    sessionId: []const u8,
    assetId: []const u8,
    assetType: []const u8,
    contentType: ?[]const u8,
    buffer: []const u8,
) !void {
    const assetPath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ assetType, assetId });

    if (!try api.write_lock.acquireWriteLock(allocator, io, rawStorage, sessionId, 3)) {
        return errors.throwError("Failed to acquire write lock.", .{});
    }
    const result = writeAssetUnderLock(allocator, io, assetStorage, rawStorage, sessionId, assetType, assetPath, contentType, buffer);
    try api.write_lock.releaseWriteLock(allocator, io, rawStorage);
    return result;
}

//
// The try and catch blocks of writeAsset, run holding the write lock.
// (Zig needs them as a function to release the lock in the finally
// block whether they failed or not.)
//
fn writeAssetUnderLock(
    allocator: std.mem.Allocator,
    io: std.Io,
    assetStorage: IStorage,
    rawStorage: IStorage,
    sessionId: []const u8,
    assetType: []const u8,
    assetPath: []const u8,
    contentType: ?[]const u8,
    buffer: []const u8,
) !void {
    writeAssetTry(allocator, io, assetStorage, rawStorage, sessionId, assetType, assetPath, contentType, buffer) catch |err| {
        log.exception(try std.fmt.allocPrint(allocator, "Failed to add asset \"{s}\" from buffer", .{assetPath}), err);
        var deleteOperation: retry_operations.DeleteFileOperation("() => assetStorage.deleteFile(assetPath)") = .{
            .allocator = allocator,
            .storage = assetStorage,
            .filePath = assetPath,
        };
        try retry(io, &deleteOperation, 3, 1_000, 2, 30_000, null);
        return err;
    };
}

//
// The try block of writeAsset.
//
fn writeAssetTry(
    allocator: std.mem.Allocator,
    io: std.Io,
    assetStorage: IStorage,
    rawStorage: IStorage,
    sessionId: []const u8,
    assetType: []const u8,
    assetPath: []const u8,
    contentType: ?[]const u8,
    buffer: []const u8,
) !void {
    var loadOperation: retry_operations.LoadMerkleTreeOperation("() => loadMerkleTree(assetStorage)") = .{
        .allocator = allocator,
        .storage = assetStorage,
    };
    var merkleTree: IMerkleTree = try retry(io, &loadOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwError("Failed to load media file database.", .{});
    };

    var writeOperation: retry_operations.WriteOperation("() => assetStorage.write(assetPath, contentType, buffer)") = .{
        .allocator = allocator,
        .storage = assetStorage,
        .fileName = assetPath,
        .contentType = contentType,
        .data = buffer,
    };
    try retry(io, &writeOperation, 3, 1_000, 2, 30_000, null);

    var infoOperation: retry_operations.InfoOperation("() => assetStorage.info(assetPath)") = .{
        .allocator = allocator,
        .storage = assetStorage,
        .fileName = assetPath,
    };
    const assetInfo = try retry(io, &infoOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwError("Failed to get info for file \"{s}\"", .{assetPath});
    };

    var hashOperation: retry_operations.ComputeAssetHashOperation("async () => computeAssetHash(await assetStorage.readStream(assetPath), assetInfo)") = .{
        .allocator = allocator,
        .storage = assetStorage,
        .fileName = assetPath,
        .fileInfo = assetInfo,
    };
    const hashedAsset = try retry(io, &hashOperation, 3, 1_000, 2, 30_000, null);

    try api.write_lock.refreshWriteLock(allocator, io, rawStorage, sessionId);

    merkleTree = try merkle_tree.addItem(allocator, &merkleTree, .{
        .name = assetPath,
        .hash = hashedAsset.hash,
        .length = hashedAsset.length,
        .lastModified = hashedAsset.lastModified,
    });

    if (std.mem.eql(u8, assetType, "asset")) {
        var databaseMetadata = merkleTree.databaseMetadata orelse try emptyDatabaseMetadata(allocator);
        const filesImported = databaseMetadata.get("filesImported") orelse BsonValue.undefined;
        const filesImportedNumber = if (filesImported == .undefined) std.math.nan(f64) else try bdb.js_value.toNumber(allocator, filesImported);
        try databaseMetadata.put(allocator, "filesImported", .{
            .number = filesImportedNumber + 1,
        });
        merkleTree.databaseMetadata = databaseMetadata;
    }

    var saveOperation: retry_operations.SaveMerkleTreeOperation("() => saveMerkleTree(merkleTree, assetStorage)") = .{
        .allocator = allocator,
        .merkleTree = &merkleTree,
        .storage = assetStorage,
    };
    try retry(io, &saveOperation, 3, 1_000, 2, 30_000, null);
    try tree.stampDatabaseModified(allocator, io, assetStorage, rawStorage);
}

//
// Writes an asset from a readable byte stream (same lock / merkle behavior as writeAsset).
// Callers that know the byte length (e.g. from Content-Length) should pass it for storage backends that use a size hint.
// (Zig: acquireWriteLock and retry are given their parameters in full, as Zig has no default parameter
// values; the lock is released before the failure of the try and catch blocks is returned.)
//
pub fn writeAssetStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    assetStorage: IStorage,
    rawStorage: IStorage,
    sessionId: []const u8,
    assetId: []const u8,
    assetType: []const u8,
    contentType: ?[]const u8,
    inputStream: *std.Io.Reader,
    contentLength: ?u64,
) !void {
    const assetPath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ assetType, assetId });

    if (!try api.write_lock.acquireWriteLock(allocator, io, rawStorage, sessionId, 3)) {
        return errors.throwError("Failed to acquire write lock.", .{});
    }
    const result = writeAssetStreamUnderLock(allocator, io, assetStorage, rawStorage, sessionId, assetType, assetPath, contentType, inputStream, contentLength);
    try api.write_lock.releaseWriteLock(allocator, io, rawStorage);
    return result;
}

//
// The try and catch blocks of writeAssetStream, run holding the write lock. (See writeAssetUnderLock.)
//
fn writeAssetStreamUnderLock(
    allocator: std.mem.Allocator,
    io: std.Io,
    assetStorage: IStorage,
    rawStorage: IStorage,
    sessionId: []const u8,
    assetType: []const u8,
    assetPath: []const u8,
    contentType: ?[]const u8,
    inputStream: *std.Io.Reader,
    contentLength: ?u64,
) !void {
    writeAssetStreamTry(allocator, io, assetStorage, rawStorage, sessionId, assetType, assetPath, contentType, inputStream, contentLength) catch |err| {
        log.exception(try std.fmt.allocPrint(allocator, "Failed to add asset \"{s}\" from stream", .{assetPath}), err);
        var deleteOperation: retry_operations.DeleteFileOperation("() => assetStorage.deleteFile(assetPath)") = .{
            .allocator = allocator,
            .storage = assetStorage,
            .filePath = assetPath,
        };
        try retry(io, &deleteOperation, 3, 1_000, 2, 30_000, null);
        return err;
    };
}

//
// The try block of writeAssetStream.
//
fn writeAssetStreamTry(
    allocator: std.mem.Allocator,
    io: std.Io,
    assetStorage: IStorage,
    rawStorage: IStorage,
    sessionId: []const u8,
    assetType: []const u8,
    assetPath: []const u8,
    contentType: ?[]const u8,
    inputStream: *std.Io.Reader,
    contentLength: ?u64,
) !void {
    var loadOperation: retry_operations.LoadMerkleTreeOperation("() => loadMerkleTree(assetStorage)") = .{
        .allocator = allocator,
        .storage = assetStorage,
    };
    var merkleTree: IMerkleTree = try retry(io, &loadOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwError("Failed to load media file database.", .{});
    };

    var writeOperation: retry_operations.WriteStreamOperation("() => assetStorage.writeStream(assetPath, contentType, inputStream, contentLength)") = .{
        .allocator = allocator,
        .storage = assetStorage,
        .fileName = assetPath,
        .contentType = contentType,
        .inputStream = inputStream,
        .contentLength = contentLength,
    };
    try retry(io, &writeOperation, 3, 1_000, 2, 30_000, null);

    var infoOperation: retry_operations.InfoOperation("() => assetStorage.info(assetPath)") = .{
        .allocator = allocator,
        .storage = assetStorage,
        .fileName = assetPath,
    };
    const assetInfo = try retry(io, &infoOperation, 3, 1_000, 2, 30_000, null);
    if (assetInfo == null or assetInfo.?.length == 0) {
        return errors.throwError("Asset data is empty", .{});
    }

    var hashOperation: retry_operations.ComputeAssetHashOperation("async () => computeAssetHash(await assetStorage.readStream(assetPath), assetInfo)") = .{
        .allocator = allocator,
        .storage = assetStorage,
        .fileName = assetPath,
        .fileInfo = assetInfo.?,
    };
    const hashedAsset = try retry(io, &hashOperation, 3, 1_000, 2, 30_000, null);

    try api.write_lock.refreshWriteLock(allocator, io, rawStorage, sessionId);

    merkleTree = try merkle_tree.addItem(allocator, &merkleTree, .{
        .name = assetPath,
        .hash = hashedAsset.hash,
        .length = hashedAsset.length,
        .lastModified = hashedAsset.lastModified,
    });

    if (std.mem.eql(u8, assetType, "asset")) {
        var databaseMetadata = merkleTree.databaseMetadata orelse try emptyDatabaseMetadata(allocator);
        const filesImported = databaseMetadata.get("filesImported") orelse BsonValue.undefined;
        const filesImportedNumber = if (filesImported == .undefined) std.math.nan(f64) else try bdb.js_value.toNumber(allocator, filesImported);
        try databaseMetadata.put(allocator, "filesImported", .{
            .number = filesImportedNumber + 1,
        });
        merkleTree.databaseMetadata = databaseMetadata;
    }

    var saveOperation: retry_operations.SaveMerkleTreeOperation("() => saveMerkleTree(merkleTree, assetStorage)") = .{
        .allocator = allocator,
        .merkleTree = &merkleTree,
        .storage = assetStorage,
    };
    try retry(io, &saveOperation, 3, 1_000, 2, 30_000, null);
    try tree.stampDatabaseModified(allocator, io, assetStorage, rawStorage);
}

//
// Writes an asset stream to the destination storage and then verifies the written file is
// byte-for-byte identical to the source file before resolving. Hashes both source and dest
// and throws if they do not match, ensuring the source is never deleted until the copy is confirmed intact.
// (Zig: retry is given its parameters in full, as Zig has no default parameter values.)
//
pub fn writeAssetStreamVerified(
    allocator: std.mem.Allocator,
    io: std.Io,
    sourceStorage: IStorage,
    destStorage: IStorage,
    destRawStorage: IStorage,
    sessionId: []const u8,
    sourceAssetId: []const u8,
    destAssetId: []const u8,
    assetType: []const u8,
    contentType: ?[]const u8,
    inputStream: *std.Io.Reader,
    contentLength: ?u64,
) !void {
    try writeAssetStream(allocator, io, destStorage, destRawStorage, sessionId, destAssetId, assetType, contentType, inputStream, contentLength);

    const sourceAssetPath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ assetType, sourceAssetId });
    const destAssetPath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ assetType, destAssetId });

    var sourceInfoOperation: retry_operations.InfoOperation("() => sourceStorage.info(sourceAssetPath)") = .{
        .allocator = allocator,
        .storage = sourceStorage,
        .fileName = sourceAssetPath,
    };
    const sourceInfo = try retry(io, &sourceInfoOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwError("Verification failed: source file \"{s}\" is no longer accessible after write.", .{sourceAssetPath});
    };

    var destInfoOperation: retry_operations.InfoOperation("() => destStorage.info(destAssetPath)") = .{
        .allocator = allocator,
        .storage = destStorage,
        .fileName = destAssetPath,
    };
    const destInfo = try retry(io, &destInfoOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwError("Verification failed: destination file \"{s}\" not found after write.", .{destAssetPath});
    };

    var sourceHashOperation: retry_operations.ComputeAssetHashOperation("async () => computeAssetHash(await sourceStorage.readStream(sourceAssetPath), sourceInfo)") = .{
        .allocator = allocator,
        .storage = sourceStorage,
        .fileName = sourceAssetPath,
        .fileInfo = sourceInfo,
    };
    const sourceHash = try retry(io, &sourceHashOperation, 3, 1_000, 2, 30_000, null);

    var destHashOperation: retry_operations.ComputeAssetHashOperation("async () => computeAssetHash(await destStorage.readStream(destAssetPath), destInfo)") = .{
        .allocator = allocator,
        .storage = destStorage,
        .fileName = destAssetPath,
        .fileInfo = destInfo,
    };
    const destHash = try retry(io, &destHashOperation, 3, 1_000, 2, 30_000, null);

    if (!std.mem.eql(u8, sourceHash.hash, destHash.hash)) {
        return errors.throwError("Verification failed: hash mismatch for \"{s}\" of asset \"{s}\" -- destination copy is corrupt.", .{ assetType, sourceAssetId });
    }
}

//
// Removes an asset: its files from the files tree and storage, and its record from the metadata collection.
// When recordDeleted is true the asset ID is added to the database metadata's deletedAssetIds.
//
pub fn removeAsset(
    allocator: std.mem.Allocator,
    io: std.Io,
    assetStorage: IStorage,
    rawStorage: IStorage,
    sessionId: []const u8,
    bsonDatabase: *BsonDatabase,
    metadataCollection: *IBsonCollection,
    assetId: []const u8,
    recordDeleted: bool,
) !void {
    //
    // Flush the cache so we reload data after acquiring the write lock.
    //
    try bsonDatabase.flush();

    if (!try api.write_lock.acquireWriteLock(allocator, io, rawStorage, sessionId, 3)) {
        return errors.throwError("Failed to acquire write lock.", .{});
    }
    const result = removeAssetUnderLock(allocator, io, assetStorage, rawStorage, bsonDatabase, metadataCollection, assetId, recordDeleted);
    try api.write_lock.releaseWriteLock(allocator, io, rawStorage);
    return result;
}

//
// The body of removeAsset's try block, run holding the write lock.
// Zig needs it as a function to release the lock
// in the finally block whether it failed or not.
//
fn removeAssetUnderLock(
    allocator: std.mem.Allocator,
    io: std.Io,
    assetStorage: IStorage,
    rawStorage: IStorage,
    bsonDatabase: *BsonDatabase,
    metadataCollection: *IBsonCollection,
    assetId: []const u8,
    recordDeleted: bool,
) !void {
    var loadOperation: retry_operations.LoadMerkleTreeOperation("() => loadMerkleTree(assetStorage)") = .{
        .allocator = allocator,
        .storage = assetStorage,
    };
    var merkleTree: IMerkleTree = try retry(io, &loadOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwError("Failed to load media file database.", .{});
    };

    //
    // Delete the files from the merkle tree.
    // We do this first because if there's a failure after this point
    // the files and database records become orphans and can easily be fixed.
    //
    const assetPath = try storage_zig.storage_factory.pathJoin(allocator, &.{ "asset", assetId });
    const displayPath = try storage_zig.storage_factory.pathJoin(allocator, &.{ "display", assetId });
    const thumbPath = try storage_zig.storage_factory.pathJoin(allocator, &.{ "thumb", assetId });
    try merkle_tree.deleteItem(allocator, &merkleTree, assetPath);
    try merkle_tree.deleteItem(allocator, &merkleTree, displayPath);
    try merkle_tree.deleteItem(allocator, &merkleTree, thumbPath);

    const removed = try metadataCollection.deleteOne(io, assetId);
    if (removed) {
        var databaseMetadata = merkleTree.databaseMetadata orelse try emptyDatabaseMetadata(allocator);
        const filesImported = databaseMetadata.get("filesImported") orelse BsonValue.undefined;
        const filesImportedNumber = try bdb.js_value.toNumber(allocator, filesImported);
        if (filesImported != .undefined and filesImportedNumber > 0) {
            try databaseMetadata.put(allocator, "filesImported", .{
                .number = filesImportedNumber - 1,
            });
        }

        // Record deleted asset ID if requested
        if (recordDeleted) {
            var deletedAssetIds: std.ArrayList(BsonValue) = .empty;
            if (databaseMetadata.get("deletedAssetIds")) |existing| {
                if (existing == .array) {
                    try deletedAssetIds.appendSlice(allocator, existing.array);
                }
            }
            var alreadyRecorded = false;
            for (deletedAssetIds.items) |deletedAssetId| {
                if (deletedAssetId == .string and std.mem.eql(u8, deletedAssetId.string, assetId)) {
                    alreadyRecorded = true;
                }
            }
            if (!alreadyRecorded) {
                try deletedAssetIds.append(allocator, .{
                    .string = assetId,
                });
            }
            try databaseMetadata.put(allocator, "deletedAssetIds", .{
                .array = deletedAssetIds.items,
            });
        }
        merkleTree.databaseMetadata = databaseMetadata;
    }

    // Commit accumulated changes to bsondb.
    try bsonDatabase.commit(io);

    // Merkle tree has to be saved after all modifications to it are made.
    var saveOperation: retry_operations.SaveMerkleTreeOperation("() => saveMerkleTree(merkleTree, assetStorage)") = .{
        .allocator = allocator,
        .merkleTree = &merkleTree,
        .storage = assetStorage,
    };
    try retry(io, &saveOperation, 3, 1_000, 2, 30_000, null);

    //
    // Delete the files from storage.
    //
    try assetStorage.deleteFile(allocator, io, assetPath);
    try assetStorage.deleteFile(allocator, io, displayPath);
    try assetStorage.deleteFile(allocator, io, thumbPath);

    //
    // Record the modification in the state file.
    //
    try tree.stampDatabaseModified(allocator, io, assetStorage, rawStorage);
}

//
// Returns true if the database at the given path is a partial replica (lazy database).
// Checks the isPartial flag stored in the merkle tree's database metadata.
// (Zig: s3Config and storageOptions are passed as null when absent.)
//
pub fn isDatabasePartial(allocator: std.mem.Allocator, io: std.Io, databasePath: []const u8, s3Config: ?storage_zig.cloud_storage.IS3Credentials, storageOptions: ?encryption.encryption_types.IStorageOptions) !bool {
    const created = try storage_zig.storage_factory.createStorage(allocator, io, databasePath, s3Config, storageOptions);
    const merkleTree = try tree.loadMerkleTree(allocator, io, created.storage);
    return merkleTree != null and isPartialDatabase(merkleTree.?.databaseMetadata);
}

//
// Creates storage for the given database path. If the database is a partial replica with a
// known origin, wraps the local storage in a LazyOriginStorage so that missing files are
// fetched from the origin and cached locally on first access.
// (Zig: resolveStorageCredentials is given null for its optional encryptionKey and s3Key, and the LazyOriginStorage is allocated
// with the allocator and keeps it.)
//
pub fn createLazyDatabaseStorage(allocator: std.mem.Allocator, io: std.Io, databasePath: []const u8, s3Config: ?storage_zig.cloud_storage.IS3Credentials, storageOptions: ?encryption.encryption_types.IStorageOptions, host: ?utils.native_caller.INativeCaller) !IStorage {
    const created = try storage_zig.storage_factory.createStorage(allocator, io, databasePath, s3Config, storageOptions);

    const config = try api.database_config.loadDatabaseConfig(allocator, io, created.rawStorage);
    const origin = configOrigin(config) orelse {
        return created.storage;
    };

    const merkleTree = try tree.loadMerkleTree(allocator, io, created.storage);
    if (merkleTree == null or !isPartialDatabase(merkleTree.?.databaseMetadata)) {
        return created.storage;
    }

    const credentials = try resolve_storage_credentials.resolveStorageCredentials(allocator, io, origin, null, null, host);
    const loadedKeys = try encryption.key_utils.loadEncryptionKeysFromPem(allocator, credentials.encryptionKeyPems);
    const originStorage = (try storage_zig.storage_factory.createStorage(allocator, io, origin, credentials.s3Config, loadedKeys.options)).storage;
    const lazyStorage = try allocator.create(LazyOriginStorage);
    lazyStorage.* = LazyOriginStorage.init(created.storage, originStorage);
    return lazyStorage.storage();
}

//
// Wraps an already-open local storage so that files a partial database does not hold are fetched
// from its origin. A full database, or one with no origin, is handed back unchanged.
//
// This exists alongside createLazyDatabaseStorage because a caller that has already opened the
// database (and resolved its encryption keys and S3 credentials) should not open it a second time
// just to add the wrapper.
//
// Reach for this only on a read path that wants the whole database, such as exporting an original
// that has been dropped locally. It must not be used for sync, replicate, repair or verify: those
// compare the local database against its origin, and a local read that falls back to the origin
// makes the two look identical when they are not.
//
pub fn openLazyOriginStorage(allocator: std.mem.Allocator, io: std.Io, localStorage: IStorage, localRawStorage: IStorage, host: ?utils.native_caller.INativeCaller) !IStorage {
    const config = try api.database_config.loadDatabaseConfig(allocator, io, localRawStorage);
    const origin = configOrigin(config) orelse {
        return localStorage;
    };

    const merkleTree = try tree.loadMerkleTree(allocator, io, localStorage);
    if (merkleTree == null or !isPartialDatabase(merkleTree.?.databaseMetadata)) {
        return localStorage;
    }

    const credentials = try resolve_storage_credentials.resolveStorageCredentials(allocator, io, origin, null, null, host);
    const loadedKeys = try encryption.key_utils.loadEncryptionKeysFromPem(allocator, credentials.encryptionKeyPems);
    const originStorage = (try storage_zig.storage_factory.createStorage(allocator, io, origin, credentials.s3Config, loadedKeys.options)).storage;
    const lazyStorage = try allocator.create(LazyOriginStorage);
    lazyStorage.* = LazyOriginStorage.init(localStorage, originStorage);
    return lazyStorage.storage();
}

//
// Gets `config?.origin` when it is a non-empty string, the only truthy origin a path can be made from.
//
fn configOrigin(config: ?std.json.Value) ?[]const u8 {
    const value = config orelse return null;
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const origin = object.get("origin") orelse return null;
    return switch (origin) {
        .string => |text| if (text.len > 0) text else null,
        else => null,
    };
}

//
// The operation checkDatabaseExists passes to retryOnce: it opens the storage of the database path and checks that the
// merkle tree exists.
//
const OpenAndCheckMerkleTreeOperation = struct {
    // The text that stands for this operation in the timeout message of retryOnce.
    pub const source =
        \\async () => {
        \\        const { storage } = await openStorage(databasePath);
        \\        return await merkleTreeExists(storage);
        \\    }
    ;

    // Allocates what opening the storage and checking it need.
    allocator: std.mem.Allocator,

    // The path of the database to look for.
    databasePath: []const u8,

    // Reaches the phone's keychain for the credentials, or null where there is no phone shell.
    host: ?utils.native_caller.INativeCaller,

    //
    // Opens the storage for the path and asks whether it holds a merkle tree.
    //
    pub fn run(self: *OpenAndCheckMerkleTreeOperation, io: std.Io) !bool {
        const opened = try open_storage.openStorage(self.allocator, io, self.databasePath, null, null, self.host);
        return tree.merkleTreeExists(self.allocator, io, opened.storage);
    }
};

//
// Returns true when a database exists at the given path. Works for any storage path (local
// filesystem, S3, network).
//
// This answers existence, not connectivity: it is reached through the check-database-exists task and
// its answer decides whether the app opens a database or tells the user there is none there. Whether
// an automatic sync may run is a separate question, decided by computeSyncAllowed from the platform's
// reported network status.
//
pub fn checkDatabaseExists(allocator: std.mem.Allocator, io: std.Io, databasePath: []const u8, host: ?utils.native_caller.INativeCaller) !bool {
    // Open storage the same way the load path does: openStorage resolves S3/encryption credentials
    // from the database's own config, so the existence check and the actual load agree on what is
    // reachable rather than probing with no credentials.
    //
    // Storage errors are deliberately NOT caught. A bucket that cannot be reached, a credential that
    // does not work and a DNS failure are all different from "there is no database here", and this
    // used to report every one of them as the latter: the app told the user their database was not
    // found when it simply could not get to it. Reaching the storage and finding no merkle tree is
    // the only thing that returns false.
    //
    // Bounded, because nothing else bounds it. One attempt, because this is a question a user is
    // waiting on the answer to rather than work worth retrying: the app tells them the database
    // cannot be reached, and pressing it again is the retry. Without the bound the wait fell through
    // to the S3 client's ten minute request ceiling, which is set for a phone pushing a large video
    // and leaves someone opening a database looking at a screen that never resolves. It only bites
    // where a connection is accepted and then answers nothing, which is what a phone reaching a
    // stopped server through an `adb reverse` forward gets, and is why this was invisible on an
    // emulator, where the same server refuses the connection at once.
    //
    // TypeScript races the check against a timer. A task runs only on its own thread, so here the S3 requests the check makes are
    // given the limit instead, and one that reaches it is cancelled.
    var operation: OpenAndCheckMerkleTreeOperation = .{
        .allocator = allocator,
        .databasePath = databasePath,
        .host = host,
    };
    storage_zig.s3_client.setRequestTimeout(DATABASE_REACHABLE_TIMEOUT);
    defer storage_zig.s3_client.setRequestTimeout(null);
    return retryOnce(io, &operation, DATABASE_REACHABLE_TIMEOUT) catch |err| {
        if (storage_zig.s3_client.takeRequestTimedOut()) {
            return errors.throwError("Operation timed out after {d}ms: {s}", .{ DATABASE_REACHABLE_TIMEOUT, OpenAndCheckMerkleTreeOperation.source });
        }
        return err;
    };
}

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
