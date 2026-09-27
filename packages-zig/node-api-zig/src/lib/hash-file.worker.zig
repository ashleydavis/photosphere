const std = @import("std");
const utils = @import("utils-zig");
const api = @import("api-zig");
const task_queue_zig = @import("task-queue-zig");
const hash_cache = @import("hash-cache.zig");
const hash_module = @import("hash.zig");
const file_scanner = @import("file-scanner.zig");
const errors = utils.errors;
const ITaskContext = task_queue_zig.types.ITaskContext;
const IDatabaseDescriptor = api.database_descriptor.IDatabaseDescriptor;
const IFileCacheIdentity = api.import_assets_types.IFileCacheIdentity;
const IFileStat = file_scanner.IFileStat;
const loadSharedHashCache = hash_cache.loadSharedHashCache;
const getHashFromCache = hash_module.getHashFromCache;
const validateAndHash = hash_module.validateAndHash;

//
// Payload for the hash-file task. Contains everything needed to compute the content
// hash of a file and check whether it already exists in the database.
// (The `= null` defaults let std.json parse task data that leaves the optional keys out.)
//
pub const IHashFileData = struct {
    // Actual path to the file on disk.
    filePath: []const u8,

    // File size and modification time.
    fileStat: IFileStat,

    // MIME type of the file.
    contentType: []const u8,

    // Identifies the target database and encryption key name.
    storageDescriptor: IDatabaseDescriptor,

    // Directory for the hash cache.
    hashCacheDir: []const u8,

    // How this file is identified in the hash cache, when it is not identified by its own path.
    // Only automatic import from a device photo library supplies one. See IFileCacheIdentity.
    cacheIdentity: ?IFileCacheIdentity = null,

    // Path used in UI (e.g. path inside a zip).
    logicalPath: []const u8,

    // Labels to attach to the asset (e.g. folder hierarchy).
    labels: []const []const u8,

    // Google Maps API key for reverse geocoding (optional).
    googleApiKey: ?[]const u8 = null,

    // Unique identifier for the session.
    sessionId: []const u8,

    // When true, files are scanned and hashed but not written to the database.
    dryRun: bool,

    // ID to use for this asset if it is imported.
    assetId: []const u8,
};

//
// Result returned by the hash-file task.
//
pub const IHashFileResult = struct {
    // SHA-256 hash bytes of the file content.
    // (Zig: hex encoded, because task outputs are JSON; TypeScript posts a Uint8Array.)
    hash: []const u8,

    // True if the hash was retrieved from the local cache (not freshly computed).
    hashFromCache: bool,

    // How long the hashing itself took, in milliseconds. Zero when the cache answered, because then
    // nothing was hashed. The import sums this across every file so hashing can be accounted for
    // separately from everything else the import does.
    hashMs: i64,

    // How long asking the hash cache took, in milliseconds, whether it answered or not.
    cacheLookupMs: i64,

    // How long this task took in total, in milliseconds. The import sums this so hashing can be
    // reported as a share of the work the child tasks did, rather than of the run's wall clock,
    // which several tasks are running inside at once.
    taskMs: i64,

    // How long loading the hash cache took. Every one of these tasks loads the whole cache from disk
    // before it can ask about one file, and the cache grows as the import runs.
    cacheLoadMs: i64,

    // How many bytes were hashed: the file's length when it was hashed, zero when the cache answered.
    bytesHashed: u64,
};

//
// `Date.now()`. (No TypeScript counterpart.)
//
fn dateNow(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}

//
// Handler for the hash-file task. Computes the SHA-256 hash of a file, or takes it from the local
// hash cache. Says nothing about the database and queues nothing; the orchestrator (import-assets)
// does both.
// (Zig: the task data and output are JSON values holding IHashFileData and IHashFileResult.)
//
pub fn hashFileHandler(allocator: std.mem.Allocator, io: std.Io, taskData: std.json.Value, context: ITaskContext) anyerror!std.json.Value {
    _ = context;
    const data = try std.json.parseFromValueLeaky(IHashFileData, allocator, taskData, .{ .ignore_unknown_fields = true });
    const filePath = data.filePath;
    const fileStat = data.fileStat;
    const contentType = data.contentType;
    const hashCacheDir = data.hashCacheDir;
    const logicalPath = data.logicalPath;
    const cacheIdentity = data.cacheIdentity;

    // When this task started, so the whole of it can be reported alongside the part of it that was
    // hashing. Read here rather than in the caller because the caller only sees when the task was
    // queued, which on a busy import is a different thing entirely.
    const taskStartedAt = dateNow(io);

    // The hash cache, read-only and shared with every other file this engine hashes: reading it is
    // proportional to how much is in it, and this task used to read the whole thing per file.
    const cacheLoadStartedAt = dateNow(io);
    const localHashCache = try loadSharedHashCache(io, hashCacheDir);
    const cacheLoadMs = dateNow(io) - cacheLoadStartedAt;

    // Try to retrieve the hash from the cache first.
    const cacheLookupStartedAt = dateNow(io);
    const cachedHash = try getHashFromCache(allocator, filePath, fileStat, localHashCache, cacheIdentity);
    const cacheLookupMs = dateNow(io) - cacheLookupStartedAt;

    var hashFromCache: bool = undefined;
    var hashBuffer: []const u8 = undefined;
    var hashMs: i64 = undefined;
    var bytesHashed: u64 = undefined;

    if (cachedHash) |cached| {
        hashBuffer = cached.hash;
        hashFromCache = true;
        hashMs = 0;
        bytesHashed = 0;
    }
    else {
        const hashStartedAt = dateNow(io);
        const hashedFile = try validateAndHash(allocator, io, filePath, fileStat, contentType, logicalPath);
        hashMs = dateNow(io) - hashStartedAt;
        const validHash = hashedFile orelse {
            return errors.throwError("Failed to validate and hash file \"{s}\"", .{logicalPath});
        };
        hashBuffer = validHash.hash;
        hashFromCache = false;
        bytesHashed = fileStat.length;
    }

    // This task hashes the file and says nothing about whether the database already holds that hash.
    //
    // It used to answer that too, and doing so was 69% of an import on a Pixel 6: the task built its
    // own database object per file, so the collection's sort index cache was fresh every time and
    // the whole hash index was read again to answer one question. The import asks it instead, from
    // the one collection it holds for the life of the run, where the index is read once.
    const result: IHashFileResult = .{
        .hash = try std.fmt.allocPrint(allocator, "{x}", .{hashBuffer}),
        .hashFromCache = hashFromCache,
        .hashMs = hashMs,
        .cacheLookupMs = cacheLookupMs,
        .taskMs = dateNow(io) - taskStartedAt,
        .cacheLoadMs = cacheLoadMs,
        .bytesHashed = bytesHashed,
    };
    const text = try std.json.Stringify.valueAlloc(allocator, result, .{});
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}
