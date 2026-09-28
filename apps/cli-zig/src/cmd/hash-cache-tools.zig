const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const tools = @import("tools-zig");
const log = &utils.log.log;
const exit = node_utils.termination.exit;
const throwError = utils.errors.throwError;
const throwStacklessError = utils.errors.throwStacklessError;
const lastErrorMessage = utils.errors.lastErrorMessage;
const recordError = utils.errors.recordError;
const HashCache = node_api.hash_cache.HashCache;
const getHashCacheDir = node_api.hash_cache.getHashCacheDir;
const computeFileHash = node_api.hash.computeFileHash;
const parseInt = tools.image.parseInt;

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
// (Zig: the cache is created with the allocator and lives until the process exits.)
//
fn openHashCache(allocator: std.mem.Allocator, io: std.Io, options: IHashCacheToolOptions) !*HashCache {
    const hashCache = try allocator.create(HashCache);
    hashCache.* = try HashCache.init(try getHashCacheDir(allocator, options.db), false);
    _ = try hashCache.load(io);
    return hashCache;
}

//
// Computes the SHA-256 hash of a file (TypeScript: `computeHash(createReadStream(filePath))`).
// A missing file fails the way Bun's createReadStream does: the path in the message is resolved against the
// cwd, and the error has no stack, so it is logged as its message alone.
// (No TypeScript counterpart: TypeScript hashes inline.)
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
// Node's `Buffer.from(text, 'hex')`: pairs of hex digits are decoded until the first pair that is not hex, where
// Node stops instead of failing, and a trailing odd digit is ignored.
// (No TypeScript counterpart: the TypeScript code calls Node's Buffer.)
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
// The length as Node's `buf.writeUIntLE(parseInt(length, 10), offset, 6)` stores it: NaN is written as 0, and a
// negative number is out of range. (No TypeScript counterpart: the hash cache takes the JavaScript number.)
//
pub fn cachedLength(length: f64) !u64 {
    if (std.math.isNan(length)) {
        return 0;
    }
    if (length < 0 or length >= 18446744073709551616.0) {
        recordError("RangeError", "The value of \"value\" is out of range. It must be >= 0 and < 2 ** 48. Received {d}", .{length});
        return error.Thrown;
    }
    return @intFromFloat(length);
}

//
// Command to compute the SHA-256 hash of a file, without touching the cache.
// Prints the hash as hex.
//
pub fn hashFileCommand(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !void {
    const hash = try hashFile(allocator, io, filePath);
    log.info(try std.fmt.allocPrint(allocator, "{x}", .{hash}));
    exit(io, 0);
}

//
// Command to hash a file and record it in the hash cache under its own path.
//
pub fn hashCacheAddCommand(allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, options: IHashCacheToolOptions) !void {
    const hash = try hashFile(allocator, io, filePath);
    const fileStat = std.Io.Dir.cwd().statFile(io, filePath, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return throwError("ENOENT: no such file or directory, stat '{s}'", .{filePath});
        }
        return err;
    };

    const hashCache = try openHashCache(allocator, io, options);
    // (Zig: fileStat.mtime is a JavaScript Date, whole milliseconds.)
    try hashCache.addHash(filePath, .{
        .hash = hash,
        .length = fileStat.size,
        .lastModified = @intCast(@divFloor(fileStat.mtime.nanoseconds, std.time.ns_per_ms)),
    });
    try hashCache.save(io);

    log.info(try std.fmt.allocPrint(allocator, "{x}", .{hash}));
    exit(io, 0);
}

//
// Command to record a hash in the hash cache against an arbitrary path, without needing the
// file to exist. This is what the concurrency smoke test uses to generate cache entries cheaply.
//
pub fn hashCacheSetCommand(allocator: std.mem.Allocator, io: std.Io, entryKey: []const u8, hashHex: []const u8, length: []const u8, options: IHashCacheToolOptions) !void {
    const hashCache = try openHashCache(allocator, io, options);
    try hashCache.addHash(entryKey, .{
        .hash = try bufferFromHex(allocator, hashHex),
        .length = try cachedLength(parseInt(length)),
        .lastModified = 0,
    });
    try hashCache.save(io);

    exit(io, 0);
}

//
// Command to record a hash in the hash cache against the source id of a photo library item, which
// is how automatic import files what it has hashed.
//
pub fn hashCacheSetSourceCommand(allocator: std.mem.Allocator, io: std.Io, sourceId: []const u8, hashHex: []const u8, length: []const u8, options: IHashCacheToolOptions) !void {
    const hashCache = try openHashCache(allocator, io, options);
    try hashCache.addSourceHash(sourceId, .{
        .hash = try bufferFromHex(allocator, hashHex),
        .length = try cachedLength(parseInt(length)),
        .lastModified = 0,
    });
    try hashCache.save(io);

    exit(io, 0);
}

//
// Command to read one entry back out of the hash cache.
// Prints the hash as hex, or nothing when the key is not cached, and exits 1 so a script can tell
// a miss from a hit without parsing the output.
//
pub fn hashCacheGetCommand(allocator: std.mem.Allocator, io: std.Io, entryKey: []const u8, options: IHashCacheToolOptions) !void {
    const hashCache = try openHashCache(allocator, io, options);
    const cacheEntry = try hashCache.getHash(allocator, entryKey) orelse {
        exit(io, 1);
    };

    log.info(try std.fmt.allocPrint(allocator, "{x}", .{cacheEntry.hash}));
    exit(io, 0);
}

//
// Command to print the asset id recorded against one entry.
// Exits 1 when the entry is missing or has no asset id, so a script can tell the two states apart
// from a recorded id without parsing the output.
//
pub fn hashCacheGetAssetIdCommand(allocator: std.mem.Allocator, io: std.Io, entryKey: []const u8, options: IHashCacheToolOptions) !void {
    const hashCache = try openHashCache(allocator, io, options);
    const cacheEntry = try hashCache.getHash(allocator, entryKey);
    if (cacheEntry == null or cacheEntry.?.assetId == null) {
        exit(io, 1);
    }

    log.info(cacheEntry.?.assetId.?);
    exit(io, 0);
}

//
// Command to drop one entry from the hash cache.
// Exits 1 when there was nothing to remove.
//
pub fn hashCacheRemoveCommand(allocator: std.mem.Allocator, io: std.Io, entryKey: []const u8, options: IHashCacheToolOptions) !void {
    const hashCache = try openHashCache(allocator, io, options);
    const removed = try hashCache.removeHash(entryKey);
    if (removed) {
        try hashCache.save(io);
    }

    exit(io, if (removed) 0 else 1);
}

//
// Command to print the key of every entry in the hash cache, one per line, so a script can
// check exactly which entries survived.
//
pub fn hashCacheListCommand(allocator: std.mem.Allocator, io: std.Io, options: IHashCacheToolOptions) !void {
    const hashCache = try openHashCache(allocator, io, options);
    for (try hashCache.getAllEntries(allocator)) |cacheEntry| {
        log.info(cacheEntry.key);
    }

    exit(io, 0);
}

//
// Command to print how many entries the hash cache holds.
//
pub fn hashCacheCountCommand(allocator: std.mem.Allocator, io: std.Io, options: IHashCacheToolOptions) !void {
    const hashCache = try openHashCache(allocator, io, options);
    log.info(try std.fmt.allocPrint(allocator, "{d}", .{hashCache.getEntryCount()}));
    exit(io, 0);
}

//
// Command to print the directory holding a database's hash cache, so a script can look at the file
// itself without having to work out how the path is derived.
//
pub fn hashCacheDirCommand(allocator: std.mem.Allocator, io: std.Io, options: IHashCacheToolOptions) !void {
    log.info(try getHashCacheDir(allocator, options.db));
    exit(io, 0);
}
