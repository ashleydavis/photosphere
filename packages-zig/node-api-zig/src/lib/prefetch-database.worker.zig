const std = @import("std");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const task_queue_zig = @import("task-queue-zig");
const api = @import("api-zig");
const open_storage = @import("open-storage.zig");
const tree = @import("tree.zig");
const media_file_database = @import("media-file-database.zig");
const retry_operations = @import("retry-operations.zig");
const errors = utils.errors;
const retry = utils.retry.retry;
const batchGenerator = utils.batch_generator.batchGenerator;
const IStorage = storage_zig.storage.IStorage;
const walk_directory = storage_zig.walk_directory;
const walkDirectory = walk_directory.walkDirectory;
const DirectoryWalker = walk_directory.DirectoryWalker;
const ITaskContext = task_queue_zig.types.ITaskContext;
const IJobTag = task_queue_zig.types.IJobTag;
const sendJobProgress = task_queue_zig.job_progress.sendJobProgress;
const openStorage = open_storage.openStorage;
const loadMerkleTree = tree.loadMerkleTree;
const loadDatabaseConfig = api.database_config.loadDatabaseConfig;
const LARGE_FILE_TIMEOUT = api.constants.LARGE_FILE_TIMEOUT;

//
// Number of simultaneous file fetch requests during prefetch.
//
const PREFETCH_CONCURRENCY = 3;

//
// Input data for the prefetch-database task.
// (The `= ""` and `= null` defaults let std.json parse data that leaves keys out.)
//
pub const IPrefetchDatabaseData = struct {
    //
    // Path to the partial database to prefetch.
    //
    databasePath: []const u8 = "",

    //
    // Names the job this task belongs to, so filling a replica in shows up in the interface's job
    // list. It carries no cancel source: a background pass is queued by the host under a source the
    // interface never learns, and it is switched off from Settings rather than stopped from the job
    // list.
    //
    job: ?IJobTag = null,
};

//
// What one prefetch pass did, which is what tells the background loop whether to keep going.
//
// A pass that fetched nothing and found nothing missing has filled the replica in, and the loop that
// asked for it can stop until a database is opened again. Anything else means there is more to do, or
// that something is in the way, and the loop asks again after its gap.
//
pub const IPrefetchDatabaseResult = struct {
    //
    // How many files this pass copied down from the origin.
    //
    filesFetched: u64,

    //
    // How many files this pass found missing and did not copy, because it was cancelled part way
    // through. Zero when the pass got to the end of what it found.
    //
    filesStillMissing: u64,
};

//
// Gets `config?.origin` when it is a non-empty string (null otherwise, which is what `!config?.origin` rejects).
// (No TypeScript counterpart: the expression is inline.)
//
fn configOrigin(config: ?std.json.Value) ?[]const u8 {
    const value = config orelse {
        return null;
    };
    const object = switch (value) {
        .object => |object| object,
        else => {
            return null;
        },
    };
    const origin = object.get("origin") orelse {
        return null;
    };
    return switch (origin) {
        .string => |text| if (text.len > 0) text else null,
        else => null,
    };
}

//
// Yields file paths that exist in origin but are missing locally,
// covering thumbnails and the BSON database (collections + sort indexes).
// (Zig: an iterator; call `next` for each path, like iterating the TypeScript missingFiles generator.)
//
const MissingFilesIterator = struct {
    // Allocates the walks and the paths.
    allocator: std.mem.Allocator,

    // Used for the storage calls.
    io: std.Io,

    // The storage the files are fetched from.
    originStorage: IStorage,

    // The partial replica the files are fetched into.
    localStorage: IStorage,

    // The directories walked, in order (TypeScript: `["thumb", ".db/bson"]`).
    dirs: []const []const u8 = &.{ "thumb", ".db/bson" },

    // The index of the next directory of `dirs` to walk.
    dirIndex: usize = 0,

    // The walk of the current directory, or null between directories.
    walker: ?DirectoryWalker = null,

    //
    // Returns the next missing file, or null when every directory has been walked.
    //
    pub fn next(self: *MissingFilesIterator) !?[]const u8 {
        while (true) {
            if (self.walker == null) {
                if (self.dirIndex >= self.dirs.len) {
                    return null;
                }
                self.walker = try walkDirectory(self.allocator, self.io, self.originStorage, self.dirs[self.dirIndex], &walk_directory.default_ignore_patterns);
                self.dirIndex += 1;
            }
            const file = try self.walker.?.next() orelse {
                self.walker = null;
                continue;
            };
            if (!try self.localStorage.fileExists(self.allocator, self.io, file.fileName)) {
                return file.fileName;
            }
        }
    }
};

//
// Copies one missing file down from the origin (TypeScript: the `async filePath => { ... }` arrow function that
// `batch.map` runs). Runs concurrently with the rest of its batch, with its own allocator because the caller's is
// not shared between threads.
//
const FetchFileTask = struct {
    // The storage the file is fetched from.
    originStorage: IStorage,

    // The partial replica the file is fetched into.
    localStorage: IStorage,

    // The file to fetch.
    filePath: []const u8,

    // The error the fetch failed with, or null when it succeeded.
    failure: ?anyerror = null,

    // The message of the error the fetch failed with, captured on the thread that ran it.
    errorRecord: errors.ErrorRecord = .{},

    //
    // Fetches the file, recording the error when it fails.
    //
    fn run(self: *FetchFileTask, io: std.Io) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        self.fetch(arena.allocator(), io) catch |err| {
            self.failure = err;
            errors.captureError(&self.errorRecord);
        };
    }

    //
    // Fetches the file.
    //
    fn fetch(self: *FetchFileTask, allocator: std.mem.Allocator, io: std.Io) !void {
        // The long timeout, because this is a file copy and a file copy is allowed to take a
        // while. `retry`'s thirty second default was what applied here, and the metadata hash
        // index of a real database is nine files of about 13 MB each: a phone cannot pull one of
        // those down and write it in thirty seconds, so each timed out, was retried, timed out
        // again, and eventually one exhausted its attempts and took the whole prefetch with it.
        // Measured on a Pixel 6, that killed the prefetch 38 minutes in, with every thumbnail
        // already fetched and the index files left behind.
        //
        // `sync.ts` and `replicate.ts` pass it at exactly this point in their own copy loops and
        // `sync.ts` carries a comment about having been bitten by it on a phone. This is the same
        // mistake in a third place.
        var copyOperation: retry_operations.CopyStreamOperation("async () => {\n        const stream = await originStorage.readStream(filePath);\n        await localStorage.writeStream(filePath, undefined, stream);\n      }") = .{
            .allocator = allocator,
            .sourceStorage = self.originStorage,
            .destStorage = self.localStorage,
            .fileName = self.filePath,
            .contentType = null,
        };
        try retry(io, &copyOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, try std.fmt.allocPrint(allocator, "Failed to prefetch {s}", .{self.filePath}));
    }
};

//
// Fetches a batch of files at once and waits for all of them (TypeScript: `await Promise.all(batch.map(...))`),
// throwing the error of the first one that failed.
// (No TypeScript counterpart: Promise.all is inline.)
//
fn fetchBatch(allocator: std.mem.Allocator, io: std.Io, originStorage: IStorage, localStorage: IStorage, batch: []const []const u8) !void {
    const tasks = try allocator.alloc(FetchFileTask, batch.len);
    for (batch, tasks) |filePath, *task| {
        task.* = .{
            .originStorage = originStorage,
            .localStorage = localStorage,
            .filePath = filePath,
        };
    }

    var group: std.Io.Group = .init;
    for (tasks) |*task| {
        group.async(io, FetchFileTask.run, .{ task, io });
    }
    try group.await(io);

    for (tasks) |*task| {
        if (task.failure) |failure| {
            errors.restoreError(&task.errorRecord);
            return failure;
        }
    }
}

//
// Converts the prefetch result to the JSON value returned as the task output.
// (No TypeScript counterpart: TypeScript returns the object itself.)
//
fn prefetchResultToJson(allocator: std.mem.Allocator, result: IPrefetchDatabaseResult) !std.json.Value {
    const text = try std.json.Stringify.valueAlloc(allocator, result, .{});
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

//
// Task handler that pre-fetches all files missing from a partial database replica.
//
// Fetches thumbnails and BSON database files (collections + sort indexes) that
// are missing from the local replica, copying them from origin storage.
//
// Exits immediately when called against a full (non-partial) database.
// (Zig: the task data and output are JSON values holding IPrefetchDatabaseData and IPrefetchDatabaseResult.)
//
pub fn prefetchDatabaseHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    const data = try std.json.parseFromValueLeaky(IPrefetchDatabaseData, allocator, taskData, .{ .ignore_unknown_fields = true });
    if (data.databasePath.len == 0) {
        return errors.throwError("databasePath is required", .{});
    }

    const runStartedAt = std.Io.Clock.real.now(io).toMilliseconds();

    //
    // Nothing to fetch is a result, not a failure, and both of the ways of having nothing to fetch
    // are answered the same way: no files copied and none left behind, which is what tells the
    // background loop the replica is complete and it can stop asking.
    //
    const nothingToFetch: IPrefetchDatabaseResult = .{
        .filesFetched = 0,
        .filesStillMissing = 0,
    };

    //
    // Check whether this is a partial database. Skip immediately for full databases.
    //
    const local = try openStorage(allocator, io, data.databasePath, null, null);
    const localStorage = local.storage;
    const rawStorage = local.rawStorage;
    const merkleTree = try loadMerkleTree(allocator, io, localStorage);
    if (merkleTree == null or !media_file_database.isPartialDatabase(merkleTree.?.databaseMetadata)) {
        return prefetchResultToJson(allocator, nothingToFetch);
    }

    //
    // Load the database config to find the origin URL.
    //
    const config = try loadDatabaseConfig(allocator, io, rawStorage);
    const origin = configOrigin(config) orelse {
        return prefetchResultToJson(allocator, nothingToFetch);
    };

    const originStorage = (try openStorage(allocator, io, origin, null, null)).storage;

    var missingFiles: MissingFilesIterator = .{
        .allocator = allocator,
        .io = io,
        .originStorage = originStorage,
        .localStorage = localStorage,
    };

    var filesFetched: u64 = 0;
    var filesStillMissing: u64 = 0;

    // The job the interface lists. Sent before the walk starts, because walking the origin is itself
    // minutes of work on a phone and a job that appears only once bytes move looks like nothing is
    // happening.
    try sendJobProgress(allocator, context, data.job, runStartedAt, null);

    //
    // Fetch missing files PREFETCH_CONCURRENCY at a time without accumulating them in memory.
    //
    var batches = batchGenerator([]const u8, allocator, &missingFiles, PREFETCH_CONCURRENCY);
    while (try batches.next()) |batch| {
        if (context.isCancelled()) {
            // The batch was drawn from the walk and is not going to be fetched, so it is left behind.
            // Reporting it is what stops the loop reading a cancelled pass as a finished one.
            filesStillMissing += batch.len;
            break;
        }
        try fetchBatch(allocator, io, originStorage, localStorage, batch);
        filesFetched += batch.len;

        try sendJobProgress(allocator, context, data.job, runStartedAt, try std.fmt.allocPrint(allocator, "{d} files fetched", .{filesFetched}));
    }

    return prefetchResultToJson(allocator, .{
        .filesFetched = filesFetched,
        .filesStillMissing = filesStillMissing,
    });
}
