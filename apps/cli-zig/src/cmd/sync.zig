const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const encryption = @import("encryption-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const pc = @import("../lib/picocolors.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const directory_picker = @import("../lib/directory-picker.zig");
const storage_helper = @import("../lib/storage-helper.zig");
const sync_watch = @import("../lib/sync-watch.zig");
const log = &utils.log.log;
const exit = node_utils.termination.exit;
const registerTerminationCallback = node_utils.termination.registerTerminationCallback;
const loadDatabase = init_cmd.loadDatabase;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const IInitResult = init_cmd.IInitResult;
const selectEncryptionKey = init_cmd.selectEncryptionKey;
const resolveKeyPemsWithPrompt = init_cmd.resolveKeyPemsWithPrompt;
const configureS3IfNeeded = init_cmd.configureS3IfNeeded;
const findSimilarKeyNames = init_cmd.findSimilarKeyNames;
const getDirectoryForCommand = directory_picker.getDirectoryForCommand;
const loadDatabaseConfig = api.database_config.loadDatabaseConfig;
const syncDatabases = node_api.sync.syncDatabases;
const merkleTreeExists = node_api.tree.merkleTreeExists;
const isDatabaseEncrypted = node_api.tree.isDatabaseEncrypted;
const loadEncryptionKeysFromPem = encryption.key_utils.loadEncryptionKeysFromPem;
const createStorageForPath = storage_helper.createStorageForPath;
const parseWatchInterval = sync_watch.parseWatchInterval;
const runSyncWatch = sync_watch.runSyncWatch;

//
// Options for the sync command (TypeScript: ISyncCommandOptions extends IBaseCommandOptions).
// The base options are in `base`.
//
pub const ISyncCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},

    //
    // Destination database (optional; defaults to origin from config).
    //
    dest: ?[]const u8 = null,

    //
    // Path to destination encryption key file.
    //
    destKey: ?[]const u8 = null,

    //
    // Keep syncing as the database changes, rather than syncing once and exiting.
    //
    watch: ?bool = null,

    //
    // How long to wait between syncs when watching, in seconds.
    //
    interval: ?[]const u8 = null,
};

//
// JavaScript truthiness of an optional string.
//
fn isSet(value: ?[]const u8) bool {
    return value != null and value.?.len > 0;
}

//
// Gets `config?.origin` (null when the config or its origin is missing, or the origin is not a string).
//
pub fn configOrigin(config: ?std.json.Value) ?[]const u8 {
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
// Formats the "Did you mean" list of similar key names
// (TypeScript: `similarKeyNames.map(similarName => `  • ${pc.cyan(similarName)}`).join('\n')`).
//
fn similarNamesList(allocator: std.mem.Allocator, similarKeyNames: []const []const u8) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    for (similarKeyNames) |similarName| {
        try lines.append(allocator, try std.fmt.allocPrint(allocator, "  \u{2022} {s}", .{try pc.cyan(allocator, similarName)}));
    }
    return std.mem.join(allocator, "\n", lines.items);
}

//
// What a sync watch runs (TypeScript: the variables the syncOnce, isStopped and termination arrow functions capture).
//
const ISyncWatchState = struct {
    // Allocates what each sync keeps.
    allocator: std.mem.Allocator,

    // The source database.
    source: IInitResult,

    // The target database.
    target: IInitResult,

    // The session id of the write locks.
    sessionId: []const u8,

    // Set once the process is told to terminate (written by the signal watcher thread).
    stopped: std.atomic.Value(bool) = .init(false),

    //
    // Runs one sync (TypeScript: `() => syncDatabases(...)`).
    //
    fn syncOnce(context: ?*anyopaque, io: std.Io) anyerror!bool {
        const self: *ISyncWatchState = @ptrCast(@alignCast(context.?));
        const result = try syncDatabases(self.allocator, io, self.source.assetStorage, self.source.rawAssetStorage, self.source.bsonDatabase, self.target.assetStorage, self.target.rawAssetStorage, self.target.bsonDatabase, self.sessionId, null);
        return result.synced;
    }

    //
    // True once the watch should stop (TypeScript: `() => stopped`).
    //
    fn isStopped(context: ?*anyopaque) bool {
        const self: *ISyncWatchState = @ptrCast(@alignCast(context.?));
        return self.stopped.load(.acquire);
    }

    //
    // Stops the watch when the process is told to terminate (TypeScript: `async () => { stopped = true; }`).
    //
    fn stop(context: ?*anyopaque, io: std.Io, exitCode: u8) anyerror!void {
        _ = io;
        _ = exitCode;
        const self: *ISyncWatchState = @ptrCast(@alignCast(context.?));
        self.stopped.store(true, .release);
    }
};

//
// Sync command implementation - synchronizes databases according to the sync specification.
//
pub fn syncCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *ISyncCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;

    const nonInteractive = options.base.yes orelse false;

    // Load source database first so we can read origin if --dest not provided
    var sourceOptions: IBaseCommandOptions = .{
        .db = options.base.db,
        .key = options.base.key,
        .verbose = options.base.verbose,
        .yes = options.base.yes,
    };
    const source = try loadDatabase(allocator, io, options.base.db, &sourceOptions, uuidGenerator, timestampProvider, sessionId, false);

    var destPathOption = options.dest;
    if (destPathOption == null) {
        const config = try loadDatabaseConfig(allocator, io, source.rawAssetStorage);
        destPathOption = configOrigin(config);
        if (destPathOption == null) {
            const cwd = if (isSet(options.base.cwd)) options.base.cwd.? else try std.process.currentPathAlloc(io, allocator);
            destPathOption = try getDirectoryForCommand(allocator, io, .existing, nonInteractive, cwd);
        }
    }
    const destPath = destPathOption.?;

    log.info("Starting database sync operation...");
    log.info(try std.fmt.allocPrint(allocator, "  Source:    {s}", .{try pc.cyan(allocator, if (isSet(options.base.db)) options.base.db.? else ".")}));
    log.info(try std.fmt.allocPrint(allocator, "  Target:    {s}", .{try pc.cyan(allocator, destPath)}));
    log.info("");

    // Check if destination database exists and handle encryption (storage scoped to db root, paths use .db/...)
    if (std.mem.startsWith(u8, destPath, "s3:")) {
        _ = try configureS3IfNeeded(allocator, io, nonInteractive);
    }

    const destMetadataStorage = (try createStorageForPath(allocator, io, destPath, null)).storage;

    // Check if destination database exists (uses .db/files.dat from API)
    const destDbExists = try merkleTreeExists(allocator, io, destMetadataStorage);
    if (destDbExists) {
        // Database exists - check if it's encrypted
        const destDbIsEncrypted = try isDatabaseEncrypted(allocator, io, destMetadataStorage);
        if (destDbIsEncrypted) {
            // Database is encrypted - user must provide a key
            if (!isSet(options.destKey)) {
                if (nonInteractive) {
                    log.@"error"(try pc.red(allocator, "\u{2717} The destination database is encrypted and requires a private key to access."));
                    log.@"error"(try pc.red(allocator, "  Please provide the private key using the --dest-key option."));
                    log.@"error"("");
                    log.@"error"("Example:");
                    log.@"error"(try std.fmt.allocPrint(allocator, "    {s}", .{try pc.cyan(allocator, try std.fmt.allocPrint(allocator, "psi sync --dest-key my-photos.key --dest {s}", .{destPath}))}));
                    log.@"error"(try std.fmt.allocPrint(allocator, "    {s}", .{try pc.cyan(allocator, try std.fmt.allocPrint(allocator, "psi sync --dest-key <full or relative path to key> --dest {s}", .{destPath}))}));
                    exit(io, 1);
                }
                else {
                    // Interactive mode - show key selection menu
                    log.info(try pc.yellow(allocator, "The destination database is encrypted and requires a private key to access."));

                    // Show menu of available keys
                    const selectedKey = try selectEncryptionKey(allocator, io, "Select the encryption key for the destination database:");
                    options.destKey = selectedKey;
                }
            }

            // Verify the key works by trying to load encryption keys
            const destKeyPems = try resolveKeyPemsWithPrompt(allocator, io, options.destKey, nonInteractive, false);
            if (destKeyPems.len == 0) {
                log.@"error"(try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} Encryption key \"{s}\" not found. Use \"psi secrets list\" to see available keys.", .{options.destKey orelse "undefined"})));
                const similarKeyNames = try findSimilarKeyNames(allocator, io, options.destKey.?);
                if (similarKeyNames.len > 0) {
                    log.info(try std.fmt.allocPrint(allocator, "Did you mean:\n{s}", .{try similarNamesList(allocator, similarKeyNames)}));
                }
                exit(io, 1);
            }
            _ = loadEncryptionKeysFromPem(allocator, destKeyPems) catch |err| {
                log.@"error"(try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} Failed to load encryption key: {s}", .{utils.errors.errorMessage(err)})));
                log.@"error"(try pc.red(allocator, "  Please check that the key exists. Use \"psi secrets list\" to see available keys."));
                exit(io, 1);
            };
        }
        else {
            // Database is not encrypted
            if (isSet(options.destKey)) {
                log.@"error"(try pc.red(allocator, "\u{2717} You specified an encryption key, but the destination database is not encrypted."));
                log.@"error"(try pc.red(allocator, "  Either remove the --dest-key option, or sync to a different location."));
                exit(io, 1);
            }
        }
    }

    // Load target database with target options (using destKey instead of key)
    var targetOptions: IBaseCommandOptions = options.base;
    targetOptions.db = destPath;
    targetOptions.key = options.destKey; // Use destKey for target database
    const target = try loadDatabase(allocator, io, targetOptions.db, &targetOptions, uuidGenerator, timestampProvider, sessionId, false);

    if (options.watch orelse false) {
        // Run the same sync over and over as the database changes, rather than once. Paired with
        // `psi add --watch` in another process this is what `psi watch` used to be, except that each
        // half is separately useful and separately testable, where before it was both or neither.
        const state = try allocator.create(ISyncWatchState);
        state.* = .{
            .allocator = allocator,
            .source = source,
            .target = target,
            .sessionId = sessionId,
        };
        try registerTerminationCallback(io, .{
            .context = state,
            .function = ISyncWatchState.stop,
        });

        try runSyncWatch(allocator, io, .{
            .intervalSeconds = try parseWatchInterval(options.interval),
            .context = state,
            .syncOnce = ISyncWatchState.syncOnce,
            .isStopped = ISyncWatchState.isStopped,
        });
        return;
    }

    // syncDatabases records lastSyncedAt and the content hash in both state files when it runs.
    const result = try syncDatabases(allocator, io, source.assetStorage, source.rawAssetStorage, source.bsonDatabase, target.assetStorage, target.rawAssetStorage, target.bsonDatabase, sessionId, null);

    if (result.synced) {
        log.info("Sync completed successfully!");
    }
    else {
        log.info("Databases already in sync, nothing to do.");
    }

    exit(io, 0);
}
