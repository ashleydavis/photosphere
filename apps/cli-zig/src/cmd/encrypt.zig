//
// In-place encrypt: transform the database at --db so that all files are encrypted
// (plain → encrypted, re-encrypt with new key, or old-format → new format).
//

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const encryption = @import("encryption-zig");
const vault_zig = @import("vault-zig");
const node_api = @import("node-api-zig");
const pc = @import("../lib/picocolors.zig");
const log_module = @import("../lib/log.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const storage_helper = @import("../lib/storage-helper.zig");
const terminal_utils = @import("../lib/terminal-utils.zig");
const directory_picker = @import("../lib/directory-picker.zig");
const prompts = @import("../lib/clack/prompts.zig");
const log = &utils.log.log;
const exportPublicKeyToPem = encryption.key_utils.exportPublicKeyToPem;
const loadEncryptionKeysFromPem = encryption.key_utils.loadEncryptionKeysFromPem;
const generateKeyPair = encryption.key_utils.generateKeyPair;
const exportPrivateKey = encryption.node_crypto.exportPrivateKey;
const exit = node_utils.termination.exit;
const getDirectoryForCommand = directory_picker.getDirectoryForCommand;
const resolveKeyPemsWithPrompt = init_cmd.resolveKeyPemsWithPrompt;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const promptForEncryption = init_cmd.promptForEncryption;
const selectEncryptionKey = init_cmd.selectEncryptionKey;
const configureS3IfNeeded = init_cmd.configureS3IfNeeded;
const createStorageForPath = storage_helper.createStorageForPath;
const getVault = vault_zig.get_vault.getVault;
const getDefaultVaultType = vault_zig.get_vault.getDefaultVaultType;
const writeProgress = terminal_utils.writeProgress;
const clearProgressMessage = terminal_utils.clearProgressMessage;
const confirm = prompts.confirm;
const isCancel = prompts.isCancel;
const merkleTreeExists = node_api.tree.merkleTreeExists;
const apiEncrypt = node_api.encrypt.encrypt;
const IEncryptProgress = node_api.encrypt.IEncryptProgress;
const configureLog = log_module.configureLog;

//
// Options of the encrypt command (TypeScript: IEncryptCommandOptions extends IBaseCommandOptions).
// The base options, which include `key` (the encryption key file(s), comma-separated, the first being the default
// key used for writing and for reading legacy-format files), are in `base`.
//
pub const IEncryptCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},

    //
    // Generate encryption key(s) if they do not exist.
    //
    generateKey: ?bool = null,
};

//
// Writes an encrypt progress message (TypeScript: the `(msg) => writeProgress(msg)` arrow function).
//
fn onEncryptProgress(context: ?*anyopaque, message: []const u8) void {
    _ = context;
    writeProgress(message);
}

//
// Encrypts the database at --db in place (plain → encrypted, re-encrypt, or old → new format).
//
pub fn encryptCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IEncryptCommandOptions) !void {
    _ = context;
    const verbose = options.base.verbose;
    const yes = options.base.yes;
    const cwd = options.base.cwd;
    const nonInteractive = yes orelse false;

    try configureLog(allocator, io, .{
        .verbose = verbose,
    });

    var dbDir: ?[]const u8 = options.base.db;
    if (dbDir == null) {
        dbDir = try getDirectoryForCommand(allocator, io, .existing, nonInteractive, cwd orelse try std.process.currentPathAlloc(io, allocator));
    }
    if (dbDir == null or dbDir.?.len == 0) {
        log.@"error"(try pc.red(allocator, "\u{2717} Database directory is required (--db)."));
        exit(io, 1);
    }
    const databaseDir = dbDir.?;

    if (std.mem.startsWith(u8, databaseDir, "s3:")) {
        _ = try configureS3IfNeeded(allocator, io, nonInteractive);
    }

    //
    // Key handling:
    // - In non-interactive mode we still require --key explicitly.
    // - In interactive mode, if --generate-key is set but no --key was provided,
    //   prompt the user for a key path (mirroring init behavior).
    //
    if (!nonInteractive and (options.base.key == null or options.base.key.?.len == 0)) {
        const result = try promptForEncryption(allocator, io, "Select the encryption key to use:");
        if (result.keyName != null and result.keyName.?.len > 0) {
            options.base.key = result.keyName;
        }
        else {
            const selectedKey = try selectEncryptionKey(allocator, io, "Select an encryption key:");
            options.base.key = selectedKey;
        }
    }

    // If --generate-key is set, generate the first key in the list if it doesn't exist in the vault.
    if ((options.generateKey orelse false) and options.base.key != null and options.base.key.?.len > 0) {
        var keyNames = std.mem.splitScalar(u8, options.base.key.?, ',');
        const firstKeyName = utils.js_string.trim(keyNames.first());
        const vault = try getVault(getDefaultVaultType());
        const existing = try vault.get(allocator, io, firstKeyName);
        if (existing == null) {
            const keyPair = try generateKeyPair(allocator, io);
            const privateKeyPem = try exportPrivateKey(allocator, keyPair.privateKey, .pem);
            try vault.set(allocator, io, .{
                .name = firstKeyName,
                .type = "encryption-key",
                .value = privateKeyPem,
            });
        }
    }

    const keyPems = try resolveKeyPemsWithPrompt(allocator, io, options.base.key, nonInteractive, true);
    if (keyPems.len == 0) {
        log.@"error"(try pc.red(allocator, "\u{2717} Encryption requires --key."));
        exit(io, 1);
    }

    const loaded = try loadEncryptionKeysFromPem(allocator, keyPems);
    const writeStorageOptions = loaded.options;
    if (!loaded.isEncrypted) {
        log.@"error"(try pc.red(allocator, "\u{2717} Failed to load encryption key."));
        exit(io, 1);
    }

    const rawStorage = (try createStorageForPath(allocator, io, databaseDir, null)).storage;
    const hasTree = try merkleTreeExists(allocator, io, rawStorage);
    if (!hasTree) {
        log.@"error"(try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} No database found at: {s}", .{try pc.cyan(allocator, databaseDir)})));
        exit(io, 1);
    }

    const readStorage = (try createStorageForPath(allocator, io, databaseDir, writeStorageOptions)).storage;
    const writeStorage = (try createStorageForPath(allocator, io, databaseDir, writeStorageOptions)).storage;

    if (nonInteractive) {
        if (!(yes orelse false)) {
            log.@"error"(try pc.red(allocator, "\u{2717} Non interactive encryption requires --yes to proceed."));
            exit(io, 1);
        }
    }
    else {
        log.warn(try pc.yellow(allocator, try std.fmt.allocPrint(allocator, "\u{26A0}\u{FE0F}  This will encrypt the database in place at {s} using key: {s}.", .{
            try pc.cyan(allocator, databaseDir),
            try pc.cyan(allocator, options.base.key orelse ""),
        })));
        log.warn(try pc.yellow(allocator, "   All files will be rewritten in encrypted form. This cannot be undone without the key."));
        const confirmed = try confirm(allocator, io, .{
            .message = "Proceed with encryption?",
            .initialValue = false,
        });
        if (isCancel(confirmed) or !confirmed.value) {
            log.info("Encryption cancelled.");
            exit(io, 0);
        }
    }

    writeProgress("Encrypting files...");

    const progressCallback: IEncryptProgress = .{
        .context = null,
        .function = onEncryptProgress,
    };
    const result = try apiEncrypt(allocator, io, readStorage, writeStorage, progressCallback, writeStorageOptions.encryptionPublicKey.?, rawStorage);

    clearProgressMessage();

    // Only after the entire database has been re-encrypted: write the public key to .db/encryption.pub.
    const publicKeyPem = try exportPublicKeyToPem(allocator, writeStorageOptions.encryptionPublicKey.?);
    try rawStorage.write(allocator, io, ".db/encryption.pub", null, publicKeyPem);

    log.info("");
    log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "\u{2705} Encrypted {d} files, {d} were already encrypted.", .{ result.encrypted, result.skipped })));
    exit(io, 0);
}
