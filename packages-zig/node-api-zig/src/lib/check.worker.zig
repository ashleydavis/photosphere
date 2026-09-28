//
// Check worker handler - handles file checking tasks
//

const std = @import("std");
const utils = @import("utils-zig");
const api = @import("api-zig");
const task_queue_zig = @import("task-queue-zig");
const hash_module = @import("hash.zig");
const hash_cache = @import("hash-cache.zig");
const file_scanner = @import("file-scanner.zig");
const media_file_database = @import("media-file-database.zig");
const open_storage = @import("open-storage.zig");
const ITaskContext = task_queue_zig.types.ITaskContext;
const IDatabaseDescriptor = api.database_descriptor.IDatabaseDescriptor;
const IFileStat = file_scanner.IFileStat;
const HashCache = hash_cache.HashCache;
const Date = utils.timestamp_provider.Date;
const validateAndHash = hash_module.validateAndHash;
const getHashFromCache = hash_module.getHashFromCache;
const createMediaFileDatabase = media_file_database.createMediaFileDatabase;
const openStorage = open_storage.openStorage;

//
// Payload for the check-file task.
//
pub const ICheckFileData = struct {
    // Actual file path (always a valid file, possibly temp file from zip)
    filePath: []const u8,

    // File size and modification time.
    fileStat: IFileStat,

    // MIME type of the file.
    contentType: []const u8,

    // Identifies the database the file is checked against.
    storageDescriptor: IDatabaseDescriptor,

    // Directory for the hash cache.
    hashCacheDir: []const u8,

    // Logical path for display (always set - equals filePath for non-zip files)
    logicalPath: []const u8,
};

//
// The hash of the checked file (TypeScript: the anonymous type of ICheckFileResult.hashedFile).
//
pub const ICheckHashedFile = struct {
    // hex string
    hash: []const u8,

    // ISO string
    lastModified: []const u8,

    // Length of the file in bytes.
    length: u64,
};

//
// Result returned by the check-file task.
//
pub const ICheckFileResult = struct {
    // The hash of the file, or undefined when it could not be hashed.
    // (The `= null` default lets std.json parse a result that leaves it out.)
    hashedFile: ?ICheckHashedFile = null,

    // How many database records have the same hash.
    matchingRecordsCount: u64,

    // true if hash was loaded from cache, false if computed
    hashFromCache: bool,
};

//
// Converts a result to the JSON value a task outputs. (No TypeScript counterpart: TypeScript returns the object.)
//
fn resultToJson(allocator: std.mem.Allocator, result: ICheckFileResult) !std.json.Value {
    const text = try std.json.Stringify.valueAlloc(allocator, result, .{
        .emit_null_optional_fields = false,
    });
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

//
// Handler for checking a single file
// Note: Hash cache is loaded read-only in workers. Saving is handled in the main thread.
// (Zig: the task data and output are JSON values holding ICheckFileData and ICheckFileResult.)
//
pub fn checkFileHandler(allocator: std.mem.Allocator, io: std.Io, taskData: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    const data = try std.json.parseFromValueLeaky(ICheckFileData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    });
    const filePath = data.filePath;
    const fileStat = data.fileStat;
    const contentType = data.contentType;
    const storageDescriptor = data.storageDescriptor;
    const hashCacheDir = data.hashCacheDir;
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;

    // Load hash cache (read-only)
    var localHashCache = try HashCache.init(hashCacheDir, true); // readonly = true
    defer localHashCache.deinit();
    _ = try localHashCache.load(io);

    // Check cache first
    // No cache identity: checking runs over real files, which are identified by their own paths.
    var hashedFile = try getHashFromCache(allocator, filePath, fileStat, &localHashCache, null);
    const hashFromCache = hashedFile != null;

    if (hashedFile == null) {
        // Not in cache - compute hash
        // filePath is always a valid file (already extracted if from zip)
        hashedFile = try validateAndHash(allocator, io, filePath, fileStat, contentType, data.logicalPath);
        if (hashedFile == null) {
            return resultToJson(allocator, .{
                .hashedFile = null,
                .matchingRecordsCount = 0,
                .hashFromCache = false,
            });
        }
    }

    // Recreate storage and metadata collection in the worker
    const opened = try openStorage(allocator, io, storageDescriptor.databasePath, storageDescriptor.encryptionKey, null);
    const database = try createMediaFileDatabase(allocator, opened.storage, uuidGenerator, timestampProvider);
    const metadataCollection = database.metadataCollection;

    // Check if file is already in database
    const localHashStr = try std.fmt.allocPrint(allocator, "{x}", .{hashedFile.?.hash});
    const records = try (try metadataCollection.sortIndex("hash", .asc)).findByValue(io, .{
        .string = localHashStr,
    }, null); //TODO: This is very slow, especially when the hash is not found.
    const matchingRecordsCount = records.len;

    const lastModified: Date = .{
        .epochMilliseconds = hashedFile.?.lastModified,
    };
    return resultToJson(allocator, .{
        .hashedFile = .{
            .hash = localHashStr,
            .lastModified = try lastModified.toISOString(allocator),
            .length = hashedFile.?.length,
        },
        .matchingRecordsCount = matchingRecordsCount,
        .hashFromCache = hashFromCache,
    });
}
