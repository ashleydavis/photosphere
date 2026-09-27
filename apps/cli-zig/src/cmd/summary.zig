const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const pc = @import("../lib/picocolors.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const format = @import("../lib/format.zig");
const log = &utils.log.log;
const exit = node_utils.termination.exit;
const loadDatabase = init_cmd.loadDatabase;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const getDatabaseSummary = node_api.media_file_database.getDatabaseSummary;

//
// Options of the summary command (TypeScript: ISummaryCommandOptions extends IBaseCommandOptions).
// The base options are in `base`.
//
pub const ISummaryCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},
};

//
// Command that displays a summary of the Photosphere media file database.
//
pub fn summaryCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *ISummaryCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;
    const loaded = try loadDatabase(allocator, io, options.base.db, &options.base, uuidGenerator, timestampProvider, sessionId, false);
    const assetStorage = loaded.assetStorage;
    const databaseDir = loaded.databaseDir;

    const summary = try getDatabaseSummary(allocator, io, assetStorage);

    log.info("");
    log.info(try pc.bold(allocator, try pc.blue(allocator, "\u{1F4CA} Database Summary")));
    log.info("");
    log.info(try std.fmt.allocPrint(allocator, "Mode:             {s}", .{try pc.green(allocator, @tagName(summary.mode))}));
    log.info(try std.fmt.allocPrint(allocator, "Files imported:   {s}", .{try pc.green(allocator, try std.fmt.allocPrint(allocator, "{d}", .{summary.totalImports}))}));
    log.info(try std.fmt.allocPrint(allocator, "Total files:      {s}", .{try pc.green(allocator, try std.fmt.allocPrint(allocator, "{d}", .{summary.totalFiles}))}));
    log.info(try std.fmt.allocPrint(allocator, "Total size:       {s}", .{try pc.green(allocator, try format.formatBytes(allocator, @floatFromInt(summary.totalSize), format.defaultFormatBytesOptions))}));
    log.info(try std.fmt.allocPrint(allocator, "Database version: {s}", .{try pc.green(allocator, try std.fmt.allocPrint(allocator, "{d}", .{summary.databaseVersion}))}));
    if (summary.filesHash) |filesHash| {
        log.info(try std.fmt.allocPrint(allocator, "Files hash:       {s}", .{filesHash}));
    }
    if (summary.databaseHash) |databaseHash| {
        log.info(try std.fmt.allocPrint(allocator, "Database hash:    {s}", .{databaseHash}));
    }
    log.info(try std.fmt.allocPrint(allocator, "Full root hash:   {s}", .{summary.fullHash}));

    // Show follow-up commands
    log.info("");
    log.info(try pc.bold(allocator, "Next steps:"));
    log.info("    # Verify the integrity of all files in the database");
    log.info("    psi verify");
    log.info("");
    log.info("    # Add more files to your database");
    log.info("    psi add <paths>");
    log.info("");
    log.info("    # Create a backup copy of your database");
    log.info(try std.fmt.allocPrint(allocator, "    psi replicate --db {s} --dest <path>", .{databaseDir}));
    log.info("");
    log.info("    # Synchronize changes between two databases that have been independently changed");
    log.info(try std.fmt.allocPrint(allocator, "    psi sync --db {s} --dest <path>", .{databaseDir}));

    exit(io, 0);
}
