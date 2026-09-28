const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const pc = @import("../lib/picocolors.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const log = &utils.log.log;
const exit = node_utils.termination.exit;
const pathExists = node_utils.fs.pathExists;
const getHashCacheDir = node_api.hash_cache.getHashCacheDir;
const loadDatabase = init_cmd.loadDatabase;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;

//
// Options of the hash-cache clear command (TypeScript: IClearCacheCommandOptions extends IBaseCommandOptions).
// The base options are in `base`.
//
pub const IClearCacheCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},
};

//
// Command to clear the hash cache of one database.
//
// The database has to be named because there is one cache per database. Clearing loses nothing:
// every entry can be recomputed from the files themselves, and the next import simply rehashes.
//
pub fn clearCacheCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IClearCacheCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;
    const databaseDir = (try loadDatabase(allocator, io, options.base.db, &options.base, uuidGenerator, timestampProvider, sessionId, false)).databaseDir;

    const localHashCachePath = try getHashCacheDir(allocator, databaseDir);

    if (pathExists(io, localHashCachePath)) {
        // (TypeScript: `fs.rmSync(localHashCachePath, { recursive: true, force: true })`.)
        try std.Io.Dir.cwd().deleteTree(io, localHashCachePath);
        log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "\u{2713} Cleared hash cache at: {s}", .{localHashCachePath})));
    }
    else {
        log.info(try pc.yellow(allocator, "Local hash cache not found or already empty."));
    }

    exit(io, 0);
}
