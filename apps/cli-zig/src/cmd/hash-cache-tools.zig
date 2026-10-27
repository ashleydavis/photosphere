const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const serialization = @import("serialization-zig");
const exit = node_utils.termination.exit;
const throwError = utils.errors.throwError;
const throwStacklessError = utils.errors.throwStacklessError;
const lastErrorMessage = utils.errors.lastErrorMessage;
const recordError = utils.errors.recordError;
const HashCache = node_api.hash_cache.HashCache;
const getHashCacheDir = node_api.hash_cache.getHashCacheDir;
const computeFileHash = node_api.hash.computeFileHash;
const parseInt = utils.js_number.parseInt;

//
// Internal tools for driving a database's hash cache directly.
//
// These are for development and for the concurrency smoke test, not for end users, so the commands
// that call them are registered as hidden. They print plain, parseable output rather than anything
// decorated, because scripts read it.
//

//
// The options every one of these tools takes.
//
pub const IHashCacheToolOptions = struct {
    // The database whose cache to act on. Required, because there is one cache per database.
    //
    // Taken as given rather than resolved through loadDatabase the way the user-facing commands do:
    // these tools act on the cache alone and are pointed at a path by a test script, so there is
    // nothing to resolve and no database that has to exist.
    db: []const u8,
};

//
// Loads a database's hash cache, ready to be read or written.
// The cache is created with the allocator and lives until the process exits.
//
fn openHashCache(allocator: std.mem.Allocator, io: std.Io, log: ILog, options: IHashCacheToolOptions) !*HashCache {
    const hashCache = try allocator.create(HashCache);
    hashCache.* = try HashCache.init(try getHashCacheDir(allocator, options.db), false);
    _ = try hashCache.load(io, log);
    return hashCache;
}

//
// Computes the SHA-256 hash of a file.
// A missing file fails with the path in the message resolved against the
// cwd, and the error has no stack, so it is logged as its message alone.
//
fn hashFile(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) ![]const u8 {
    return computeFileHash(allocator, io, filePath, null) catch |err| {
        if (err == error.Thrown and std.mem.startsWith(u8, lastErrorMessage(), "ENOENT:")) {
            const currentPath = try std.process.currentPathAlloc(io, allocator);
            const resolvedPath = try std.fs.path.resolve(allocator, &.{ currentPath, filePath });
            return throwStacklessError("ENOENT: no such file or directory, open '{s}'", .{resolvedPath});
        }
        return err;
    };
}

//
// Decodes hex text to bytes: pairs of hex digits are decoded until the first pair that is not hex, where
// decoding stops instead of failing, and a trailing odd digit is ignored.
//
pub fn bufferFromHex(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index + 1 < text.len) : (index += 2) {
        const high = std.fmt.charToDigit(text[index], 16) catch {
            break;
        };
        const low = std.fmt.charToDigit(text[index + 1], 16) catch {
            break;
        };
        try bytes.append(allocator, high * 16 + low);
    }
    return bytes.items;
}

//
// The length as the hash cache stores it in 6 little-endian bytes: NaN is written as 0, and a
// negative number or one of 2 ** 48 or more is out of range, with the number printed in its shortest decimal form.
//
pub fn cachedLength(length: f64) !u64 {
    if (std.math.isNan(length)) {
        return 0;
    }
    if (length < 0 or length >= 281474976710656.0) {
        var numberBuffer: [64]u8 = undefined;
        var numberWriter: std.Io.Writer = .fixed(&numberBuffer);
        try serialization.js_number.writeNumber(&numberWriter, length);
        recordError("RangeError", "The value of \"value\" is out of range. It must be >= 0 and < 2 ** 48. Received {s}", .{numberWriter.buffered()});
        return error.Thrown;
    }
    return @intFromFloat(length);
}

//
// Command to compute the SHA-256 hash of a file, without touching the cache.
// Prints the hash as hex.
//
pub fn hashFileCommand(allocator: std.mem.Allocator, io: std.Io, log: ILog, filePath: []const u8) !void {
    const hash = try hashFile(allocator, io, filePath);
    log.info(try std.fmt.allocPrint(allocator, "{x}", .{hash}));
    exit(io, log, 0);
}

//
// Command to hash a file and record it in the hash cache under its own path.
//
pub fn hashCacheAddCommand(allocator: std.mem.Allocator, io: std.Io, log: ILog, filePath: []const u8, options: IHashCacheToolOptions) !void {
    const hash = try hashFile(allocator, io, filePath);
    const fileStat = std.Io.Dir.cwd().statFile(io, filePath, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return throwError("ENOENT: no such file or directory, stat '{s}'", .{filePath});
        }
        return err;
    };

    const hashCache = try openHashCache(allocator, io, log, options);
    // The modification time is kept as whole milliseconds, truncated towards zero.
    try hashCache.addHash(filePath, .{
        .hash = hash,
        .length = fileStat.size,
        .lastModified = fileStat.mtime.toMilliseconds(),
    });
    try hashCache.save(io, log);

    log.info(try std.fmt.allocPrint(allocator, "{x}", .{hash}));
    exit(io, log, 0);
}

//
// Command to record a hash in the hash cache against an arbitrary path, without needing the
// file to exist. This is what the concurrency smoke test uses to generate cache entries cheaply.
//
pub fn hashCacheSetCommand(allocator: std.mem.Allocator, io: std.Io, log: ILog, entryKey: []const u8, hashHex: []const u8, length: []const u8, options: IHashCacheToolOptions) !void {
    const hashCache = try openHashCache(allocator, io, log, options);
    try hashCache.addHash(entryKey, .{
        .hash = try bufferFromHex(allocator, hashHex),
        .length = try cachedLength(parseInt(length, 10)),
        .lastModified = 0,
    });
    try hashCache.save(io, log);

    exit(io, log, 0);
}

//
// Command to record a hash in the hash cache against the source id of a photo library item, which
// is how automatic import files what it has hashed.
//
pub fn hashCacheSetSourceCommand(allocator: std.mem.Allocator, io: std.Io, log: ILog, sourceId: []const u8, hashHex: []const u8, length: []const u8, options: IHashCacheToolOptions) !void {
    const hashCache = try openHashCache(allocator, io, log, options);
    try hashCache.addSourceHash(sourceId, .{
        .hash = try bufferFromHex(allocator, hashHex),
        .length = try cachedLength(parseInt(length, 10)),
        .lastModified = 0,
    });
    try hashCache.save(io, log);

    exit(io, log, 0);
}

//
// Command to read one entry back out of the hash cache.
// Prints the hash as hex, or nothing when the key is not cached, and exits 1 so a script can tell
// a miss from a hit without parsing the output.
//
pub fn hashCacheGetCommand(allocator: std.mem.Allocator, io: std.Io, log: ILog, entryKey: []const u8, options: IHashCacheToolOptions) !void {
    const hashCache = try openHashCache(allocator, io, log, options);
    const cacheEntry = try hashCache.getHash(allocator, entryKey) orelse {
        exit(io, log, 1);
    };

    log.info(try std.fmt.allocPrint(allocator, "{x}", .{cacheEntry.hash}));
    exit(io, log, 0);
}

//
// Command to print the asset id recorded against one entry.
// Exits 1 when the entry is missing or has no asset id, so a script can tell the two states apart
// from a recorded id without parsing the output.
//
pub fn hashCacheGetAssetIdCommand(allocator: std.mem.Allocator, io: std.Io, log: ILog, entryKey: []const u8, options: IHashCacheToolOptions) !void {
    const hashCache = try openHashCache(allocator, io, log, options);
    const cacheEntry = try hashCache.getHash(allocator, entryKey);
    if (cacheEntry == null or cacheEntry.?.assetId == null) {
        exit(io, log, 1);
    }

    log.info(cacheEntry.?.assetId.?);
    exit(io, log, 0);
}

//
// Command to drop one entry from the hash cache.
// Exits 1 when there was nothing to remove.
//
pub fn hashCacheRemoveCommand(allocator: std.mem.Allocator, io: std.Io, log: ILog, entryKey: []const u8, options: IHashCacheToolOptions) !void {
    const hashCache = try openHashCache(allocator, io, log, options);
    const removed = try hashCache.removeHash(entryKey);
    if (removed) {
        try hashCache.save(io, log);
    }

    exit(io, log, if (removed) 0 else 1);
}

//
// Command to print the key of every entry in the hash cache, one per line, so a script can
// check exactly which entries survived.
//
pub fn hashCacheListCommand(allocator: std.mem.Allocator, io: std.Io, log: ILog, options: IHashCacheToolOptions) !void {
    const hashCache = try openHashCache(allocator, io, log, options);
    for (try hashCache.getAllEntries(allocator)) |cacheEntry| {
        log.info(cacheEntry.key);
    }

    exit(io, log, 0);
}

//
// Command to print how many entries the hash cache holds.
//
pub fn hashCacheCountCommand(allocator: std.mem.Allocator, io: std.Io, log: ILog, options: IHashCacheToolOptions) !void {
    const hashCache = try openHashCache(allocator, io, log, options);
    log.info(try std.fmt.allocPrint(allocator, "{d}", .{hashCache.getEntryCount()}));
    exit(io, log, 0);
}

//
// Command to print the directory holding a database's hash cache, so a script can look at the file
// itself without having to work out how the path is derived.
//
pub fn hashCacheDirCommand(allocator: std.mem.Allocator, io: std.Io, log: ILog, options: IHashCacheToolOptions) !void {
    log.info(try getHashCacheDir(allocator, options.db));
    exit(io, log, 0);
}
