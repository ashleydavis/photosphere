const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const storage_zig = @import("storage-zig");
const encryption = @import("encryption-zig");
const vault_zig = @import("vault-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const pc = @import("../lib/picocolors.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const storage_helper = @import("../lib/storage-helper.zig");
const terminal_utils = @import("../lib/terminal-utils.zig");
const directory_picker = @import("../lib/directory-picker.zig");
const prompts = @import("../lib/clack/prompts.zig");
const log = &utils.log.log;
const loadEncryptionKeysFromPem = encryption.key_utils.loadEncryptionKeysFromPem;
const pathJoin = storage_zig.storage_factory.pathJoin;
const generateKeyPair = encryption.key_utils.generateKeyPair;
const exportPrivateKey = encryption.node_crypto.exportPrivateKey;
const exit = node_utils.termination.exit;
const loadDatabase = init_cmd.loadDatabase;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const resolveKeyPemsWithPrompt = init_cmd.resolveKeyPemsWithPrompt;
const promptForEncryption = init_cmd.promptForEncryption;
const selectEncryptionKey = init_cmd.selectEncryptionKey;
const ICommandContext = init_cmd.ICommandContext;
const configureS3IfNeeded = init_cmd.configureS3IfNeeded;
const findSimilarKeyNames = init_cmd.findSimilarKeyNames;
const createStorageForPath = storage_helper.createStorageForPath;
const getVault = vault_zig.get_vault.getVault;
const getDefaultVaultType = vault_zig.get_vault.getDefaultVaultType;
const clearProgressMessage = terminal_utils.clearProgressMessage;
const writeProgress = terminal_utils.writeProgress;
const getDirectoryForCommand = directory_picker.getDirectoryForCommand;
const loadDatabaseConfig = api.database_config.loadDatabaseConfig;
const replicateDatabase = node_api.replicate_database.replicateDatabase;
const ReplicateProgressCallback = node_api.replicate_database.ReplicateProgressCallback;
const merkleTreeExists = node_api.tree.merkleTreeExists;
const confirm = prompts.confirm;
const select = prompts.select;
const isCancel = prompts.isCancel;

//
// Options of the replicate command (TypeScript: IReplicateCommandOptions extends IBaseCommandOptions).
// The base options are in `base`.
//
pub const IReplicateCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},

    //
    // Destination directory for replicated database.
    //
    dest: ?[]const u8 = null,

    //
    // Path to destination encryption key file.
    //
    destKey: ?[]const u8 = null,

    //
    // Generate encryption keys if they don't exist.
    //
    generateKey: ?bool = null,

    //
    // Path to a specific file or directory to replicate (instead of entire database).
    //
    path: ?[]const u8 = null,

    //
    // If true, allows replication even if destination has modifications not in source.
    //
    force: ?bool = null,

    //
    // If true, only copy thumb directory assets. Asset and display files will be lazily copied when needed.
    //
    partial: ?bool = null,

    //
    // If true, perform a full replication (copies all asset, display, and thumb files).
    //
    full: ?bool = null,
};

//
// JavaScript truthiness of an optional string.
//
fn isSet(value: ?[]const u8) bool {
    return value != null and value.?.len > 0;
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
// Writes each replication progress message (TypeScript: `progress => { writeProgress(`🔄 ${progress}`); }`).
//
fn onProgress(context: ?*anyopaque, progress: []const u8) void {
    _ = context;
    var buffer: [4096]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "\u{1F504} {s}", .{progress}) catch return;
    writeProgress(message);
}

//
// Command that replicates an asset database from source to destination.
//
pub fn replicateCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IReplicateCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;

    const nonInteractive = options.base.yes orelse false;

    if ((options.partial orelse false) and (options.full orelse false)) {
        log.@"error"(try pc.red(allocator, "\u{2717} --partial and --full cannot be used together. Please specify only one."));
        exit(io, 1);
    }

    // Load the source database for pre-flight validation (path resolution, encryption key check).
    // The worker re-resolves credentials internally; we only need srcDir and sourceRawAssetStorage here.
    var loadOptions: IBaseCommandOptions = .{
        .db = options.base.db,
        .key = options.base.key,
        .verbose = options.base.verbose,
        .yes = options.base.yes,
    };
    const loaded = try loadDatabase(allocator, io, options.base.db, &loadOptions, uuidGenerator, timestampProvider, sessionId, false);
    const sourceRawAssetStorage = loaded.rawAssetStorage;
    const srcDir = loaded.databaseDir;

    var destDirOption = options.dest;
    if (destDirOption == null) {
        const config = try loadDatabaseConfig(allocator, io, sourceRawAssetStorage);
        if (config) |configValue| {
            if (configValue == .object) {
                if (configValue.object.get("origin")) |origin| {
                    if (origin == .string) {
                        destDirOption = origin.string;
                    }
                }
            }
        }
        if (destDirOption == null) {
            const cwd = if (isSet(options.base.cwd)) options.base.cwd.? else try std.process.currentPathAlloc(io, allocator);
            destDirOption = try getDirectoryForCommand(allocator, io, .existing, nonInteractive, cwd);
        }
    }
    const destDir = destDirOption.?;

    //
    // If neither --partial nor --full was specified, prompt the user to choose.
    // In non-interactive (--yes) mode, default to full replication.
    //
    if (!(options.partial orelse false) and !(options.full orelse false)) {
        if (nonInteractive) {
            options.full = true;
        }
        else {
            const mode = try select(allocator, io, .{
                .message = "How would you like to replicate the database?",
                .options = &.{
                    .{
                        .value = "full",
                        .label = "Full",
                        .hint = "Copy everything \u{2014} all original, display, and thumbnail files",
                    },
                    .{
                        .value = "partial",
                        .label = "Partial",
                        .hint = "Copy only metadata and structure; asset files are fetched on demand from origin",
                    },
                },
            });

            if (isCancel(mode)) {
                log.info("Replication cancelled.");
                exit(io, 0);
            }

            options.partial = std.mem.eql(u8, mode.value, "partial");
            options.full = std.mem.eql(u8, mode.value, "full");
        }
    }

    const destMetaPath = try pathJoin(allocator, &.{ destDir, ".db" });

    if (std.mem.startsWith(u8, destDir, "s3:") or std.mem.startsWith(u8, destMetaPath, "s3:")) {
        _ = try configureS3IfNeeded(allocator, io, nonInteractive);
    }

    // Check if destination database already exists (using plain metadata probe storage)
    const destMetadataProbeStorage = (try createStorageForPath(allocator, io, destDir, null)).storage;

    // Check if destination database already has a files tree
    const destDbExists = try merkleTreeExists(allocator, io, destMetadataProbeStorage);
    if (destDbExists) {
        // Database already exists - check if it's encrypted
        const destDbIsEncrypted = try destMetadataProbeStorage.fileExists(allocator, io, ".db/encryption.pub");
        if (destDbIsEncrypted) {
            // Database is encrypted - user must provide a key
            if (!isSet(options.destKey)) {
                if (nonInteractive) {
                    log.@"error"(try pc.red(allocator, "\u{2717} The destination database is encrypted and requires a private key to access."));
                    log.@"error"(try pc.red(allocator, "  Please provide the private key using the --dest-key option."));
                    log.@"error"("");
                    log.@"error"("Example:");
                    log.@"error"(try std.fmt.allocPrint(allocator, "    {s}", .{try pc.cyan(allocator, try std.fmt.allocPrint(allocator, "psi replicate --dest-key my-photos.key --dest {s}", .{destDir}))}));
                    log.@"error"(try std.fmt.allocPrint(allocator, "    {s}", .{try pc.cyan(allocator, try std.fmt.allocPrint(allocator, "psi replicate --dest-key <full or relative path to key> --dest {s}", .{destDir}))}));
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
            const verifyKeyPems = try resolveKeyPemsWithPrompt(allocator, io, options.destKey, nonInteractive, false);
            if (verifyKeyPems.len == 0) {
                log.@"error"(try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} Encryption key \"{s}\" not found. Use \"psi secrets list\" to see available keys.", .{options.destKey orelse "undefined"})));
                const similarKeyNames = try findSimilarKeyNames(allocator, io, options.destKey.?);
                if (similarKeyNames.len > 0) {
                    log.info(try std.fmt.allocPrint(allocator, "Did you mean:\n{s}", .{try similarNamesList(allocator, similarKeyNames)}));
                }
                exit(io, 1);
            }
            _ = loadEncryptionKeysFromPem(allocator, verifyKeyPems) catch |err| {
                log.@"error"(try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} Failed to load encryption key: {s}", .{utils.errors.errorMessage(err)})));
                log.@"error"(try pc.red(allocator, "  Please check that the key exists. Use \"psi secrets list\" to see available keys."));
                exit(io, 1);
            };
        }
        else {
            // Database is not encrypted
            if (isSet(options.destKey)) {
                log.@"error"(try pc.red(allocator, "\u{2717} You specified an encryption key, but the destination database is not encrypted."));
                log.@"error"(try pc.red(allocator, "  Either remove the --dest-key option, or replicate to a different location to create a new encrypted database."));
                exit(io, 1);
            }
        }
    }
    else {
        // Database doesn't exist - ask about encryption if not already specified
        if (!isSet(options.destKey) and !(options.generateKey orelse false) and !nonInteractive) {
            const encryptionResult = try promptForEncryption(allocator, io, "Would you like to encrypt the destination database?");

            if (isSet(encryptionResult.keyName)) {
                options.destKey = encryptionResult.keyName;
                options.generateKey = encryptionResult.generateKey orelse false;
            }
        }
    }

    // If --generate-key is set, generate the dest key in the vault if it doesn't exist yet.
    if ((options.generateKey orelse false) and isSet(options.destKey)) {
        const vault = try getVault(getDefaultVaultType());
        const existing = try vault.get(allocator, io, options.destKey.?);
        if (existing == null) {
            const keyPair = try generateKeyPair(allocator, io);
            const privateKeyPem = try exportPrivateKey(allocator, keyPair.privateKey, .pem);
            try vault.set(allocator, io, .{
                .name = options.destKey.?,
                .type = "encryption-key",
                .value = privateKeyPem,
            });
        }
    }

    // Pre-flight: verify the dest key resolves to a real PEM (file path or vault entry) so we fail
    // early before queueing the task. The worker re-resolves the key internally via the same helper.
    if (isSet(options.destKey)) {
        const destKeyPems = try resolveKeyPemsWithPrompt(allocator, io, options.destKey, nonInteractive, true);
        if (destKeyPems.len == 0) {
            log.@"error"(try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} Encryption key \"{s}\" not found. Use \"psi secrets list\" to see available keys.", .{options.destKey.?})));
            const similarKeyNames = try findSimilarKeyNames(allocator, io, options.destKey.?);
            if (similarKeyNames.len > 0) {
                log.info(try std.fmt.allocPrint(allocator, "Did you mean:\n{s}", .{try similarNamesList(allocator, similarKeyNames)}));
            }
            exit(io, 1);
        }
        _ = try loadEncryptionKeysFromPem(allocator, destKeyPems);
    }

    // If destination database exists, warn user and ask for confirmation (unless --ues is used)
    if (destDbExists and !(options.base.yes orelse false)) {
        if (nonInteractive) {
            log.@"error"(try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} The destination database already exists at {s}.", .{destDir})));
            log.@"error"(try pc.red(allocator, "  Replication will overwrite any changes made to the destination database."));
            log.@"error"(try pc.red(allocator, "  Use the --force flag to proceed without confirmation."));
            exit(io, 1);
        }
        else {
            log.warn(try pc.yellow(allocator, try std.fmt.allocPrint(allocator, "\u{26A0}\u{FE0F}  The destination database already exists at {s}.", .{destDir})));
            log.warn(try pc.yellow(allocator, "    Replication will overwrite any changes made to the destination database."));
            log.info("");

            const confirmed = try confirm(allocator, io, .{
                .message = "Do you want to proceed with replication?\n" ++
                    "   This will cause the destination database to be updated to match the source database.\n" ++
                    "   Any changes you have made separately to the destination database will be overwritten.\n" ++
                    "   If you have made changes to the source and destination databases separately you should use the sync command instead.",
                .initialValue = false,
            });

            if (isCancel(confirmed) or !confirmed.value) {
                log.info("Replication cancelled.");
                exit(io, 0);
            }
        }
    }

    log.info("");
    log.info("Replicating database:");
    log.info(try std.fmt.allocPrint(allocator, "  Source:         {s}", .{try pc.cyan(allocator, srcDir)}));
    log.info(try std.fmt.allocPrint(allocator, "  Destination:    {s}", .{try pc.cyan(allocator, destDir)}));
    log.info("");

    writeProgress(if (isSet(options.path))
        try std.fmt.allocPrint(allocator, "Copying files matching: {s}...", .{options.path.?})
    else
        "Copying files...");

    // Delegate the actual replication to the shared queueing wrapper. The worker handler resolves
    // credentials, runs replicate(), writes the destination public key (when encrypted) and updates
    // the destination's database config - the CLI no longer does any of those itself.
    const progressCallback: ReplicateProgressCallback = .{ .context = null, .function = onProgress };
    const result = try replicateDatabase(allocator, io, uuidGenerator, .{
        .sourcePath = srcDir,
        .destPath = destDir,
        .sourceEncryptionKey = options.base.key,
        .destEncryptionKey = options.destKey,
        .destS3Key = null,
        .partial = options.partial orelse false,
        .force = options.force orelse false,
        .pathFilter = options.path,
    }, &progressCallback);

    clearProgressMessage(); // Flush the progress message.

    log.info(try pc.bold(allocator, try pc.blue(allocator, if (isSet(options.path))
        try std.fmt.allocPrint(allocator, "\u{1F4CA} Replication Results (filtered: {s})", .{options.path.?})
    else
        "\u{1F4CA} Replication Results")));
    log.info("");

    log.info(try std.fmt.allocPrint(allocator, "Total files imported:      {s}", .{try pc.cyan(allocator, try std.fmt.allocPrint(allocator, "{d}", .{result.filesImported}))}));
    log.info(try std.fmt.allocPrint(allocator, "Total files copied:        {s}", .{if (result.copiedFiles > 0) try pc.green(allocator, try std.fmt.allocPrint(allocator, "{d}", .{result.copiedFiles})) else "0"}));
    log.info("");
    log.info(try std.fmt.allocPrint(allocator, "Total records copied:      {s}", .{if (result.copiedRecords > 0) try pc.green(allocator, try std.fmt.allocPrint(allocator, "{d}", .{result.copiedRecords})) else "0"}));

    // Print pruned files if any
    if (result.prunedFiles.len > 0) {
        log.info("");
        log.info(try std.fmt.allocPrint(allocator, "Files pruned from destination: {s}", .{try pc.red(allocator, try std.fmt.allocPrint(allocator, "{d}", .{result.prunedFiles.len}))}));
        for (result.prunedFiles) |fileName| {
            log.info(try std.fmt.allocPrint(allocator, "  {s} {s}", .{ try pc.red(allocator, "\u{2717}"), fileName }));
        }
    }

    log.info("");
    log.info(try pc.green(allocator, "\u{2705} Replication completed successfully"));

    log.info("");
    log.info(try pc.blue(allocator, "\u{1F4A1} Tip: You can run this command again anytime to update your replica when the source database changes."));

    // Show follow-up commands
    log.info("");
    log.info(try pc.bold(allocator, "Next steps:"));
    log.info("    # Verify the integrity of the replicated database");
    log.info(try std.fmt.allocPrint(allocator, "    psi verify --db {s}", .{destDir}));
    log.info("");
    log.info("    # Compare source and destination databases");
    log.info(try std.fmt.allocPrint(allocator, "    psi compare --db {s} --dest {s}", .{ srcDir, destDir }));
    log.info("");
    log.info("    # Synchronize changes between two databases that have been independently changed");
    log.info(try std.fmt.allocPrint(allocator, "    psi sync --db {s} --dest {s}", .{ srcDir, destDir }));
    log.info("");
    log.info("    # View summary of the replicated database");
    log.info(try std.fmt.allocPrint(allocator, "    psi summary --db {s}", .{destDir}));

    exit(io, 0);
}
