//
// In-place decrypt: transform the database at --db so that all files are plain
// (encrypted → plain). Removes .db/encryption.pub at the end.
//

const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const encryption = @import("encryption-zig");
const node_api = @import("node-api-zig");
const pc = @import("../lib/picocolors.zig");
const log_module = @import("../lib/log.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const storage_helper = @import("../lib/storage-helper.zig");
const terminal_utils = @import("../lib/terminal-utils.zig");
const directory_picker = @import("../lib/directory-picker.zig");
const prompts = @import("../lib/clack/prompts.zig");
const log = &utils.log.log;
const loadEncryptionKeysFromPem = encryption.key_utils.loadEncryptionKeysFromPem;
const exit = node_utils.termination.exit;
const getDirectoryForCommand = directory_picker.getDirectoryForCommand;
const resolveKeyPems = init_cmd.resolveKeyPems;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const configureS3IfNeeded = init_cmd.configureS3IfNeeded;
const createStorageForPath = storage_helper.createStorageForPath;
const writeProgress = terminal_utils.writeProgress;
const clearProgressMessage = terminal_utils.clearProgressMessage;
const confirm = prompts.confirm;
const isCancel = prompts.isCancel;
const apiDecrypt = node_api.decrypt.decrypt;
const IDecryptProgress = node_api.decrypt.IDecryptProgress;
const configureLog = log_module.configureLog;

//
// Options of the decrypt command (TypeScript: IDecryptCommandOptions extends IBaseCommandOptions).
// The base options, which include `key` (the encryption key file(s) used to read the source database,
// comma-separated), are in `base`.
//
pub const IDecryptCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},
};

//
// Writes a decrypt progress message (TypeScript: the `(msg) => writeProgress(msg)` arrow function).
//
fn onDecryptProgress(context: ?*anyopaque, message: []const u8) void {
    _ = context;
    writeProgress(message);
}

//
// Decrypts the database at --db in place (encrypted → plain). Removes .db/encryption.pub.
//
pub fn decryptCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IDecryptCommandOptions) !void {
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

    const keyPems = try resolveKeyPems(allocator, io, options.base.key);
    if (keyPems.len == 0) {
        log.@"error"(try pc.red(allocator, "\u{2717} Decryption requires --key."));
        exit(io, 1);
    }

    const readStorageOptions = (try loadEncryptionKeysFromPem(allocator, keyPems)).options;

    const rawStorage = (try createStorageForPath(allocator, io, databaseDir, null)).storage;
    const hasEncryptionPub = try rawStorage.fileExists(allocator, io, ".db/encryption.pub");
    if (!hasEncryptionPub) {
        log.@"error"(try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} Database at {s} does not appear to be encrypted (no .db/encryption.pub).", .{try pc.cyan(allocator, databaseDir)})));
        exit(io, 1);
    }

    const readStorage = (try createStorageForPath(allocator, io, databaseDir, readStorageOptions)).storage;

    if (nonInteractive) {
        if (!(yes orelse false)) {
            log.@"error"(try pc.red(allocator, "\u{2717} Non interactive decryption requires --yes to proceed."));
            exit(io, 1);
        }
    }
    else {
        log.warn(try pc.yellow(allocator, try std.fmt.allocPrint(allocator, "\u{26A0}\u{FE0F}  This will decrypt the database in place at {s} using key: {s}.", .{
            try pc.cyan(allocator, databaseDir),
            try pc.cyan(allocator, options.base.key orelse ""),
        })));
        log.warn(try pc.yellow(allocator, "   All files will be rewritten in plain form. The database will no longer be encrypted."));
        const confirmed = try confirm(allocator, io, .{
            .message = "Proceed with decryption?",
            .initialValue = false,
        });
        if (isCancel(confirmed) or !confirmed.value) {
            log.info("Decryption cancelled.");
            exit(io, 0);
        }
    }

    writeProgress("Decrypting files...");

    const progressCallback: IDecryptProgress = .{
        .context = null,
        .function = onDecryptProgress,
    };
    const result = try apiDecrypt(allocator, io, readStorage, rawStorage, progressCallback, rawStorage);

    clearProgressMessage();

    try rawStorage.deleteFile(allocator, io, ".db/encryption.pub");

    log.info("");
    log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "\u{2705} Decrypted {d} files, {d} were already plain.", .{ result.decrypted, result.skipped })));
    exit(io, 0);
}
