const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
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
const IDatabaseDescriptor = api.database_descriptor.IDatabaseDescriptor;
const verify = node_api.verify.verify;
const verifyDatabaseFiles = node_api.verify.verifyDatabaseFiles;
const IDatabaseFileVerifyResult = node_api.verify.IDatabaseFileVerifyResult;
const ProgressCallback = node_api.media_file_database.ProgressCallback;

//
// Options of the verify command (TypeScript: IVerifyCommandOptions extends IBaseCommandOptions).
// The base options are in `base`.
//
pub const IVerifyCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},

    //
    // Force full verification (bypass cached hash optimization).
    //
    full: ?bool = null,

    //
    // Path to a specific file or directory to verify (instead of entire database).
    //
    path: ?[]const u8 = null,
};

//
// JavaScript truthiness of an optional string.
//
fn isSet(value: ?[]const u8) bool {
    return value != null and value.?.len > 0;
}

//
// Writes each verification progress message (TypeScript: `(progress) => { writeProgress(`🔍 ${progress}`); }`).
//
fn onProgress(context: ?*anyopaque, progress: ?[]const u8) void {
    _ = context;
    var buffer: [4096]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "\u{1F50D} {s}", .{progress orelse "undefined"}) catch return;
    writeProgress(message);
}

//
// Formats a count (`count.toString()`).
//
fn countText(allocator: std.mem.Allocator, count: u64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{count});
}

//
// Command that verifies the integrity of the Photosphere media file database.
//
pub fn verifyCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IVerifyCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;
    const loaded = try loadDatabase(allocator, io, options.base.db, &options.base, uuidGenerator, timestampProvider, sessionId, false);
    const assetStorage = loaded.assetStorage;
    const databaseDir = loaded.databaseDir;
    const metadataCollection = loaded.metadataCollection;

    const storageDescriptor: IDatabaseDescriptor = .{
        .databasePath = databaseDir,
        .encryptionKey = options.base.key,
    };

    const progressCallback: ProgressCallback = .{ .context = null, .function = onProgress };

    //
    // First, verify database files (metadata and sort index files) when verifying the full database.
    //
    var dbFileResult: ?IDatabaseFileVerifyResult = null;
    if (!isSet(options.path)) {
        writeProgress("\u{1F5C4}\u{FE0F}  Verifying database files...");
        dbFileResult = try verifyDatabaseFiles(allocator, io, assetStorage, progressCallback);
    }

    //
    // Then, verify asset files.
    //
    writeProgress("Verifying assets...");

    const result = try verify(allocator, io, storageDescriptor, assetStorage, context.uuidGenerator, metadataCollection, .{
        .full = options.full,
        .pathFilter = options.path,
    }, progressCallback);

    clearProgressMessage(); // Flush the progress message.

    log.info(if (isSet(options.path))
        try std.fmt.allocPrint(allocator, "Verified files matching: {s}", .{options.path.?})
    else
        "Asset files verified.");
    log.info("");

    const recordMismatchCount: u64 = if (result.recordMismatches) |recordMismatches| recordMismatches.len else 0;

    log.info(try std.fmt.allocPrint(allocator, "Files imported:    {s}", .{try pc.cyan(allocator, try countText(allocator, result.totalImports))}));
    log.info(try std.fmt.allocPrint(allocator, "Total files:       {s}", .{try pc.cyan(allocator, try countText(allocator, result.totalFiles))}));
    log.info(try std.fmt.allocPrint(allocator, "Total size:        {s}", .{try pc.cyan(allocator, try format.formatBytes(allocator, @floatFromInt(result.totalSize), format.defaultFormatBytesOptions))}));
    log.info(try std.fmt.allocPrint(allocator, "Files processed:   {s}", .{try pc.cyan(allocator, try countText(allocator, result.filesProcessed))}));
    log.info(try std.fmt.allocPrint(allocator, "Nodes processed:   {s}", .{try pc.cyan(allocator, try countText(allocator, result.nodesProcessed))}));
    log.info(try std.fmt.allocPrint(allocator, "Unmodified:        {s}", .{try pc.green(allocator, try countText(allocator, result.numUnmodified))}));
    log.info(try std.fmt.allocPrint(allocator, "Modified:          {s}", .{if (result.modified.len > 0) try pc.red(allocator, try countText(allocator, result.modified.len)) else try pc.green(allocator, "0")}));
    log.info(try std.fmt.allocPrint(allocator, "New:               {s}", .{if (result.new.len > 0) try pc.yellow(allocator, try countText(allocator, result.new.len)) else try pc.green(allocator, "0")}));
    log.info(try std.fmt.allocPrint(allocator, "Removed:           {s}", .{if (result.removed.len > 0) try pc.red(allocator, try countText(allocator, result.removed.len)) else try pc.green(allocator, "0")}));
    log.info(try std.fmt.allocPrint(allocator, "Failures:          {s}", .{if (result.numFailures > 0) try pc.red(allocator, try countText(allocator, result.numFailures)) else try pc.green(allocator, "0")}));
    log.info(try std.fmt.allocPrint(allocator, "Record mismatches: {s}", .{if (recordMismatchCount > 0) try pc.red(allocator, try countText(allocator, recordMismatchCount)) else try pc.green(allocator, "0")}));

    // Show details for problematic files
    if (result.modified.len > 0) {
        log.info("");
        log.info(try pc.red(allocator, "Modified files:"));
        for (result.modified) |file| {
            log.info(try std.fmt.allocPrint(allocator, "  {s} {s}", .{ try pc.red(allocator, "\u{25CF}"), file }));
        }
    }

    if (result.new.len > 0) {
        log.info("");
        log.info(try pc.yellow(allocator, "New files:"));
        for (result.new) |file| {
            log.info(try std.fmt.allocPrint(allocator, "  {s} {s}", .{ try pc.yellow(allocator, "+"), file }));
        }
    }

    if (result.removed.len > 0) {
        log.info("");
        log.info(try pc.red(allocator, "Removed files:"));
        for (result.removed) |file| {
            log.info(try std.fmt.allocPrint(allocator, "  {s} {s}", .{ try pc.red(allocator, "-"), file }));
        }
    }

    if (recordMismatchCount > 0) {
        log.info("");
        log.info(try pc.red(allocator, "Asset record mismatches (missing or wrong id/hash):"));
        for (result.recordMismatches.?) |path| {
            log.info(try std.fmt.allocPrint(allocator, "  {s} {s}", .{ try pc.red(allocator, "\u{25CF}"), path }));
        }
    }

    log.info("");

    //
    // Database file summary (only when we ran database file verification, i.e. full verify without path)
    //
    if (dbFileResult) |fileResult| {
        log.info(try pc.bold(allocator, "Database files:"));
        log.info(try std.fmt.allocPrint(allocator, "  Total files:    {s}", .{try pc.cyan(allocator, try countText(allocator, fileResult.totalFiles))}));
        log.info(try std.fmt.allocPrint(allocator, "  Total size:     {s}", .{try pc.cyan(allocator, try format.formatBytes(allocator, @floatFromInt(fileResult.totalSize), format.defaultFormatBytesOptions))}));
        log.info(try std.fmt.allocPrint(allocator, "  Valid files:    {s}", .{if (fileResult.validFiles == fileResult.totalFiles) try pc.green(allocator, try countText(allocator, fileResult.validFiles)) else try pc.yellow(allocator, try countText(allocator, fileResult.validFiles))}));
        log.info(try std.fmt.allocPrint(allocator, "  Invalid files:  {s}", .{if (fileResult.invalidFiles.len > 0) try pc.red(allocator, try countText(allocator, fileResult.invalidFiles.len)) else try pc.green(allocator, "0")}));

        // Show details for invalid database files
        if (fileResult.errors.len > 0) {
            log.info("");
            log.info(try pc.red(allocator, "Invalid database files:"));
            for (fileResult.errors) |fileError| {
                log.info(try std.fmt.allocPrint(allocator, "  {s} {s}", .{ try pc.red(allocator, "\u{25CF}"), fileError.file }));
                log.info(try std.fmt.allocPrint(allocator, "    {s}", .{fileError.@"error"}));
            }
        }
        log.info("");
    }

    //
    // Summary
    //
    const dbFilesOk = dbFileResult == null or dbFileResult.?.invalidFiles.len == 0;
    const assetFilesOk = result.modified.len == 0 and result.new.len == 0 and result.removed.len == 0 and result.numFailures == 0 and recordMismatchCount == 0;

    if (dbFilesOk and assetFilesOk) {
        log.info(try pc.green(allocator, "\u{2705} Database verification passed - all files are intact"));
    }
    else {
        if (dbFileResult != null and !dbFilesOk) {
            log.info(try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{274C} Database file verification failed - {d} file(s) have issues", .{dbFileResult.?.invalidFiles.len})));
        }
        if (!assetFilesOk) {
            log.info(try pc.yellow(allocator, "\u{26A0}\u{FE0F} Asset file verification found issues - see details above"));
        }
        if (recordMismatchCount > 0) {
            log.info(try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{274C} Asset record verification failed - {d} asset(s) have missing or wrong database record", .{recordMismatchCount})));
        }
    }

    // Show follow-up commands
    log.info("");
    log.info(try pc.bold(allocator, "Next steps:"));
    const invalidDbFileCount: u64 = if (dbFileResult) |fileResult| fileResult.invalidFiles.len else 0;
    const hasProblems = invalidDbFileCount > 0 or result.modified.len > 0 or result.new.len > 0 or result.removed.len > 0 or result.numFailures > 0 or recordMismatchCount > 0;
    if (hasProblems) {
        log.info("    # Fix database issues by restoring from source");
        log.info("    psi repair --source <backup-db-path>");
        log.info("");
    }
    else {
        log.info("    # Create a backup copy of your database");
        log.info(try std.fmt.allocPrint(allocator, "    psi replicate --db {s} --dest <other-db-path>", .{databaseDir}));
        log.info("");
        log.info("    # Synchronize changes between two databases that have been independently changed");
        log.info(try std.fmt.allocPrint(allocator, "    psi sync --db {s} --dest <other-db-path>", .{databaseDir}));
        log.info("");
        log.info("    # Compare this database with another location");
        log.info(try std.fmt.allocPrint(allocator, "    psi compare --db {s} --dest <other-db-path>", .{databaseDir}));
        log.info("");
        log.info("    # View database summary and tree hash");
        log.info("    psi summary");
    }

    exit(io, 0);
}
