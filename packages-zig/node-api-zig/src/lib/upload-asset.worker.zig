//
// Upload-asset worker handler - uploads a single asset's files to storage and
// returns all data needed by the orchestrator to write the asset to the database.
//

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const api = @import("api-zig");
const storage_zig = @import("storage-zig");
const serialization_zig = @import("serialization-zig");
const task_queue_zig = @import("task-queue-zig");
const open_storage = @import("open-storage.zig");
const hash_module = @import("hash.zig");
const file_scanner = @import("file-scanner.zig");
const media_file_database = @import("media-file-database.zig");
const video = @import("video.zig");
const image = @import("image.zig");
const retry_operations = @import("retry-operations.zig");
const errors = utils.errors;
const log = &utils.log.log;
const retry = utils.retry.retry;
const ILocation = utils.reverse_geocode.ILocation;
const IReverseGeocodeResult = utils.reverse_geocode.IReverseGeocodeResult;
const reverseGeocode = utils.reverse_geocode.reverseGeocode;
const swallowError = utils.swallow_error.swallowError;
const path = node_utils.path;
const ensureDir = node_utils.fs.ensureDir;
const remove = node_utils.fs.remove;
const getProcessTmpDir = node_utils.fs.getProcessTmpDir;
const mathRandom = node_utils.fs.mathRandom;
const getEnv = node_utils.process_env.getEnv;
const IDatabaseDescriptor = api.database_descriptor.IDatabaseDescriptor;
const LARGE_FILE_TIMEOUT = api.constants.LARGE_FILE_TIMEOUT;
const IStorage = storage_zig.storage.IStorage;
const IFileInfo = storage_zig.storage.IFileInfo;
const bson = serialization_zig.bson;
const BsonDocument = bson.BsonDocument;
const BsonValue = bson.BsonValue;
const jsonParse = serialization_zig.json_parse.jsonParse;
const js_date = serialization_zig.js_date;
const ITaskContext = task_queue_zig.types.ITaskContext;
const openStorage = open_storage.openStorage;
const computeFileHash = hash_module.computeFileHash;
const getNativeFileHasher = hash_module.getNativeFileHasher;
const IFileStat = file_scanner.IFileStat;
const IAssetDetails = media_file_database.IAssetDetails;
const extractDominantColorFromThumbnail = media_file_database.extractDominantColorFromThumbnail;
const getVideoDetails = video.getVideoDetails;
const getImageDetails = image.getImageDetails;
const InfoOperation = retry_operations.InfoOperation;

//
// Payload for the upload-asset task.
// (The `= null` defaults let std.json parse task data that leaves the optional keys out.)
//
pub const IUploadAssetData = struct {
    // Actual path to the file (e.g. temp file when importing from zip).
    filePath: []const u8,

    // File size and modification time.
    fileStat: IFileStat,

    // MIME type of the file.
    contentType: []const u8,

    // Identifies the target database and optional encryption key name.
    storageDescriptor: IDatabaseDescriptor,

    // Path used in UI (e.g. path inside a zip).
    logicalPath: []const u8,

    // ID to use for this asset.
    assetId: []const u8,

    // Labels to attach to the asset (e.g. folder hierarchy).
    labels: []const []const u8,

    // Google Maps API key for reverse geocoding (optional).
    googleApiKey: ?[]const u8 = null,

    // Unique identifier for the session.
    sessionId: []const u8,

    // When true, files are scanned and hashed but not written to the database.
    dryRun: ?bool = null,

    // Pre-computed SHA-256 hash of the file content, supplied by the orchestrator.
    // (Zig: hex encoded, because task data is JSON; TypeScript posts a Uint8Array.)
    expectedHash: []const u8,
};

//
// All data the orchestrator needs to write a single asset to the database.
// (Zig: dates are milliseconds since the epoch, and the asset record is carried as the base64 of its BSON
// serialization, because task outputs are JSON and JSON cannot tell the record's number and date types apart.)
//
pub const IAssetDatabaseData = struct {
    // ID used for asset/thumb/display storage paths.
    assetId: []const u8,

    // Storage path of the original asset file.
    assetPath: []const u8,

    // Hex-encoded SHA-256 hash of the uploaded asset.
    assetHash: []const u8,

    // Byte length of the uploaded asset.
    assetLength: u64,

    // Last-modified date of the uploaded asset.
    assetLastModified: i64,

    // Storage path of the thumbnail (optional).
    thumbPath: ?[]const u8 = null,

    // Hex-encoded SHA-256 hash of the thumbnail (optional).
    thumbHash: ?[]const u8 = null,

    // Byte length of the thumbnail (optional).
    thumbLength: ?u64 = null,

    // Last-modified date of the thumbnail (optional).
    thumbLastModified: ?i64 = null,

    // Storage path of the display version (optional).
    displayPath: ?[]const u8 = null,

    // Hex-encoded SHA-256 hash of the display version (optional).
    displayHash: ?[]const u8 = null,

    // Byte length of the display version (optional).
    displayLength: ?u64 = null,

    // Last-modified date of the display version (optional).
    displayLastModified: ?i64 = null,

    // Full metadata record ready for metadataCollection.insertOne().
    assetRecord: []const u8,
};

//
// Result returned by the upload-asset task.
//
pub const IUploadAssetResult = struct {
    // All data needed by the orchestrator to write this asset to the database.
    assetData: IAssetDatabaseData,

    // Total byte size of all uploaded files (asset + thumb + display).
    totalSize: u64,

    // How long this task took in total, in milliseconds: the metadata, the thumbnail and display
    // versions, and the uploads. The import sums it alongside the hashing tasks so the two can be
    // compared, which is the whole question when hashing is made faster.
    taskMs: f64,

    // How long reading the item's own metadata took. For a video this includes extracting the frame
    // the thumbnail is made from, which is the expensive part of taking a video in.
    metadataMs: f64,

    // How long each of the three derivative images took to produce.
    microMs: f64,
    thumbnailMs: f64,
    displayMs: f64,

    // How long writing the original and its derivatives into storage took.
    uploadMs: f64,

    // How long reverse geocoding took, zero when the item carried no coordinates or no key is set.
    geocodeMs: f64,

    // How long working out the dominant colour took.
    dominantColorMs: f64,

    // Time this task spent on things none of the counters above name. Reported rather than left to
    // be inferred: the counters accounted for a fifth of the child task time, and a gap that large
    // is the most important number in the measurement.
    otherMs: f64,

    // Opening storage, which every one of these tasks does before it can write anything.
    openStorageMs: f64,

    // Asking the media tool for the image dimensions, which spawns it once per file.
    probeMs: f64,

    // Whether this item was a video rather than a photo.
    isVideo: bool,
};

//
// Encodes an asset record the way IAssetDatabaseData carries it: the base64 of its BSON serialization.
// (No TypeScript counterpart: TypeScript posts the record itself.)
//
pub fn encodeAssetRecord(allocator: std.mem.Allocator, assetRecord: BsonDocument) ![]const u8 {
    const serialized = try bson.serialize(allocator, assetRecord);
    const encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, encoder.calcSize(serialized.len));
    return encoder.encode(encoded, serialized);
}

//
// Decodes an asset record carried by IAssetDatabaseData. (No TypeScript counterpart.)
//
pub fn decodeAssetRecord(allocator: std.mem.Allocator, encoded: []const u8) !BsonDocument {
    const decoder = std.base64.standard.Decoder;
    const serialized = try allocator.alloc(u8, try decoder.calcSizeForSlice(encoded));
    try decoder.decode(serialized, encoded);
    return bson.deserialize(allocator, serialized);
}

//
// `Date.now()`. (No TypeScript counterpart.)
//
fn dateNow(io: std.Io) f64 {
    return @floatFromInt(std.Io.Clock.real.now(io).toMilliseconds());
}

//
// `dayjs(time).toISOString()` for a date held as milliseconds. (No TypeScript counterpart.)
//
fn toISOString(allocator: std.mem.Allocator, time: i64) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    try js_date.writeIsoString(&output.writer, time);
    return output.written();
}

//
// `() => storage.writeStream(filePath, contentType, createReadStream(localPath), contentLength)`.
// (No TypeScript counterpart: the arrow functions passed to retry.)
//
fn WriteFileStreamOperation(comptime sourceText: []const u8) type {
    return struct {
        // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
        pub const source = sourceText;

        // Allocates the storage implementation's temporary data.
        allocator: std.mem.Allocator,

        // The storage to write to.
        storage: IStorage,

        // The path written in storage.
        filePath: []const u8,

        // The content type of the file.
        contentType: ?[]const u8,

        // The local file streamed into storage.
        localPath: []const u8,

        // The length of the local file, when the caller gives it.
        contentLength: ?u64,

        //
        // Streams the local file into storage.
        //
        pub fn run(self: *@This(), io: std.Io) !void {
            const file = std.Io.Dir.cwd().openFile(io, self.localPath, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    return errors.throwError("ENOENT: no such file or directory, open '{s}'", .{self.localPath});
                }
                return err;
            };
            defer file.close(io);
            var readBuffer: [64 * 1024]u8 = undefined;
            var fileReader = file.reader(io, &readBuffer);
            try self.storage.writeStream(self.allocator, io, self.filePath, self.contentType, &fileReader.interface, self.contentLength);
        }
    };
}

//
// `() => computeFileHash(localPath, getNativeFileHasher())`.
//
fn ComputeFileHashOperation(comptime sourceText: []const u8) type {
    return struct {
        // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
        pub const source = sourceText;

        // Allocates the hash.
        allocator: std.mem.Allocator,

        // The file to hash.
        localPath: []const u8,

        //
        // Hashes the file.
        //
        pub fn run(self: *@This(), io: std.Io) ![]const u8 {
            return computeFileHash(self.allocator, io, self.localPath, getNativeFileHasher());
        }
    };
}

//
// `() => reverseGeocode(assetDetails.coordinates!, googleApiKey)`.
//
const ReverseGeocodeOperation = struct {
    // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
    pub const source = "() => reverseGeocode(assetDetails.coordinates, googleApiKey)";

    // Allocates the result.
    allocator: std.mem.Allocator,

    // Where the asset was taken.
    coordinates: ILocation,

    // The Google API key.
    googleApiKey: []const u8,

    //
    // Looks the location up.
    //
    pub fn run(self: *@This(), io: std.Io) !?IReverseGeocodeResult {
        return reverseGeocode(self.allocator, io, self.coordinates, self.googleApiKey);
    }
};

//
// `() => fs.readFile(assetDetails.microPath)`.
//
const ReadMicroOperation = struct {
    // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
    pub const source = "() => fs.readFile(assetDetails.microPath)";

    // Allocates the contents.
    allocator: std.mem.Allocator,

    // The file to read.
    localPath: []const u8,

    //
    // Reads the file.
    //
    pub fn run(self: *@This(), io: std.Io) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(io, self.localPath, self.allocator, .unlimited);
    }
};

//
// `() => storage.deleteFile(filePath)`.
//
fn DeleteFileOperation(comptime sourceText: []const u8) type {
    return struct {
        // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
        pub const source = sourceText;

        // Allocates the storage implementation's temporary data.
        allocator: std.mem.Allocator,

        // The storage to delete from.
        storage: IStorage,

        // The file to delete.
        filePath: []const u8,

        //
        // Deletes the file.
        //
        pub fn run(self: *@This(), io: std.Io) !void {
            try self.storage.deleteFile(self.allocator, io, self.filePath);
        }
    };
}

//
// `() => remove(assetTempDir)`.
//
const RemoveDirOperation = struct {
    // The directory to remove.
    dirPath: []const u8,

    //
    // Removes the directory.
    //
    pub fn run(self: *@This(), io: std.Io) !void {
        try remove(io, self.dirPath);
    }
};

//
// The labels of an asset: the task's own followed by every part of the directory the file is in
// (TypeScript: `data.labels.concat(fileDir.replace(/\\/g, "/").split("/").filter(label => label))`).
//
fn buildLabels(allocator: std.mem.Allocator, labels: []const []const u8, fileDir: []const u8) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    try result.appendSlice(allocator, labels);
    const normalized = try allocator.dupe(u8, fileDir);
    std.mem.replaceScalar(u8, normalized, '\\', '/');
    var parts = std.mem.splitScalar(u8, normalized, '/');
    while (parts.next()) |label| {
        if (label.len > 0) {
            try result.append(allocator, label);
        }
    }
    return result.items;
}

//
// Converts a string list to a BSON array. (No TypeScript counterpart.)
//
fn stringArray(allocator: std.mem.Allocator, strings: []const []const u8) ![]BsonValue {
    const values = try allocator.alloc(BsonValue, strings.len);
    for (strings, 0..) |text, index| {
        values[index] = .{ .string = text };
    }
    return values;
}

//
// Handler for uploading a single asset. Extracts metadata, uploads files to storage,
// and returns all data needed by the orchestrator for the database write.
// Does NOT write to the database or acquire the write lock.
// (Zig: the task data and output are JSON values holding IUploadAssetData and IUploadAssetResult; undefined is
// JSON null.)
//
pub fn uploadAssetHandler(allocator: std.mem.Allocator, io: std.Io, taskData: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    if (context.isCancelled()) {
        return .null;
    }

    const data = try std.json.parseFromValueLeaky(IUploadAssetData, allocator, taskData, .{ .ignore_unknown_fields = true });

    var pendingMessage: std.json.ObjectMap = .empty;
    try pendingMessage.put(allocator, "type", .{ .string = "import-pending" });
    try pendingMessage.put(allocator, "assetId", .{ .string = data.assetId });
    try pendingMessage.put(allocator, "logicalPath", .{ .string = data.logicalPath });
    context.sendMessage(.{ .object = pendingMessage });

    // When this task started, so the import can report what the work other than hashing cost.
    const taskStartedAt = dateNow(io);

    // Where this task's time goes, gathered as it goes so the import can rank its stages.
    var uploadMs: f64 = 0;
    var geocodeMs: f64 = 0;
    var dominantColorMs: f64 = 0;

    const filePath = data.filePath;
    // (Zig: fileStat is read by uploadAndDescribe, which is handed the data.)
    const contentType = data.contentType;
    const storageDescriptor = data.storageDescriptor;
    const googleApiKey = data.googleApiKey;
    const dryRun = data.dryRun orelse false;
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;

    const assetId = data.assetId;
    log.verbose(try std.fmt.allocPrint(allocator, "Importing file {s} to asset database with asset id {s}", .{ data.logicalPath, assetId }));

    const expectedHashBuffer = try allocator.alloc(u8, data.expectedHash.len / 2);
    _ = try std.fmt.hexToBytes(expectedHashBuffer, data.expectedHash);

    const openStorageStartedAt = dateNow(io);
    const opened = try openStorage(allocator, io, storageDescriptor.databasePath, storageDescriptor.encryptionKey, null);
    const storage = opened.storage;
    const openStorageMs = dateNow(io) - openStorageStartedAt;

    const assetTempDir = try path.join(allocator, &.{ try getProcessTmpDir(allocator, io), "photosphere", "assets", try uuidGenerator.generate(allocator, io) });
    try ensureDir(io, assetTempDir);

    const fileDisplayPath = data.logicalPath;

    defer {
        var removeOperation: RemoveDirOperation = .{
            .dirPath = assetTempDir,
        };
        _ = swallowError(io, &removeOperation);
    }

    var assetDetails: ?IAssetDetails = null;

    // filePath is always a valid file (already extracted if from zip)
    //TODO: We should be able to get this information from the validation phase instead of getting it again here.
    if (std.mem.startsWith(u8, contentType, "video")) {
        assetDetails = try getVideoDetails(allocator, io, filePath, assetTempDir, contentType, uuidGenerator, data.logicalPath);
    }
    else if (std.mem.startsWith(u8, contentType, "image")) {
        assetDetails = try getImageDetails(allocator, io, filePath, assetTempDir, contentType, uuidGenerator, data.logicalPath);
    }

    const assetPath = try std.fmt.allocPrint(allocator, "asset/{s}", .{assetId});
    const thumbPath = try std.fmt.allocPrint(allocator, "thumb/{s}", .{assetId});
    const displayPath = try std.fmt.allocPrint(allocator, "display/{s}", .{assetId});

    if (getEnv("SIMULATE_FAILURE")) |simulateFailure| {
        if (std.mem.eql(u8, simulateFailure, "add-file") and mathRandom(io) < 0.1) {
            return errors.throwError("Simulated failure during add-file operation for {s}", .{fileDisplayPath});
        }
    }

    const uploaded = uploadAndDescribe(allocator, io, data, context, assetDetails, storage, expectedHashBuffer, assetPath, thumbPath, displayPath, dryRun, googleApiKey, timestampProvider.dateNow(io).epochMilliseconds, &uploadMs, &geocodeMs, &dominantColorMs) catch |err| {
        log.exception(try std.fmt.allocPrint(allocator, "Error importing file {s} ({s})", .{ filePath, assetId }), err);
        var failedMessage: std.json.ObjectMap = .empty;
        try failedMessage.put(allocator, "type", .{ .string = "import-failed" });
        try failedMessage.put(allocator, "assetId", .{ .string = data.assetId });
        try failedMessage.put(allocator, "logicalPath", .{ .string = data.logicalPath });
        context.sendMessage(.{ .object = failedMessage });

        // Clean up uploaded files on error, then let exception propagate to task queue
        var deleteAssetOperation: DeleteFileOperation("() => storage.deleteFile(assetPath)") = .{
            .allocator = allocator,
            .storage = storage,
            .filePath = assetPath,
        };
        try retry(io, &deleteAssetOperation, 3, 1_000, 2, 30_000, null);
        var deleteThumbOperation: DeleteFileOperation("() => storage.deleteFile(thumbPath)") = .{
            .allocator = allocator,
            .storage = storage,
            .filePath = thumbPath,
        };
        try retry(io, &deleteThumbOperation, 3, 1_000, 2, 30_000, null);
        var deleteDisplayOperation: DeleteFileOperation("() => storage.deleteFile(displayPath)") = .{
            .allocator = allocator,
            .storage = storage,
            .filePath = displayPath,
        };
        try retry(io, &deleteDisplayOperation, 3, 1_000, 2, 30_000, null);
        return err;
    };

    const assetData = uploaded orelse {
        return .null;
    };

    log.verbose(if (dryRun)
        try std.fmt.allocPrint(allocator, "[DRY RUN] Would add file \"{s}\" to the database with ID \"{s}\".", .{ data.logicalPath, assetId })
    else
        try std.fmt.allocPrint(allocator, "Uploaded file \"{s}\" with ID \"{s}\".", .{ data.logicalPath, assetId }));

    const timings = if (assetDetails) |details| details.detailTimings else media_file_database.IAssetDetailTimings{};
    const totalSize = assetData.assetLength + (assetData.thumbLength orelse 0) + (assetData.displayLength orelse 0);
    const result: IUploadAssetResult = .{
        .assetData = assetData,
        .totalSize = totalSize,
        .taskMs = dateNow(io) - taskStartedAt,
        .metadataMs = timings.metadataMs,
        .microMs = timings.microMs,
        .thumbnailMs = timings.thumbnailMs,
        .displayMs = timings.displayMs,
        .uploadMs = uploadMs,
        .geocodeMs = geocodeMs,
        .dominantColorMs = dominantColorMs,
        .openStorageMs = openStorageMs,
        .probeMs = timings.probeMs,
        .otherMs = @max(0, (dateNow(io) - taskStartedAt) - (timings.probeMs + timings.metadataMs + timings.microMs + timings.thumbnailMs + timings.displayMs + uploadMs + geocodeMs + dominantColorMs + openStorageMs)),
        .isVideo = std.mem.startsWith(u8, contentType, "video"),
    };
    const text = try std.json.Stringify.valueAlloc(allocator, result, .{ .emit_null_optional_fields = false });
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

//
// The body of uploadAssetHandler's inner try block: uploads the asset and its derivatives and builds the
// record, or returns undefined (null) when the task is cancelled part way.
// (No TypeScript counterpart: the try block is written inline; Zig needs it as a function to catch its errors.)
//
fn uploadAndDescribe(
    allocator: std.mem.Allocator,
    io: std.Io,
    data: IUploadAssetData,
    context: ITaskContext,
    assetDetails: ?IAssetDetails,
    storage: IStorage,
    expectedHashBuffer: []const u8,
    assetPath: []const u8,
    thumbPath: []const u8,
    displayPath: []const u8,
    dryRun: bool,
    googleApiKey: ?[]const u8,
    uploadDateNow: i64,
    uploadMs: *f64,
    geocodeMs: *f64,
    dominantColorMs: *f64,
) !?IAssetDatabaseData {
    const filePath = data.filePath;
    const fileStat = data.fileStat;
    const contentType = data.contentType;
    const assetId = data.assetId;

    var hashedAssetLength: u64 = undefined;
    var hashedAssetLastModified: i64 = undefined;

    // Upload files (no database writes here - that's done in main thread)
    // filePath is always a valid file (already extracted if from zip)
    if (dryRun) {
        // Mock hashed asset.
        hashedAssetLength = fileStat.length;
        hashedAssetLastModified = fileStat.lastModified;
    }
    else {
        const assetUploadStartedAt = dateNow(io);
        var writeOperation: WriteFileStreamOperation("() => storage.writeStream(assetPath, contentType, createReadStream(filePath), fileStat.length)") = .{
            .allocator = allocator,
            .storage = storage,
            .filePath = assetPath,
            .contentType = contentType,
            .localPath = filePath,
            .contentLength = fileStat.length,
        };
        try retry(io, &writeOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, null);
        uploadMs.* += dateNow(io) - assetUploadStartedAt;

        var infoOperation: InfoOperation("() => storage.info(assetPath)") = .{
            .allocator = allocator,
            .storage = storage,
            .fileName = assetPath,
        };
        const assetInfo = try retry(io, &infoOperation, 3, 1_000, 2, 30_000, null) orelse {
            return errors.throwError("Failed to get info for file {s} ({s})", .{ assetPath, assetId });
        };

        // The stored copy is not read back to learn its hash. The hash is the one the
        // import already has for this file, taken natively from the file on disk before
        // anything was written, and the thumbnail and display below are hashed the same way
        // from the files they were made into.
        //
        // Reading the copy back was the unaccounted half of every import into an encrypted
        // database. A stream out of an encrypted store has no file behind it, so the native
        // hasher could not be used and the bytes were decrypted and hashed in the engine's
        // own JavaScript instead, at about a fifth of a megabyte a second on a Pixel 6: a
        // photo spent seven seconds being written and seven more being read back, and one
        // 87MB video spent seven and a half minutes on each. Measured across 46 photos and
        // videos, the read-back was as long as the write it was checking.
        //
        // What a store can say about the copy without reading it, it is asked. One that hands
        // out what it holds is checked by length, and one that cannot say how long its copy
        // reads (an encrypted store) is not checked here at all, which is the same trust the
        // sync places in a store that cannot verify a write. `psi verify` is the deep check.
        const storedLength = storage.readableLength(assetInfo);
        if (storedLength != null and storedLength.? != fileStat.length) {
            return errors.throwError("Wrote {d} bytes to {s} ({s}) and the store holds {d}.", .{ fileStat.length, assetPath, assetId, storedLength.? });
        }

        hashedAssetLength = assetInfo.length;
        hashedAssetLastModified = assetInfo.lastModified;
    }

    if (context.isCancelled()) {
        return null;
    }

    var thumbHash: ?[]const u8 = null;
    var thumbLength: ?u64 = null;
    var thumbLastModified: ?i64 = null;

    if (assetDetails) |details| {
        if (dryRun) {
            // Mock hashed thumbnail.
            thumbHash = expectedHashBuffer;
            thumbLength = fileStat.length;
            thumbLastModified = fileStat.lastModified;
        }
        else {
            const thumbUploadStartedAt = dateNow(io);
            var writeOperation: WriteFileStreamOperation("() => storage.writeStream(thumbPath, assetDetails.thumbnailContentType, createReadStream(assetDetails.thumbnailPath))") = .{
                .allocator = allocator,
                .storage = storage,
                .filePath = thumbPath,
                .contentType = details.thumbnailContentType,
                .localPath = details.thumbnailPath,
                .contentLength = null,
            };
            try retry(io, &writeOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, null);
            uploadMs.* += dateNow(io) - thumbUploadStartedAt;

            var infoOperation: InfoOperation("() => storage.info(thumbPath)") = .{
                .allocator = allocator,
                .storage = storage,
                .fileName = thumbPath,
            };
            const thumbInfo = try retry(io, &infoOperation, 3, 1_000, 2, 30_000, null) orelse {
                return errors.throwError("Failed to get info for thumbnail {s} ({s})", .{ thumbPath, assetId });
            };
            // Hashed from the file it was made into, natively where there is a native
            // hasher, rather than read back out of the store: see the asset above.
            var hashOperation: ComputeFileHashOperation("() => computeFileHash(assetDetails.thumbnailPath, getNativeFileHasher())") = .{
                .allocator = allocator,
                .localPath = details.thumbnailPath,
            };
            thumbHash = try retry(io, &hashOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, null);
            thumbLength = thumbInfo.length;
            thumbLastModified = thumbInfo.lastModified;
        }
    }

    if (context.isCancelled()) {
        return null;
    }

    var displayHash: ?[]const u8 = null;
    var displayLength: ?u64 = null;
    var displayLastModified: ?i64 = null;

    if (assetDetails != null and assetDetails.?.displayPath != null) {
        const details = assetDetails.?;
        if (dryRun) {
            // Mock hashed display.
            displayHash = expectedHashBuffer;
            displayLength = fileStat.length;
            displayLastModified = fileStat.lastModified;
        }
        else {
            const displayUploadStartedAt = dateNow(io);
            var writeOperation: WriteFileStreamOperation("() => storage.writeStream(displayPath, assetDetails.displayContentType, createReadStream(assetDetails.displayPath))") = .{
                .allocator = allocator,
                .storage = storage,
                .filePath = displayPath,
                .contentType = details.displayContentType,
                .localPath = details.displayPath.?,
                .contentLength = null,
            };
            try retry(io, &writeOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, null);
            uploadMs.* += dateNow(io) - displayUploadStartedAt;

            var infoOperation: InfoOperation("() => storage.info(displayPath)") = .{
                .allocator = allocator,
                .storage = storage,
                .fileName = displayPath,
            };
            const displayInfo = try retry(io, &infoOperation, 3, 1_000, 2, 30_000, null) orelse {
                return errors.throwError("Failed to get info for display {s} ({s})", .{ displayPath, assetId });
            };
            // Hashed from the file it was made into, for the same reason as the thumbnail.
            var hashOperation: ComputeFileHashOperation("() => computeFileHash(assetDetails.displayPath, getNativeFileHasher())") = .{
                .allocator = allocator,
                .localPath = details.displayPath.?,
            };
            displayHash = try retry(io, &hashOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, null);
            displayLength = displayInfo.length;
            displayLastModified = displayInfo.lastModified;
        }
    }

    // Prepare metadata for database insert (done in main thread)
    var properties: BsonDocument = .empty;
    if (assetDetails != null and assetDetails.?.metadata != null) {
        try properties.put(allocator, "metadata", assetDetails.?.metadata.?);
    }

    if (context.isCancelled()) {
        return null;
    }

    var coordinates: ?ILocation = null;
    var location: ?[]const u8 = null;
    if (assetDetails != null and assetDetails.?.coordinates != null) {
        coordinates = assetDetails.?.coordinates;
        if (googleApiKey != null and googleApiKey.?.len > 0) {
            const geocodeStartedAt = dateNow(io);
            var geocodeOperation: ReverseGeocodeOperation = .{
                .allocator = allocator,
                .coordinates = assetDetails.?.coordinates.?,
                .googleApiKey = googleApiKey.?,
            };
            const reverseGeocodingResult = try retry(io, &geocodeOperation, 3, 1500, 2, 30_000, null);
            geocodeMs.* += dateNow(io) - geocodeStartedAt;
            if (reverseGeocodingResult) |geocoded| {
                location = geocoded.location;
                const fullResult = try jsonParse(allocator, try std.json.Stringify.valueAlloc(allocator, geocoded.fullResult, .{}));
                try properties.put(allocator, "reverseGeocoding", .{
                    .document = try BsonDocument.fromFields(allocator, &.{
                        .{
                            .key = "type",
                            .value = .{ .string = geocoded.type },
                        },
                        .{
                            .key = "fullResult",
                            .value = fullResult,
                        },
                    }),
                });
            }
        }
    }

    const fileDir = path.dirname(filePath);
    const labels = try buildLabels(allocator, data.labels, fileDir);

    if (context.isCancelled()) {
        return null;
    }

    const description = "";
    var micro: ?[]const u8 = null;
    if (assetDetails) |details| {
        var readOperation: ReadMicroOperation = .{
            .allocator = allocator,
            .localPath = details.microPath,
        };
        const microBytes = try retry(io, &readOperation, 3, 1_000, 2, 30_000, null);
        const encoder = std.base64.standard.Encoder;
        const encoded = try allocator.alloc(u8, encoder.calcSize(microBytes.len));
        micro = encoder.encode(encoded, microBytes);
    }

    const dominantColorStartedAt = dateNow(io);
    const color: ?[3]f64 = if (assetDetails) |details|
        try extractDominantColorFromThumbnail(allocator, io, details.thumbnailPath)
    else
        null;
    dominantColorMs.* = dateNow(io) - dominantColorStartedAt;

    const colorValues = try allocator.alloc(BsonValue, 3);
    const resolvedColor = color orelse [3]f64{ 0, 0, 0 };
    for (resolvedColor, 0..) |component, index| {
        colorValues[index] = .{ .number = component };
    }

    const fileDate = try toISOString(allocator, fileStat.lastModified);
    const photoDate: []const u8 = if (assetDetails != null and assetDetails.?.photoDate != null and assetDetails.?.photoDate.?.len > 0)
        assetDetails.?.photoDate.?
    else
        fileDate;

    const coordinatesValue: BsonValue = if (coordinates) |coordinate|
        .{
            .document = try BsonDocument.fromFields(allocator, &.{
                .{
                    .key = "lat",
                    .value = .{ .number = coordinate.lat },
                },
                .{
                    .key = "lng",
                    .value = .{ .number = coordinate.lng },
                },
            }),
        }
    else
        .undefined;

    const durationValue: BsonValue = if (assetDetails != null and assetDetails.?.duration != null) .{ .number = assetDetails.?.duration.? } else .undefined;

    const assetRecord = try BsonDocument.fromFields(allocator, &.{
        .{
            .key = "_id",
            .value = .{ .string = assetId },
        },
        .{
            .key = "width",
            .value = .{ .number = if (assetDetails) |details| details.resolution.width else 0 },
        },
        .{
            .key = "height",
            .value = .{ .number = if (assetDetails) |details| details.resolution.height else 0 },
        },
        .{
            .key = "origFileName",
            .value = .{ .string = path.basename(filePath) },
        },
        .{
            .key = "origPath",
            .value = .{ .string = fileDir },
        },
        .{
            .key = "contentType",
            .value = .{ .string = contentType },
        },
        .{
            .key = "hash",
            .value = .{ .string = try std.fmt.allocPrint(allocator, "{x}", .{expectedHashBuffer}) },
        },
        .{
            .key = "coordinates",
            .value = coordinatesValue,
        },
        .{
            .key = "location",
            .value = if (location) |text| .{ .string = text } else .undefined,
        },
        .{
            .key = "duration",
            .value = durationValue,
        },
        .{
            .key = "fileDate",
            .value = .{ .string = fileDate },
        },
        .{
            .key = "photoDate",
            .value = .{ .string = photoDate },
        },
        .{
            .key = "uploadDate",
            .value = .{ .string = try toISOString(allocator, uploadDateNow) },
        },
        .{
            .key = "properties",
            .value = .{ .document = properties },
        },
        .{
            .key = "labels",
            .value = .{ .array = try stringArray(allocator, labels) },
        },
        .{
            .key = "description",
            .value = .{ .string = description },
        },
        .{
            .key = "micro",
            .value = .{ .string = micro orelse "" },
        },
        .{
            .key = "color",
            .value = .{ .array = colorValues },
        },
    });

    return .{
        .assetId = assetId,
        .assetPath = assetPath,
        .assetHash = try std.fmt.allocPrint(allocator, "{x}", .{expectedHashBuffer}),
        .assetLength = hashedAssetLength,
        .assetLastModified = hashedAssetLastModified,
        .thumbPath = if (assetDetails != null) thumbPath else null,
        .thumbHash = if (thumbHash) |hash| try std.fmt.allocPrint(allocator, "{x}", .{hash}) else null,
        .thumbLength = thumbLength,
        .thumbLastModified = thumbLastModified,
        .displayPath = if (assetDetails != null and assetDetails.?.displayPath != null) displayPath else null,
        .displayHash = if (displayHash) |hash| try std.fmt.allocPrint(allocator, "{x}", .{hash}) else null,
        .displayLength = displayLength,
        .displayLastModified = displayLastModified,
        .assetRecord = try encodeAssetRecord(allocator, assetRecord),
    };
}
