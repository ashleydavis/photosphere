const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const task_queue_zig = @import("task-queue-zig");
const pc = @import("../lib/picocolors.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const terminal_utils = @import("../lib/terminal-utils.zig");
const log_module = @import("../lib/log.zig");
const format = @import("../lib/format.zig");
const log = &utils.log.log;
const sleep = utils.sleep.sleep;
const IUuidGenerator = utils.uuid_generator.IUuidGenerator;
const exit = node_utils.termination.exit;
const pathExists = node_utils.fs.pathExists;
const getDefaultPhotoFolders = node_utils.photo_folders.getDefaultPhotoFolders;
const clearProgressMessage = terminal_utils.clearProgressMessage;
const writeProgress = terminal_utils.writeProgress;
const loadDatabase = init_cmd.loadDatabase;
const resolveGeocodingApiKey = init_cmd.resolveGeocodingApiKey;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const getFileLogger = log_module.getFileLogger;
const formatBytes = format.formatBytes;
const defaultFormatBytesOptions = format.defaultFormatBytesOptions;
const IDatabaseDescriptor = api.database_descriptor.IDatabaseDescriptor;
const IAutoImportSettings = api.auto_import_settings.IAutoImportSettings;
const IAutoImportSource = api.auto_import_settings.IAutoImportSource;
const DEFAULT_AUTO_IMPORT_SETTINGS = api.auto_import_settings.DEFAULT_AUTO_IMPORT_SETTINGS;
const autoImportSettingsToJson = api.auto_import_settings.autoImportSettingsToJson;
const addPaths = node_api.import_module.addPaths;
const AddPathsProgressCallback = node_api.import_module.AddPathsProgressCallback;
const IAddSummary = node_api.media_file_database.IAddSummary;
const IImportOptions = node_api.import_assets_worker.IImportOptions;
const ICleanupSourcesResult = node_api.cleanup_sources_worker.ICleanupSourcesResult;
const TaskQueue = task_queue_zig.task_queue.TaskQueue;

//
// How long the CLI waits before running the import again under `--watch`. Shorter than the
// desktop and mobile apps wait, because a person is sitting in front of this one watching it.
//
const WATCH_RESTART_INTERVAL_MS = 5000;

//
// Options of the add command (TypeScript: IAddCommandOptions extends IBaseCommandOptions).
// The base options are in `base`.
//
pub const IAddCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},

    // Run without making any database changes.
    dryRun: ?bool = null,

    //
    // Keep watching the named folders and import what turns up, rather than walking them once and
    // stopping.
    //
    watch: ?bool = null,

    //
    // Delete the source files the database is confirmed to hold, once the import has finished.
    //
    cleanup: ?bool = null,
};

//
// `value.toString().padStart(4)` for a count. (No TypeScript counterpart.)
//
fn padCount(allocator: std.mem.Allocator, value: f64) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d: >4}", .{value});
}

//
// What the progress callback needs (TypeScript: the variables the arrow function passed to addPaths closes over).
//
pub const ProgressState = struct {
    // The command options.
    options: *IAddCommandOptions,

    //
    // Writes the progress line (TypeScript: the `(currentlyScanning, summary) => { ... }` arrow function).
    //
    fn onProgress(context: ?*anyopaque, currentlyScanning: ?[]const u8, summary: *const IAddSummary) void {
        const self: *ProgressState = @ptrCast(@alignCast(context.?));
        var buffer: [16 * 1024]u8 = undefined;
        var bufferAllocator = std.heap.FixedBufferAllocator.init(&buffer);
        const message = self.buildProgressMessage(bufferAllocator.allocator(), currentlyScanning, summary) catch |err| {
            log.exception("Failed to write the progress message", err);
            return;
        };
        writeProgress(message);
    }

    //
    // Builds the progress line. (No TypeScript counterpart: the body of the arrow function.)
    //
    pub fn buildProgressMessage(self: *ProgressState, allocator: std.mem.Allocator, currentlyScanning: ?[]const u8, summary: *const IAddSummary) ![]const u8 {
        const dryRun = self.options.dryRun orelse false;
        var progressMessage: std.ArrayList(u8) = .empty;
        if (dryRun) {
            try progressMessage.print(allocator, "Would add: {s}", .{try pc.green(allocator, try padCount(allocator, summary.filesAdded))});
        }
        else {
            try progressMessage.print(allocator, "Added: {s}", .{try pc.green(allocator, try padCount(allocator, summary.filesAdded))});
        }
        if (summary.filesAlreadyAdded > 0) {
            try progressMessage.print(allocator, " | Existing: {s}", .{try pc.blue(allocator, try padCount(allocator, summary.filesAlreadyAdded))});
        }
        if (summary.filesIgnored > 0) {
            try progressMessage.print(allocator, " | Ignored: {s}", .{try pc.yellow(allocator, try padCount(allocator, summary.filesIgnored))});
        }
        if (summary.filesFailed > 0) {
            try progressMessage.print(allocator, " | Failed: {s}", .{try pc.red(allocator, try padCount(allocator, summary.filesFailed))});
        }
        if (currentlyScanning) |scanning| {
            if (scanning.len > 0) {
                try progressMessage.print(allocator, " | Scanning {s}", .{try pc.cyan(allocator, scanning)});
            }
        }
        if (dryRun) {
            try progressMessage.print(allocator, " | {s}", .{try pc.yellow(allocator, "DRY RUN")});
        }

        try progressMessage.appendSlice(allocator, " | Abort with Ctrl-C. It is safe to abort and resume later.");
        return progressMessage.items;
    }
};

//
// Command that adds files and directories to the Photosphere media file database.
//
pub fn addCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, paths: []const []const u8, options: *IAddCommandOptions) !void {
    const sessionId = context.sessionId;
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;

    // Validate that all paths exist before processing.
    for (paths) |filePath| {
        if (!pathExists(io, filePath)) {
            log.@"error"("");
            log.@"error"(try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} Path does not exist: {s}", .{try pc.cyan(allocator, filePath)})));
            log.@"error"(try pc.red(allocator, "  Please verify the path is correct and try again."));
            log.@"error"("");
            exit(io, 1);
        }
    }

    const loaded = try loadDatabase(allocator, io, options.base.db, &options.base, uuidGenerator, timestampProvider, sessionId, false);
    const databaseDir = loaded.databaseDir;
    const googleApiKey = try resolveGeocodingApiKey(allocator, io, loaded.geocodingKeyName);

    const storageDescriptor: IDatabaseDescriptor = .{
        .databasePath = databaseDir,
        .encryptionKey = options.base.key,
    };

    // With --watch the same import task is fed by a scanner that watches these folders and imports
    // what turns up, instead of walking them once. That is the only difference between the two:
    // everything below is shared, so `psi add` exercises nearly all of what a watch does.
    const watch = options.watch orelse false;
    const importOptions: ?IImportOptions = if (watch)
        .{
            .auto = true,
            .sources = (try watchSettings(allocator, io, paths)).sources,
        }
    else
        null;
    if (watch) {
        log.info(try pc.bold(allocator, "Watching for new media. Press Ctrl-C to stop."));
    }

    writeProgress("Searching for files...");

    var progressState: ProgressState = .{
        .options = options,
    };
    const progressCallback: AddPathsProgressCallback = .{
        .context = &progressState,
        .function = ProgressState.onProgress,
    };

    // An import reads its sources to the end and then stops, so a watch is that same import run
    // again and again, exactly as the desktop and mobile apps restart theirs. Ctrl-C ends the
    // process, which is what ends this loop.
    var addSummary: IAddSummary = undefined;
    while (true) {
        // Runs the import once over the paths, reporting progress as it goes.
        addSummary = try addPaths(
            allocator,
            io,
            uuidGenerator,
            storageDescriptor,
            paths,
            googleApiKey,
            sessionId,
            options.dryRun orelse false,
            progressCallback,
            importOptions,
        );
        if (!watch) {
            break;
        }
        try sleep(io, WATCH_RESTART_INTERVAL_MS);
    }

    clearProgressMessage(); // Flush the progress message.

    if (options.cleanup orelse false) {
        // After the import rather than during it, and as one walk rather than per file. The CLI has
        // no confirmation dialog in front of deleting a file, so unlike mobile it needs no button:
        // only what triggers this differs between the two, and it differs because only a phone puts
        // a system prompt in front of it.
        log.info(try pc.dim(allocator, "Looking for source files the database already holds..."));
        _ = try cleanUpImportedSources(allocator, io, uuidGenerator, storageDescriptor, try watchSettings(allocator, io, paths), sessionId);
        log.info("Source files deleted: ");
    }

    if (options.dryRun orelse false) {
        log.info(try pc.yellow(allocator, try std.fmt.allocPrint(allocator, "[DRY RUN] Would add {d} files to the media database.\n", .{addSummary.filesAdded})));
    }
    else {
        log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "Added {d} files to the media database.\n", .{addSummary.filesAdded})));
    }

    log.info(try pc.bold(allocator, "Summary:"));
    log.info(try std.fmt.allocPrint(allocator, "Files considered: {d}", .{addSummary.filesProcessed}));
    log.info(try std.fmt.allocPrint(allocator, "Files added:      {d}", .{addSummary.filesAdded}));
    log.info(try std.fmt.allocPrint(allocator, "Files ignored:    {d}", .{addSummary.filesIgnored}));
    log.info(try std.fmt.allocPrint(allocator, "Files failed:     {d}", .{addSummary.filesFailed}));
    log.info(try std.fmt.allocPrint(allocator, "Already added:    {d}", .{addSummary.filesAlreadyAdded}));
    log.info(try std.fmt.allocPrint(allocator, "Total size:       {s}", .{try formatBytes(allocator, addSummary.totalSize, defaultFormatBytesOptions)}));
    log.info(try std.fmt.allocPrint(allocator, "Average size:     {s}", .{try formatBytes(allocator, addSummary.averageSize, defaultFormatBytesOptions)}));

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
    log.info("    # Verify the integrity of all files in the database");
    log.info("    psi verify");
    log.info("");
    log.info("    # View database summary and tree hash");
    log.info("    psi summary");
    log.info("");
    log.info("    # Replicate the database to another location");
    log.info(try std.fmt.allocPrint(allocator, "    psi replicate --db {s} --dest <path>", .{databaseDir}));
    log.info("");
    log.info("    # Synchronize changes between two databases that have been independently changed");
    log.info(try std.fmt.allocPrint(allocator, "    psi sync --db {s} --dest <path>", .{databaseDir}));

    // A file that failed to import did not make it into the database, so the command did not do what
    // it was asked. The counts above say so on screen, but a script or a scheduled backup only reads
    // the exit code, and reporting success there is how an incomplete import goes unnoticed.
    if (addSummary.filesFailed > 0) {
        exit(io, 1);
    }
    else {
        exit(io, 0);
    }
}

//
// The places `--watch` watches: the folders named on the command line, or this operating system's
// own photo folders when none were.
//
// The pacing and the poll interval are not offered as options, so they stay at the shared defaults
// rather than being invented here: a watch from the CLI behaves exactly as the app's does.
//
pub fn watchSettings(allocator: std.mem.Allocator, io: std.Io, folders: []const []const u8) !IAutoImportSettings {
    const watchedFolders = if (folders.len > 0) folders else try getDefaultPhotoFolders(allocator, io);
    const sources = try allocator.alloc(IAutoImportSource, watchedFolders.len);
    for (watchedFolders, 0..) |folderPath, index| {
        sources[index] = .{
            .folder = .{
                .path = folderPath,
                .recurse = true,
            },
        };
    }
    var settings = DEFAULT_AUTO_IMPORT_SETTINGS;
    settings.enabled = true;
    settings.sources = sources;
    return settings;
}

//
// Deletes the source files the database is confirmed to hold, and returns how many went.
//
fn cleanUpImportedSources(
    allocator: std.mem.Allocator,
    io: std.Io,
    uuidGenerator: IUuidGenerator,
    storageDescriptor: IDatabaseDescriptor,
    settings: IAutoImportSettings,
    sessionId: []const u8,
) !usize {
    const queue = try TaskQueue.init(allocator, io, uuidGenerator, try std.fmt.allocPrint(allocator, "cleanup-{s}", .{sessionId}));
    defer queue.deinit();
    defer queue.shutdown();

    var taskData: std.json.ObjectMap = .empty;
    var descriptor: std.json.ObjectMap = .empty;
    try descriptor.put(allocator, "databasePath", .{ .string = storageDescriptor.databasePath });
    if (storageDescriptor.encryptionKey) |encryptionKey| {
        try descriptor.put(allocator, "encryptionKey", .{ .string = encryptionKey });
    }
    try taskData.put(allocator, "storageDescriptor", .{ .object = descriptor });
    try taskData.put(allocator, "settings", try autoImportSettingsToJson(allocator, settings));
    try taskData.put(allocator, "dryRun", .{ .bool = false });
    const taskId = try queue.addTask("cleanup-sources", .{ .object = taskData }, null, null);
    const taskResult = try queue.awaitTask(taskId);
    const outputs = if (taskResult) |result| result.outputs orelse std.json.Value.null else std.json.Value.null;
    if (outputs == .null) {
        return 0;
    }
    const cleanupResult = try std.json.parseFromValueLeaky(ICleanupSourcesResult, allocator, outputs, .{
        .ignore_unknown_fields = true,
    });

    if (cleanupResult.failedSourceIds.len > 0) {
        log.@"error"(try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} {d} source file(s) could not be deleted.", .{cleanupResult.failedSourceIds.len})));
    }
    return cleanupResult.deletedSourceIds.len;
}
