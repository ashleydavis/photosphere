const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const pc = @import("../lib/picocolors.zig");
const format = @import("../lib/format.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const log = &utils.log.log;
const exit = node_utils.termination.exit;
const HashCache = node_api.hash_cache.HashCache;
const getHashCacheDir = node_api.hash_cache.getHashCacheDir;
const formatBytes = format.formatBytes;
const defaultFormatBytesOptions = format.defaultFormatBytesOptions;
const loadDatabase = init_cmd.loadDatabase;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const Date = utils.timestamp_provider.Date;
const errorMessage = utils.errors.errorMessage;
const formatErrorChain = utils.wrapped_error.formatErrorChain;

//
// Options of the hash-cache show command (TypeScript: IHashCacheCommandOptions extends IBaseCommandOptions).
// The base options are in `base`.
//
pub const IHashCacheCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},
};

//
// Command to display the hash cache of one database.
//
// The database has to be named because there is one cache per database: an entry records the id
// the file has in that database, and one entry cannot hold the ids of several.
//
pub fn hashCacheCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IHashCacheCommandOptions) !void {
    showHashCache(allocator, io, context, options) catch |err| {
        log.@"error"(try pc.red(allocator, try std.fmt.allocPrint(allocator, "Error reading hash cache: {s}", .{errorMessage(err)})));
        if (options.base.verbose orelse false) {
            // Zig errors carry no stack trace, so the error chain stands in for `err.stack`.
            log.@"error"(try pc.red(allocator, try formatErrorChain(allocator, err)));
        }
        exit(io, 1);
    };
}

//
// The body of the try block of hashCacheCommand. (No TypeScript counterpart: TypeScript catches inline.)
//
fn showHashCache(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IHashCacheCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;
    const databaseDir = (try loadDatabase(allocator, io, options.base.db, &options.base, uuidGenerator, timestampProvider, sessionId, false)).databaseDir;

    log.info(try pc.blue(allocator, "\n=== Local Hash Cache ==="));
    const localHashCachePath = try getHashCacheDir(allocator, databaseDir);
    var localHashCache = try HashCache.init(localHashCachePath, false);
    defer localHashCache.deinit();

    const loaded = try localHashCache.load(io);
    if (!loaded) {
        log.info(try pc.yellow(allocator, "Local hash cache not found or empty."));
    }
    else {
        const entryCount = localHashCache.getEntryCount();
        log.info(try std.fmt.allocPrint(allocator, "Database: {s}", .{databaseDir}));
        log.info(try std.fmt.allocPrint(allocator, "Location: {s}", .{localHashCachePath}));
        log.info(try std.fmt.allocPrint(allocator, "Entries: {d}", .{entryCount}));

        if (entryCount > 0) {
            log.info("\nCache entries:");
            try displayHashCacheEntries(allocator, &localHashCache);
        }
    }

    log.info(""); // Empty line at end
}

//
// Helper function to display hash cache entries
//
fn displayHashCacheEntries(allocator: std.mem.Allocator, hashCache: *HashCache) !void {
    const entries = try hashCache.getAllEntries(allocator);

    if (entries.len == 0) {
        log.info("  No entries found.");
        return;
    }

    log.info("");

    // Display entries
    for (entries) |entry| {
        log.info(try pc.cyan(allocator, try std.fmt.allocPrint(allocator, "  {s}", .{entry.key})));
        log.info(try std.fmt.allocPrint(allocator, "    Keyed by: {s}", .{if (entry.keyedBySourceId) "photo library source id" else "file path"}));
        log.info(try std.fmt.allocPrint(allocator, "    Size: {s}", .{try formatBytes(allocator, @floatFromInt(entry.size), defaultFormatBytesOptions)}));
        log.info(try std.fmt.allocPrint(allocator, "    Modified: {s}", .{try formatModified(allocator, entry.lastModified)}));
        log.info(try std.fmt.allocPrint(allocator, "    Hash: {s}", .{entry.hash}));
        log.info(try std.fmt.allocPrint(allocator, "    Asset id: {s}", .{entry.assetId orelse "(not known to be in the database)"}));
        log.info("");
    }

    log.info(try std.fmt.allocPrint(allocator, "  Total: {d} {s}", .{ entries.len, if (entries.len == 1) "entry" else "entries" }));
}

//
// Formats a modified time like `lastModified.toISOString().replace('T', ' ').slice(0, 19)`.
// (No TypeScript counterpart: TypeScript formats inline.)
//
pub fn formatModified(allocator: std.mem.Allocator, lastModified: i64) ![]const u8 {
    const isoString = try (Date{ .epochMilliseconds = lastModified }).toISOString(allocator);
    const replaced = try allocator.dupe(u8, isoString);
    if (std.mem.indexOfScalar(u8, replaced, 'T')) |index| {
        replaced[index] = ' ';
    }
    return replaced[0..@min(replaced.len, 19)];
}
