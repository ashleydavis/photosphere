const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const pc = @import("../lib/picocolors.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const terminal_utils = @import("../lib/terminal-utils.zig");
const directory_picker = @import("../lib/directory-picker.zig");
const find_orphans = @import("../lib/find-orphans.zig");
const log = &utils.log.log;
const exit = node_utils.termination.exit;
const loadDatabase = init_cmd.loadDatabase;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const loadMerkleTree = node_api.tree.loadMerkleTree;
const clearProgressMessage = terminal_utils.clearProgressMessage;
const writeProgress = terminal_utils.writeProgress;
const findOrphans = find_orphans.findOrphans;
const getDirectoryForCommand = directory_picker.getDirectoryForCommand;

//
// Options of the find-orphans command (TypeScript: IFindOrphansCommandOptions extends IBaseCommandOptions).
// The base options are in `base`.
//
pub const IFindOrphansCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},
};

//
// Command that finds and lists files that are no longer in the merkle tree.
//
pub fn findOrphansCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IFindOrphansCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;

    const nonInteractive = options.base.yes orelse false;

    var dbDir = options.base.db;
    if (dbDir == null) {
        const cwd = if (options.base.cwd != null and options.base.cwd.?.len > 0) options.base.cwd.? else try std.process.currentPathAlloc(io, allocator);
        dbDir = try getDirectoryForCommand(allocator, io, .existing, nonInteractive, cwd);
    }

    // Load the database
    const loaded = try loadDatabase(allocator, io, dbDir, &options.base, uuidGenerator, timestampProvider, sessionId, false);
    const assetStorage = loaded.assetStorage;

    log.info("");
    log.info("Finding orphaned files in database:");
    log.info(try std.fmt.allocPrint(allocator, "  Database: {s}", .{try pc.cyan(allocator, loaded.databaseDir)}));
    log.info("");

    // Load merkle tree
    writeProgress("Loading merkle tree...");
    const merkleTree = try loadMerkleTree(allocator, io, assetStorage) orelse {
        clearProgressMessage();
        log.info(try pc.red(allocator, "Error: Failed to load merkle tree"));
        exit(io, 1);
    };

    // Find orphans
    writeProgress("Scanning for orphaned files...");
    const orphans = try findOrphans(allocator, io, assetStorage, &merkleTree);
    clearProgressMessage();

    log.info("");
    log.info(try pc.bold(allocator, try pc.blue(allocator, "\u{1F4CB} Orphaned Files")));
    log.info("");

    if (orphans.len == 0) {
        log.info(try pc.green(allocator, "\u{2713} No orphaned files found"));
    }
    else {
        for (orphans) |file| {
            log.info(try std.fmt.allocPrint(allocator, "  {s} {s}", .{ try pc.red(allocator, "\u{2717}"), file }));
        }
        log.info("");
        log.info(try pc.yellow(allocator, try std.fmt.allocPrint(allocator, "\u{26A0}\u{FE0F}  Found {d} orphaned file(s) that exist in storage but are not tracked in the merkle tree.", .{orphans.len})));
        log.info(try pc.yellow(allocator, "     Use 'psi remove-orphans' to remove them."));
    }

    exit(io, 0);
}
