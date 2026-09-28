const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const pc = @import("../lib/picocolors.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const terminal_utils = @import("../lib/terminal-utils.zig");
const log_module = @import("../lib/log.zig");
const log = &utils.log.log;
const exit = node_utils.termination.exit;
const clearProgressMessage = terminal_utils.clearProgressMessage;
const writeProgress = terminal_utils.writeProgress;
const loadDatabase = init_cmd.loadDatabase;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const getFileLogger = log_module.getFileLogger;
const IDatabaseDescriptor = api.database_descriptor.IDatabaseDescriptor;
const checkPaths = node_api.check.checkPaths;
const CheckPathsProgressCallback = node_api.check.CheckPathsProgressCallback;
const IAddSummary = node_api.media_file_database.IAddSummary;

//
// Options of the check command (TypeScript: ICheckCommandOptions extends IBaseCommandOptions).
// The base options are in `base`.
//
pub const ICheckCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},
};

//
// Writes the progress line (TypeScript: the `(currentlyScanning, summary) => { ... }` arrow function).
//
fn onProgress(context: ?*anyopaque, currentlyScanning: ?[]const u8, summary: *const IAddSummary) void {
    _ = context;
    var buffer: [16 * 1024]u8 = undefined;
    var bufferAllocator = std.heap.FixedBufferAllocator.init(&buffer);
    const message = buildProgressMessage(bufferAllocator.allocator(), currentlyScanning, summary) catch |err| {
        log.exception("Failed to write the progress message", err);
        return;
    };
    writeProgress(message);
}

//
// Builds the progress line. (No TypeScript counterpart: the body of the arrow function.)
//
pub fn buildProgressMessage(allocator: std.mem.Allocator, currentlyScanning: ?[]const u8, summary: *const IAddSummary) ![]const u8 {
    var progressMessage: std.ArrayList(u8) = .empty;
    try progressMessage.print(allocator, "Already in DB: {s}", .{try pc.green(allocator, try std.fmt.allocPrint(allocator, "{d}", .{summary.filesAlreadyAdded}))});
    if (summary.filesAdded > 0) {
        try progressMessage.print(allocator, " | Would add: {s}", .{try pc.yellow(allocator, try std.fmt.allocPrint(allocator, "{d}", .{summary.filesAdded}))});
    }
    if (summary.filesIgnored > 0) {
        try progressMessage.print(allocator, " | Ignored: {d}", .{summary.filesIgnored});
    }
    if (currentlyScanning) |scanning| {
        if (scanning.len > 0) {
            try progressMessage.print(allocator, " | Scanning {s}", .{try pc.cyan(allocator, scanning)});
        }
    }

    try progressMessage.appendSlice(allocator, " | Abort with Ctrl-C");
    return progressMessage.items;
}

//
// Command that checks which files and directories have been added to the Photosphere media file database.
//
pub fn checkCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, paths: []const []const u8, options: *ICheckCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;
    const sessionTempDir = context.sessionTempDir;
    const loaded = try loadDatabase(allocator, io, options.base.db, &options.base, uuidGenerator, timestampProvider, sessionId, false);
    const databaseDir = loaded.databaseDir;

    const storageDescriptor: IDatabaseDescriptor = .{
        .databasePath = databaseDir,
        .encryptionKey = options.base.key,
    };

    writeProgress("Searching for files...");

    const progressCallback: CheckPathsProgressCallback = .{
        .context = null,
        .function = onProgress,
    };
    const addSummary = try checkPaths(
        allocator,
        io,
        storageDescriptor,
        paths,
        progressCallback,
        uuidGenerator,
        sessionTempDir,
    );

    clearProgressMessage(); // Flush the progress message.

    const totalChecked = addSummary.filesAdded + addSummary.filesAlreadyAdded + addSummary.filesIgnored;
    log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "Checked {d} files.\n", .{totalChecked})));

    log.info(try pc.bold(allocator, "Summary:"));
    log.info(try std.fmt.allocPrint(allocator, "Files considered: {d}", .{addSummary.filesProcessed}));
    log.info(try std.fmt.allocPrint(allocator, "Files to add:     {d}", .{addSummary.filesAdded}));
    log.info(try std.fmt.allocPrint(allocator, "Files ignored:    {d}", .{addSummary.filesIgnored}));
    log.info(try std.fmt.allocPrint(allocator, "Files failed:     {d}", .{addSummary.filesFailed}));
    log.info(try std.fmt.allocPrint(allocator, "Already added:    {d}", .{addSummary.filesAlreadyAdded}));

    // If there were failures, tell the user to check the log file
    if (addSummary.filesFailed > 0) {
        if (getFileLogger()) |fileLogger| {
            const logFilePath = fileLogger.getLogFilePath();
            log.info("");
            log.info(try pc.yellow(allocator, try std.fmt.allocPrint(allocator, "\u{26A0}\u{FE0F}  {d} file{s} failed. Check the log file for details:", .{ addSummary.filesFailed, if (addSummary.filesFailed == 1) "" else "s" })));
            log.info(try std.fmt.allocPrint(allocator, "    {s}", .{try pc.cyan(allocator, logFilePath)}));
        }
    }

    // Show follow-up commands
    log.info("");
    log.info(try pc.bold(allocator, "Next steps:"));
    if (addSummary.filesAdded > 0) {
        log.info("    # Add the new files found to your database");
        log.info(try std.fmt.allocPrint(allocator, "    psi add <paths> --db {s}", .{databaseDir}));
        log.info("");
    }
    log.info("    # Verify the integrity of all files in the database");
    log.info(try std.fmt.allocPrint(allocator, "    psi verify --db {s}", .{databaseDir}));
    log.info("");
    log.info("    # View database summary and statistics");
    log.info(try std.fmt.allocPrint(allocator, "    psi summary --db {s}", .{databaseDir}));

    exit(io, 0);
}
