const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const api = @import("api-zig");
const pc = @import("../lib/picocolors.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const terminal_utils = @import("../lib/terminal-utils.zig");
const format = @import("../lib/format.zig");
const log = &utils.log.log;
const exit = node_utils.termination.exit;
const clearProgressMessage = terminal_utils.clearProgressMessage;
const writeProgress = terminal_utils.writeProgress;
const loadDatabase = init_cmd.loadDatabase;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const loadDatabaseConfig = api.database_config.loadDatabaseConfig;
const repair = node_api.repair.repair;
const IRepairResult = node_api.repair.IRepairResult;

//
// Options of the repair command (TypeScript: IRepairCommandOptions extends IBaseCommandOptions).
// The base options are in `base`.
//
pub const IRepairCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},

    //
    // The source database to repair from (optional; defaults to origin from config).
    //
    source: ?[]const u8 = null,

    //
    // The source key file.
    //
    sourceKey: ?[]const u8 = null,

    //
    // Force full verification (bypass cached hash optimization).
    //
    full: ?bool = null,
};

//
// Writes each repair progress message (TypeScript: `(progress) => { writeProgress(`🔧 ${progress}`); }`).
//
fn onProgress(context: ?*anyopaque, progress: ?[]const u8) void {
    _ = context;
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const message = std.fmt.allocPrint(arena.allocator(), "\u{1F527} {s}", .{progress orelse "undefined"}) catch @panic("out of memory writing the progress line");
    writeProgress(message);
}

//
// Gets `config?.origin` (null when the config or its origin is missing, or the origin is not a string).
//
fn configOrigin(config: ?std.json.Value) ?[]const u8 {
    const value = config orelse return null;
    const object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    const origin = object.get("origin") orelse return null;
    return switch (origin) {
        .string => |text| text,
        else => null,
    };
}

//
// Formats a count in a colour (TypeScript: `pc.<colour>(count.toString())`).
//
fn count(allocator: std.mem.Allocator, value: usize, comptime colour: fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error![]const u8) ![]const u8 {
    return colour(allocator, try std.fmt.allocPrint(allocator, "{d}", .{value}));
}

//
// Formats the count of a list, in `problemColour` when it is not empty and green when it is.
//
fn listCount(allocator: std.mem.Allocator, list: []const []const u8, comptime problemColour: fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error![]const u8) ![]const u8 {
    if (list.len > 0) {
        return count(allocator, list.len, problemColour);
    }
    return pc.green(allocator, "0");
}

//
// Shows the first ten entries of a list under a title, and how many more there are.
//
fn showList(allocator: std.mem.Allocator, title: []const u8, list: []const []const u8, marker: []const u8, moreInGray: bool) !void {
    if (list.len == 0) {
        return;
    }
    log.info("");
    log.info(title);
    for (list[0..@min(list.len, 10)]) |file| {
        log.info(try std.fmt.allocPrint(allocator, "  {s} {s}", .{ marker, file }));
    }
    if (list.len > 10) {
        const more = try std.fmt.allocPrint(allocator, "  ... and {d} more", .{list.len - 10});
        log.info(if (moreInGray) try pc.gray(allocator, more) else more);
    }
}

//
// Command that repairs the integrity of the Photosphere media file database by restoring files from a source database.
//
pub fn repairCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IRepairCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;

    const target = try loadDatabase(allocator, io, options.base.db, &options.base, uuidGenerator, timestampProvider, sessionId, false);
    const targetDir = target.databaseDir;

    var sourcePath = options.source;
    if (sourcePath == null) {
        const config = try loadDatabaseConfig(allocator, io, target.rawAssetStorage);
        sourcePath = configOrigin(config);
        if (sourcePath == null) {
            log.@"error"(try pc.red(allocator, "Source database path is required for repair command. Specify --source or set an origin (psi set-origin <path>)."));
            exit(io, 1);
        }
    }
    // TODO: this mirrors a bug in the TypeScript (repair.ts repairCommand) until both are fixed: the source database is
    // loaded from options.source, not sourcePath, so when the source is the origin from the config, the database in
    // the current directory (or the one picked from the prompt) is loaded as the source instead.
    var sourceOptions: IBaseCommandOptions = .{
        .db = options.source,
        .key = options.sourceKey,
        .verbose = options.base.verbose,
        .yes = options.base.yes,
    };
    const source = try loadDatabase(allocator, io, options.source, &sourceOptions, uuidGenerator, timestampProvider, sessionId, false);
    const sourceDir = source.databaseDir;

    log.info("");
    log.info("Repairing database:");
    log.info(try std.fmt.allocPrint(allocator, "  Source:    {s}", .{try pc.cyan(allocator, sourceDir)}));
    log.info(try std.fmt.allocPrint(allocator, "  Target:    {s}", .{try pc.cyan(allocator, targetDir)}));
    log.info("");

    writeProgress("\u{1F527} Repairing database...");

    const result = try repair(allocator, io, target.assetStorage, target.rawAssetStorage, source.assetStorage, target.bsonDatabase, target.metadataCollection, .{
        .source = sourcePath.?,
        .sourceKey = options.sourceKey,
        .full = options.full,
    }, .{ .context = null, .function = onProgress });

    clearProgressMessage(); // Flush the progress message.

    log.info("");
    log.info(try pc.bold(allocator, try pc.blue(allocator, try std.fmt.allocPrint(allocator, "\u{1F527} Repair completed - processed {d} files.", .{result.totalFiles}))));
    log.info("");

    log.info(try std.fmt.allocPrint(allocator, "Files imported:   {s}", .{try count(allocator, result.totalImports, pc.cyan)}));
    log.info(try std.fmt.allocPrint(allocator, "Total files:      {s}", .{try count(allocator, result.totalFiles, pc.cyan)}));
    log.info(try std.fmt.allocPrint(allocator, "Total size:       {s}", .{try pc.cyan(allocator, try format.formatBytes(allocator, @floatFromInt(result.totalSize), format.defaultFormatBytesOptions))}));
    log.info(try std.fmt.allocPrint(allocator, "Nodes processed:  {s}", .{try count(allocator, result.nodesProcessed, pc.cyan)}));
    log.info(try std.fmt.allocPrint(allocator, "Unmodified:       {s}", .{try count(allocator, result.numUnmodified, pc.green)}));
    log.info(try std.fmt.allocPrint(allocator, "Modified:         {s}", .{try listCount(allocator, result.modified, pc.red)}));
    log.info(try std.fmt.allocPrint(allocator, "New:              {s}", .{try listCount(allocator, result.new, pc.yellow)}));
    log.info(try std.fmt.allocPrint(allocator, "Removed:          {s}", .{try listCount(allocator, result.removed, pc.red)}));
    log.info(try std.fmt.allocPrint(allocator, "Repaired:         {s}", .{try listCount(allocator, result.repaired, pc.green)}));
    log.info(try std.fmt.allocPrint(allocator, "Unrepaired:       {s}", .{try listCount(allocator, result.unrepaired, pc.red)}));
    log.info(try std.fmt.allocPrint(allocator, "Records repaired: {s}", .{try listCount(allocator, result.recordsRepaired, pc.green)}));

    // Show details for repaired files
    try showList(allocator, try pc.green(allocator, "Repaired files:"), result.repaired, try pc.green(allocator, "\u{2713}"), false);

    // Show details for unrepaired files
    try showList(allocator, try pc.red(allocator, "Unrepaired files:"), result.unrepaired, try pc.red(allocator, "\u{2717}"), false);

    // Show details for problematic files
    try showList(allocator, try pc.red(allocator, "Modified files:"), result.modified, try pc.red(allocator, "\u{25CF}"), false);
    try showList(allocator, try pc.yellow(allocator, "New files:"), result.new, try pc.yellow(allocator, "+"), false);
    try showList(allocator, try pc.red(allocator, "Removed files:"), result.removed, try pc.red(allocator, "-"), false);
    try showList(allocator, try pc.green(allocator, "Database records repaired:"), result.recordsRepaired, try pc.green(allocator, "\u{2713}"), true);

    log.info("");
    if (result.repaired.len == 0 and result.unrepaired.len == 0 and result.modified.len == 0 and result.new.len == 0 and result.removed.len == 0 and result.recordsRepaired.len == 0) {
        log.info(try pc.green(allocator, "\u{2705} Database repair completed - no issues found"));
    }
    else if (result.unrepaired.len > 0) {
        log.info(try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{274C} Database repair completed with {d} unrepaired files", .{result.unrepaired.len})));
    }
    else {
        log.info(try pc.green(allocator, "\u{2705} Database repair completed successfully"));
    }

    // Show follow-up commands
    log.info("");
    log.info(try pc.bold(allocator, "Next steps:"));
    log.info("    # Verify the repaired database integrity");
    log.info(try std.fmt.allocPrint(allocator, "    psi verify --db {s}", .{targetDir}));
    log.info("");
    log.info("    # View database summary and tree hash");
    log.info(try std.fmt.allocPrint(allocator, "    psi summary --db {s}", .{targetDir}));

    exit(io, 0);
}
