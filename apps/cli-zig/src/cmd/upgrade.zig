const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const storage_zig = @import("storage-zig");
const encryption = @import("encryption-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const bdb = @import("bdb-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const pc = @import("../lib/picocolors.zig");
const init_cmd = @import("../lib/init-cmd.zig");
const storage_helper = @import("../lib/storage-helper.zig");
const directory_picker = @import("../lib/directory-picker.zig");
const ensure_tools = @import("../lib/ensure-tools.zig");
const prompts = @import("../lib/clack/prompts.zig");
const log = &utils.log.log;
const retry = utils.retry.retry;
const throwError = utils.errors.throwError;
const errorMessage = utils.errors.errorMessage;
const exit = node_utils.termination.exit;
const IBaseCommandOptions = init_cmd.IBaseCommandOptions;
const ICommandContext = init_cmd.ICommandContext;
const resolveKeyPems = init_cmd.resolveKeyPems;
const resolveKeyPemsWithPrompt = init_cmd.resolveKeyPemsWithPrompt;
const selectEncryptionKey = init_cmd.selectEncryptionKey;
const configureS3IfNeeded = init_cmd.configureS3IfNeeded;
const createStorageForPath = storage_helper.createStorageForPath;
const getDirectoryForCommand = directory_picker.getDirectoryForCommand;
const ensureMediaProcessingTools = ensure_tools.ensureMediaProcessingTools;
const intro = prompts.intro;
const confirm = prompts.confirm;
const outro = prompts.outro;
const isCancel = prompts.isCancel;
const loadEncryptionKeysFromPem = encryption.key_utils.loadEncryptionKeysFromPem;
const IEncryptionKeyPem = encryption.key_utils.IEncryptionKeyPem;
const merkle_tree = merkle_tree_zig.merkle_tree;
const addItem = merkle_tree.addItem;
const CURRENT_DATABASE_VERSION = merkle_tree.CURRENT_DATABASE_VERSION;
const loadTree = merkle_tree.loadTree;
const rebuildTree = merkle_tree.rebuildTree;
const saveTree = merkle_tree.saveTree;
const IMerkleTree = merkle_tree.IMerkleTree;
const SortNode = merkle_tree.SortNode;
const traverseTreeAsync = merkle_tree_zig.traverse.traverseTreeAsync;
const acquireWriteLock = api.write_lock.acquireWriteLock;
const releaseWriteLock = api.write_lock.releaseWriteLock;
const loadDatabaseConfig = api.database_config.loadDatabaseConfig;
const saveDatabaseConfig = api.database_config.saveDatabaseConfig;
const createReadme = node_api.media_file_database.createReadme;
const ensureSortIndex = node_api.media_file_database.ensureSortIndex;
const computeHash = node_api.hash.computeHash;
const BsonDatabase = bdb.database.BsonDatabase;
const buildDatabaseMerkleTree = bdb.merkle_tree.buildDatabaseMerkleTree;
const deleteDatabaseMerkleTree = bdb.merkle_tree.deleteDatabaseMerkleTree;
const saveDatabaseMerkleTree = bdb.merkle_tree.saveDatabaseMerkleTree;
const IStorage = storage_zig.storage.IStorage;
const IFileInfo = storage_zig.storage.IFileInfo;
const pathJoin = storage_zig.storage_factory.pathJoin;
const walkDirectory = storage_zig.walk_directory.walkDirectory;

//
// Options of the upgrade command (TypeScript: IUpgradeCommandOptions extends IBaseCommandOptions).
// The base options, which include `yes`, are in `base`.
//
pub const IUpgradeCommandOptions = struct {
    // The options shared by every command.
    base: IBaseCommandOptions = .{},
};

//
// First DB version that stores .db/ files encrypted when the database is encrypted.
// Re-encrypt .db/ only when upgrading from before this version.
//
const FIRST_VERSION_WITH_ENCRYPTED_DOT_DB = 6;

//
// `() => loadTree(filePath, assetStorage)`.
//
fn LoadTreeOperation(comptime sourceText: []const u8) type {
    return struct {
        // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
        pub const source = sourceText;

        // Allocates the loaded tree.
        allocator: std.mem.Allocator,

        // The path of the tree file.
        filePath: []const u8,

        // The database storage.
        storage: IStorage,

        //
        // Loads the tree.
        //
        pub fn run(self: *@This(), io: std.Io) !?IMerkleTree {
            return loadTree(self.allocator, io, self.filePath, self.storage, "FTRE");
        }
    };
}

//
// `() => saveTree(".db/files.dat", merkleTree!, assetStorage)`.
//
const SaveTreeOperation = struct {
    // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
    pub const source = "() => saveTree(\".db/files.dat\", merkleTree, assetStorage)";

    // Allocates the serialized data.
    allocator: std.mem.Allocator,

    // The tree to save.
    merkleTree: *const IMerkleTree,

    // The database storage.
    storage: IStorage,

    //
    // Saves the tree.
    //
    pub fn run(self: *SaveTreeOperation, io: std.Io) !void {
        return saveTree(self.allocator, io, ".db/files.dat", self.merkleTree, self.storage, "FTRE");
    }
};

//
// What the traversal that fills in missing lastModified values needs (TypeScript: the variables the callback captures).
//
const IFillLastModifiedContext = struct {
    // Allocates the file information.
    allocator: std.mem.Allocator,

    // Used for the storage calls.
    io: std.Io,

    // The database storage.
    assetStorage: IStorage,
};

//
// Fills in the missing lastModified of a leaf from its file information (TypeScript: the traverseTreeAsync callback).
//
fn fillLastModified(context: *const IFillLastModifiedContext, node: *SortNode) anyerror!bool {
    if (node.name) |name| {
        if (node.lastModified == null or node.lastModified.? == 0) {
            const fileInfo = try context.assetStorage.info(context.allocator, context.io, name);
            if (fileInfo) |info| {
                // Fill in missing lastModified from file info
                node.lastModified = info.lastModified;
            }
        }
    }
    return true; // Continue traversal
}

//
// Computes the hash of a file in storage (TypeScript: `computeHash(await assetStorage.readStream(file))`).
//
fn computeStorageHash(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, fileName: []const u8) ![32]u8 {
    const stream = try storage.readStream(allocator, io, fileName);
    defer stream.destroy(io);
    return computeHash(stream.reader());
}

//
// Command that upgrades a Photosphere media file database to the latest format.
//
pub fn upgradeCommand(allocator: std.mem.Allocator, io: std.Io, context: ICommandContext, options: *IUpgradeCommandOptions) !void {
    const uuidGenerator = context.uuidGenerator;
    const timestampProvider = context.timestampProvider;
    const sessionId = context.sessionId;

    try intro(io, try pc.blue(allocator, "Upgrading media file database..."), .{});

    const nonInteractive = options.base.yes orelse false;
    try ensureMediaProcessingTools(allocator, io, nonInteractive);

    var databaseDir: []const u8 = undefined;
    if (options.base.db) |db| {
        databaseDir = db;
    }
    else {
        const cwd = if (options.base.cwd != null and options.base.cwd.?.len > 0) options.base.cwd.? else try std.process.currentPathAlloc(io, allocator);
        databaseDir = try getDirectoryForCommand(allocator, io, .existing, nonInteractive, cwd);
    }

    const metaPath = try pathJoin(allocator, &.{ databaseDir, ".db" });
    if (std.mem.startsWith(u8, databaseDir, "s3:") or std.mem.startsWith(u8, metaPath, "s3:")) {
        _ = try configureS3IfNeeded(allocator, io, nonInteractive);
    }

    var keyPems: []const IEncryptionKeyPem = try resolveKeyPemsWithPrompt(allocator, io, options.base.key, nonInteractive, false);
    if (options.base.key != null and options.base.key.?.len > 0 and keyPems.len == 0) {
        try outro(io, try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} Encryption key \"{s}\" not found.\n  Use \"psi secrets list\" to see available keys.", .{options.base.key.?})), .{});
        exit(io, 1);
    }
    var storageOptions = (try loadEncryptionKeysFromPem(allocator, keyPems)).options;
    const created = try createStorageForPath(allocator, io, databaseDir, storageOptions);
    var assetStorage = created.storage;
    const rawStorage = created.rawStorage;

    const hasFilesDat = try assetStorage.fileExists(allocator, io, ".db/files.dat");
    const hasTreeDat = try assetStorage.fileExists(allocator, io, ".db/tree.dat");
    if (!hasFilesDat and !hasTreeDat) {
        try outro(io, try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} No database found at: {s}\n  The database directory must contain a \".db\" folder with files.dat or tree.dat.\n\nTo create a new database at this directory, use:\n  {s}", .{
            try pc.cyan(allocator, databaseDir),
            try pc.cyan(allocator, try std.fmt.allocPrint(allocator, "psi init --db {s}", .{databaseDir})),
        })), .{});
        exit(io, 1);
    }

    if (try assetStorage.fileExists(allocator, io, ".db/encryption.pub")) {
        if (keyPems.len == 0) {
            if (nonInteractive) {
                try outro(io, try pc.red(allocator, "\u{2717} This database is encrypted and requires a private key to access.\n  Please provide the private key using the --key option."), .{});
                exit(io, 1);
            }
            log.info(try pc.yellow(allocator, "This database is encrypted and requires a private key to access."));
            const selectedKey = try selectEncryptionKey(allocator, io, "Select the encryption key for this database:");
            options.base.key = selectedKey;
            keyPems = try resolveKeyPems(allocator, io, options.base.key);
            storageOptions = (try loadEncryptionKeysFromPem(allocator, keyPems)).options;
            assetStorage = (try createStorageForPath(allocator, io, databaseDir, storageOptions)).storage;
        }
    }

    // Load from .db/files.dat (v6) or .db/tree.dat (legacy). Upgrade will write .db/files.dat and remove .db/tree.dat.
    var loadFilesOperation: LoadTreeOperation("() => loadTree(\".db/files.dat\", assetStorage)") = .{
        .allocator = allocator,
        .filePath = ".db/files.dat",
        .storage = assetStorage,
    };
    var loadedTree = try retry(io, &loadFilesOperation, 3, 1_000, 2, 30_000, null);
    if (loadedTree == null) {
        var loadLegacyOperation: LoadTreeOperation("() => loadTree(\".db/tree.dat\", assetStorage)") = .{
            .allocator = allocator,
            .filePath = ".db/tree.dat",
            .storage = assetStorage,
        };
        loadedTree = try retry(io, &loadLegacyOperation, 3, 1_000, 2, 30_000, null);
    }
    var merkleTree = loadedTree orelse {
        return throwError("Failed to load merkle tree (no .db/files.dat or .db/tree.dat found)", .{});
    };

    const currentVersion = merkleTree.version;

    log.info(try std.fmt.allocPrint(allocator, "\u{2713} Found database version {d}", .{currentVersion}));

    if (currentVersion == CURRENT_DATABASE_VERSION) {
        log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "\u{2713} Database is already at the latest version ({d})", .{CURRENT_DATABASE_VERSION})));
        exit(io, 0);
    }
    else if (currentVersion >= CURRENT_DATABASE_VERSION) {
        try outro(io, try pc.red(allocator, try std.fmt.allocPrint(allocator, "\u{2717} Database version {d} is newer than the current supported version {d}.\n  Please update your Photosphere CLI tool.", .{ currentVersion, CURRENT_DATABASE_VERSION })), .{});
        exit(io, 1);
    }

    log.warn(try pc.yellow(allocator, "\u{26A0}\u{FE0F}  IMPORTANT: Database upgrade will modify your database files."));
    log.warn(try pc.yellow(allocator, "    It is strongly recommended to backup your database before proceeding."));
    log.warn(try pc.yellow(allocator, "    You can backup your database by copying the entire directory:"));

    // Provide platform-specific backup commands
    if (builtin.os.tag == .windows) {
        log.warn(try pc.yellow(allocator, try std.fmt.allocPrint(allocator, "    xcopy \"{s}\" \"{s}-backup\" /E /I", .{ databaseDir, databaseDir })));
    }
    else {
        log.warn(try pc.yellow(allocator, try std.fmt.allocPrint(allocator, "    cp -r \"{s}\" \"{s}-backup\"", .{ databaseDir, databaseDir })));
    }
    log.info("");

    var shouldProceed: bool = undefined;

    if (options.base.yes orelse false) {
        // Non-interactive mode: proceed automatically
        log.info(try pc.blue(allocator, "\u{2713} Non-interactive mode: proceeding with database upgrade"));
        shouldProceed = true;
    }
    else {
        // Interactive mode: ask for confirmation
        const confirmResult = try confirm(allocator, io, .{
            .message = try std.fmt.allocPrint(allocator, "Do you want to proceed with upgrading from version {d} to version {d}?", .{ currentVersion, CURRENT_DATABASE_VERSION }),
            .initialValue = false,
        });
        shouldProceed = !isCancel(confirmResult) and confirmResult.value;
    }

    if (!shouldProceed) {
        try outro(io, "Database upgrade cancelled.", .{});
        exit(io, 0);
    }

    log.info(try std.fmt.allocPrint(allocator, "Upgrading database from version {d} to version {d}...", .{ currentVersion, CURRENT_DATABASE_VERSION }));

    // Acquire write lock before making changes
    if (!try acquireWriteLock(allocator, io, assetStorage, sessionId, 3)) {
        return throwError("Failed to acquire write lock for database upgrade.", .{});
    }

    upgradeLocked(allocator, io, uuidGenerator, timestampProvider, assetStorage, rawStorage, keyPems, currentVersion, &merkleTree, databaseDir) catch |err| {
        try releaseWriteLock(allocator, io, assetStorage);
        return err;
    };
    try releaseWriteLock(allocator, io, assetStorage);

    exit(io, 0);
}

//
// The part of upgradeCommand that runs while the write lock is held (TypeScript: the body of the try block).
//
fn upgradeLocked(
    allocator: std.mem.Allocator,
    io: std.Io,
    uuidGenerator: utils.uuid_generator.IUuidGenerator,
    timestampProvider: utils.timestamp_provider.ITimestampProvider,
    assetStorage: IStorage,
    rawStorage: IStorage,
    keyPems: []const IEncryptionKeyPem,
    currentVersion: u32,
    merkleTreeInOut: *IMerkleTree,
    databaseDir: []const u8,
) !void {
    var merkleTree = merkleTreeInOut.*;

    // Fill in missing lastModified from file info using async binary tree traversal.
    const fillContext: IFillLastModifiedContext = .{
        .allocator = allocator,
        .io = io,
        .assetStorage = assetStorage,
    };
    try traverseTreeAsync(SortNode, merkleTree.sort, &fillContext, fillLastModified);

    if (try assetStorage.dirExists(allocator, io, "assets")) {

        log.info("Moving files from 'assets' directory to 'asset' directory...");

        //
        // Move files and add them to the merkle tree.
        //
        var next: ?[]const u8 = null;
        var filesMoved: usize = 0;

        while (true) {
            const assetsFiles = try assetStorage.listFiles(allocator, io, "assets", 1000, next);

            for (assetsFiles.names) |fileName| {
                const sourceFile = try pathJoin(allocator, &.{ "assets", fileName });
                const destFile = try pathJoin(allocator, &.{ "asset", fileName });

                // Get file info and compute hash of source file
                const fileInfo = try assetStorage.info(allocator, io, sourceFile);
                if (fileInfo) |info| {
                    const sourceHash = try computeStorageHash(allocator, io, assetStorage, sourceFile);

                    // Copy file from assets/ to asset/
                    const readStream = try assetStorage.readStream(allocator, io, sourceFile);
                    defer readStream.destroy(io);
                    try assetStorage.writeStream(allocator, io, destFile, info.contentType, readStream.reader(), null);

                    // Verify the copied file has the same hash
                    const destHash = try computeStorageHash(allocator, io, assetStorage, destFile);

                    if (!std.mem.eql(u8, &sourceHash, &destHash)) {
                        return throwError("Hash mismatch during file move from {s} to {s}: source={s}, dest={s}", .{ sourceFile, destFile, &std.fmt.bytesToHex(sourceHash, .lower), &std.fmt.bytesToHex(destHash, .lower) });
                    }

                    const destFileInfo = try assetStorage.info(allocator, io, destFile) orelse {
                        return throwError("Failed to get info for file {s}", .{destFile});
                    };

                    // Only delete the source file after successful verification
                    try assetStorage.deleteFile(allocator, io, sourceFile);

                    merkleTree = try addItem(allocator, &merkleTree, .{
                        .name = destFile,
                        .hash = try allocator.dupe(u8, &destHash),
                        .length = destFileInfo.length,
                        .lastModified = destFileInfo.lastModified,
                    });
                    filesMoved += 1;
                }
            }

            next = assetsFiles.next;
            if (next == null) {
                break;
            }
        }

        log.info(try std.fmt.allocPrint(allocator, "\u{2713} Moved {d} files from 'assets' to 'asset' directory", .{filesMoved}));
    }

    // Create README.md if it doesn't exist
    var readmeInfoOperation: node_api.retry_operations.InfoOperation("() => assetStorage.info('README.md')") = .{
        .allocator = allocator,
        .storage = assetStorage,
        .fileName = "README.md",
    };
    const existingReadme = try retry(io, &readmeInfoOperation, 3, 1_000, 2, 30_000, null);
    if (existingReadme == null) {
        merkleTree = try createReadme(allocator, io, rawStorage, merkleTree);
    }

    // Check if database is encrypted and ensure public key is in .db directory
    if (keyPems.len > 0) {
        // Database is encrypted - check if public key marker exists in .db directory
        if (!try assetStorage.fileExists(allocator, io, ".db/encryption.pub")) {
            // Write public key PEM from key pair
            if (rawStorage.write(allocator, io, ".db/encryption.pub", "text/plain", keyPems[0].publicKeyPem)) {
                log.info(try pc.green(allocator, "\u{2713} Wrote public key to database directory"));
            }
            else |err| {
                log.@"error"(try pc.red(allocator, try std.fmt.allocPrint(allocator, "Warning: Could not write public key to database directory: {s}", .{errorMessage(err)})));
            }
        }

        //
        // When upgrading from a version before 6 to 6+, encrypt existing .db/ files that were
        // previously stored unencrypted. From v6 onward these files are already written encrypted.
        //
        if (currentVersion < FIRST_VERSION_WITH_ENCRYPTED_DOT_DB) {
            var walker = try walkDirectory(allocator, io, assetStorage, ".db", &.{});
            while (try walker.next()) |file| {
                const filePath = file.fileName;
                const data = try assetStorage.read(allocator, io, filePath);
                if (data) |bytes| {
                    const info = try assetStorage.info(allocator, io, filePath);
                    try assetStorage.write(allocator, io, filePath, if (info) |fileInfo| fileInfo.contentType else null, bytes);
                }
            }
        }
    }

    // Rebuild the merkle tree in sorted order with no metadata/
    merkleTree = try rebuildTree(allocator, &merkleTree, &.{ "metadata/", "assets/" });

    // Count files in the asset directory to get the actual number of imported files
    var filesImported: usize = 0;
    var next: ?[]const u8 = null;

    while (true) {
        const assetFiles = try assetStorage.listFiles(allocator, io, "asset", 1000, next);
        filesImported += assetFiles.names.len;
        next = assetFiles.next;
        if (next == null) {
            break;
        }
    }

    if (merkleTree.databaseMetadata == null) {
        merkleTree.databaseMetadata = .empty;
    }
    try merkleTree.databaseMetadata.?.put(allocator, "filesImported", .{ .number = @floatFromInt(filesImported) });

    // Save the rebuilt tree to .db/files.dat (v6 path; encrypted when DB is encrypted).
    var saveOperation: SaveTreeOperation = .{
        .allocator = allocator,
        .merkleTree = &merkleTree,
        .storage = assetStorage,
    };
    try retry(io, &saveOperation, 3, 1_000, 2, 30_000, null);
    if (try assetStorage.fileExists(allocator, io, ".db/tree.dat")) {
        try assetStorage.deleteFile(allocator, io, ".db/tree.dat");
    }
    merkleTreeInOut.* = merkleTree;

    // Migrate BSON from metadata/ to .db/bson/ when metadata/ exists (copy only; rest of upgrade still uses metadata/)
    if (try assetStorage.dirExists(allocator, io, "metadata")) {
        log.info(try pc.blue(allocator, "Migrating BSON from metadata/ to .db/bson/."));
        try migrateBsonV5ToV6(allocator, io, assetStorage, "metadata", ".db/bson");
        log.info(try pc.green(allocator, "\u{2713} BSON migrated to .db/bson/"));
    }

    log.info(try pc.blue(allocator, "Rebuilding BSON database merkle tree."));

    var bsonDatabaseTree = try buildDatabaseMerkleTree(
        allocator,
        io,
        assetStorage,
        ".db/bson",
        uuidGenerator,
        null,
        null,
        true,
    );
    if (bsonDatabaseTree.sort == null) {
        try deleteDatabaseMerkleTree(allocator, io, assetStorage, ".db/bson");
    }
    else {
        try saveDatabaseMerkleTree(allocator, io, assetStorage, ".db/bson", &bsonDatabaseTree);
    }
    log.info(try pc.green(allocator, "\u{2713} BSON database merkle tree built successfully"));

    // Delete and rebuild sort indexes under .db/bson so they use v6 format (type code + checksum).
    log.info(try pc.blue(allocator, "Rebuilding sort indexes."));
    const bsonDb = try BsonDatabase.init(allocator, assetStorage, ".db/bson", uuidGenerator, timestampProvider);
    const v6MetadataCollection = try bsonDb.collection("metadata");
    const existingIndexes = try v6MetadataCollection.sortIndexes(io);
    for (existingIndexes) |index| {
        _ = try (try v6MetadataCollection.sortIndex(index.fieldName, index.direction)).drop(io);
    }
    try ensureSortIndex(io, v6MetadataCollection);
    log.info(try pc.green(allocator, "\u{2713} Sort indexes rebuilt successfully"));

    // Remove the old metadata/ directory now that everything is in .db/bson/
    if (try assetStorage.dirExists(allocator, io, "metadata")) {
        try assetStorage.deleteDir(allocator, io, "metadata");
        log.info(try pc.green(allocator, "\u{2713} Removed metadata/ directory"));
    }

    // Ensure .db/config.json exists (create empty if not present)
    const existingConfig = try loadDatabaseConfig(allocator, io, rawStorage);
    if (existingConfig == null) {
        try saveDatabaseConfig(allocator, io, rawStorage, .{});
        log.info(try pc.green(allocator, "\u{2713} Created .db/config.json"));
    }

    log.info(try pc.green(allocator, try std.fmt.allocPrint(allocator, "\u{2713} Database upgraded successfully to version {d}", .{CURRENT_DATABASE_VERSION})));
    log.info("");
    log.info(try pc.bold(allocator, "Next steps:"));
    log.info("    # View database summary and tree hash");
    log.info(try std.fmt.allocPrint(allocator, "    psi summary --db {s}", .{databaseDir}));
    log.info("");
    log.info("    # Verify the integrity of the upgraded database");
    log.info(try std.fmt.allocPrint(allocator, "    psi verify --db {s}", .{databaseDir}));
}

//
// Copies a file within the same storage.
//
fn copyStorageFile(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, src: []const u8, dest: []const u8) !void {
    const data = try storage.read(allocator, io, src);
    if (data) |bytes| {
        try storage.write(allocator, io, dest, null, bytes);
    }
}

// Not ported: copyStorageDirRecursive (not called by upgradeCommand).

//
// Copies BSON from srcPrefix (v5 layout: <name>/ collection dirs, sort_indexes/) to destPrefix
// with v6 layout (collections/, shards/, indexes/). Does not copy sort_indexes (rebuilt later).
// Does not delete srcPrefix so callers that still use the source root keep working.
//
fn migrateBsonV5ToV6(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, srcPrefix: []const u8, destPrefix: []const u8) !void {
    if (try storage.fileExists(allocator, io, try pathJoin(allocator, &.{ srcPrefix, "db.dat" }))) {
        try copyStorageFile(
            allocator,
            io,
            storage,
            try pathJoin(allocator, &.{ srcPrefix, "db.dat" }),
            try pathJoin(allocator, &.{ destPrefix, "db.dat" }),
        );
    }

    var next: ?[]const u8 = null;
    var v5CollectionDirs: std.ArrayList([]const u8) = .empty;
    while (true) {
        const result = try storage.listDirs(allocator, io, srcPrefix, 1000, next);
        for (result.names) |name| {
            if (!std.mem.eql(u8, name, "sort_indexes") and !std.mem.eql(u8, name, "collections") and !std.mem.eql(u8, name, "indexes")) {
                try v5CollectionDirs.append(allocator, name);
            }
        }
        next = result.next;
        if (next == null) {
            break;
        }
    }

    for (v5CollectionDirs.items) |collectionName| {
        const srcDir = try pathJoin(allocator, &.{ srcPrefix, collectionName });
        var fileNext: ?[]const u8 = null;
        while (true) {
            const fileResult = try storage.listFiles(allocator, io, srcDir, 1000, fileNext);
            for (fileResult.names) |fileName| {
                const srcPath = try pathJoin(allocator, &.{ srcDir, fileName });
                if (std.mem.eql(u8, fileName, "collection.dat")) {
                    try copyStorageFile(
                        allocator,
                        io,
                        storage,
                        srcPath,
                        try pathJoin(allocator, &.{ destPrefix, "collections", collectionName, "collection.dat" }),
                    );
                }
                else {
                    try copyStorageFile(
                        allocator,
                        io,
                        storage,
                        srcPath,
                        try pathJoin(allocator, &.{ destPrefix, "collections", collectionName, "shards", fileName }),
                    );
                }
            }
            fileNext = fileResult.next;
            if (fileNext == null) {
                break;
            }
        }
    }
}
