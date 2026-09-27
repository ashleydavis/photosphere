const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const pc = @import("../lib/picocolors.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const terminal_utils = @import("../lib/terminal-utils.zig");
const directory_picker = @import("../lib/directory-picker.zig");
const find_orphans = @import("../lib/find-orphans.zig");
const prompts = @import("../lib/clack/prompts.zig");
const log = &utils.log.log;
const exit = node_utils.termination.exit;
const errorMessage = utils.errors.errorMessage;
const loadDatabase = init_cmd.loadDatabase;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const loadMerkleTree = node_api.tree.loadMerkleTree;
const clearProgressMessage = terminal_utils.clearProgressMessage;
const writeProgress = terminal_utils.writeProgress;
const findOrphans = find_orphans.findOrphans;
const getDirectoryForCommand = directory_picker.getDirectoryForCommand;
const confirm = prompts.confirm;
const isCancel = prompts.isCancel;

//
// Options of the remove-orphans command (TypeScript: IRemoveOrphansCommandOptions extends IBaseCommandOptions).
// The base options are in `base`.
//
pub const IRemoveOrphansCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},
};

//
// Command that finds and removes files that are no longer in the merkle tree.
//
pub fn removeOrphansCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IRemoveOrphansCommandOptions) !void {
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
    log.info(try pc.bold(allocator, try pc.blue(allocator, "\u{1F5D1}\u{FE0F}  Remove Orphaned Files")));
    log.info("");

    if (orphans.len == 0) {
        log.info(try pc.green(allocator, "\u{2713} No orphaned files found"));
        exit(io, 0);
    }

    for (orphans) |file| {
        log.info(try std.fmt.allocPrint(allocator, "  {s} {s}", .{ try pc.red(allocator, "\u{2717}"), file }));
    }
    log.info("");

    // Confirm deletion
    if (!nonInteractive) {
        const shouldDelete = try confirm(allocator, io, .{
            .message = try std.fmt.allocPrint(allocator, "Delete {d} orphaned file(s)?", .{orphans.len}),
            .initialValue = false,
        });

        if (isCancel(shouldDelete) or !shouldDelete.value) {
            log.info(try pc.yellow(allocator, "Cancelled. No files were deleted."));
            exit(io, 0);
        }
    }

    // Delete orphaned files
    writeProgress("Deleting orphaned files...");
    var deletedCount: usize = 0;
    var errorCount: usize = 0;

    for (orphans) |file| {
        if (assetStorage.deleteFile(allocator, io, file)) {
            deletedCount += 1;
            if (options.base.verbose orelse false) {
                log.verbose(try std.fmt.allocPrint(allocator, "Deleted: {s}", .{file}));
            }
        }
        else |err| {
            errorCount += 1;
            log.@"error"(try std.fmt.allocPrint(allocator, "Failed to delete {s}: {s}", .{ file, errorMessage(err) }));
        }
    }

    clearProgressMessage();

    log.info("");
    if (errorCount == 0) {
        log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "\u{2713} Successfully deleted {d} orphaned file(s)", .{deletedCount})));
    }
    else {
        log.info(try pc.yellow(allocator, try std.fmt.allocPrint(allocator, "\u{26A0}\u{FE0F}  Deleted {d} file(s), {d} error(s)", .{ deletedCount, errorCount })));
    }

    exit(io, 0);
}
