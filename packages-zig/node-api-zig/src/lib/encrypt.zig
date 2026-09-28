//
// In-place encrypt: copy every file from read storage to write storage (same logical path),
// then save the merkle tree.
// Uses walkDirectory so that all files (including .db/bson/*) are transformed.
//

const std = @import("std");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const encryption = @import("encryption-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const api = @import("api-zig");
const tree = @import("tree.zig");
const retry_operations = @import("retry-operations.zig");
const errors = utils.errors;
const log = &utils.log.log;
const retry = utils.retry.retry;
const batchGenerator = utils.batch_generator.batchGenerator;
const IStorage = storage_zig.storage.IStorage;
const walk_directory = storage_zig.walk_directory;
const walkDirectory = walk_directory.walkDirectory;
const DirectoryWalker = walk_directory.DirectoryWalker;
const readEncryptionHeader = storage_zig.read_encryption_header.readEncryptionHeader;
const PublicKey = encryption.node_crypto.PublicKey;
const hashPublicKey = encryption.key_utils.hashPublicKey;
const merkle_tree = merkle_tree_zig.merkle_tree;
const IMerkleTree = merkle_tree.IMerkleTree;
const getItemInfo = merkle_tree.getItemInfo;
const updateItem = merkle_tree.updateItem;
const LARGE_FILE_TIMEOUT = api.constants.LARGE_FILE_TIMEOUT;

//
// Callback invoked periodically during encrypt to report progress.
//
pub const IEncryptProgress = struct {
    // The state of the callback, passed to function.
    context: ?*anyopaque,

    // The callback function.
    function: *const fn (context: ?*anyopaque, message: []const u8) void,

    //
    // Invokes the callback.
    //
    pub fn call(self: IEncryptProgress, message: []const u8) void {
        self.function(self.context, message);
    }
};

//
// Result returned by encrypt with counts of files processed.
//
pub const IEncryptResult = struct {
    // The number of files that were encrypted.
    encrypted: u64,

    // The number of files skipped because they were already encrypted with the key.
    skipped: u64,
};

//
// Encrypts a single file from readStorage and writes it to writeStorage.
// Skips files already encrypted with the given publicKeyHash.
// Updates the merkle tree entry for non-.db/ files with the new storage metadata.
//
//
// Returns true if the file was encrypted, false if it was skipped (already encrypted with the given key).
// (Zig: treeMutex, when given, is held while the merkle tree is read and updated, because the files of a batch
// are encrypted on separate threads where TypeScript interleaves them on one.)
//
pub fn encryptFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    fileName: []const u8,
    readStorage: IStorage,
    writeStorage: IStorage,
    rawReadStorage: IStorage,
    publicKeyHash: []const u8,
    merkleTree: *IMerkleTree,
    treeMutex: ?*std.Io.Mutex,
) !bool {
    var srcInfoOperation: retry_operations.InfoOperation("() => readStorage.info(fileName)") = .{
        .allocator = allocator,
        .storage = readStorage,
        .fileName = fileName,
    };
    const srcFileInfo = try retry(io, &srcInfoOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwError("Source file \"{s}\" does not exist.", .{fileName});
    };

    const header = try readEncryptionHeader(allocator, io, rawReadStorage, fileName);
    const shouldEncrypt = header == null or !std.mem.eql(u8, header.?, publicKeyHash);
    if (shouldEncrypt) {
        log.verbose(try std.fmt.allocPrint(allocator, "Encrypting {s}", .{fileName}));

        var copyOperation: retry_operations.CopyStreamOperation("async () => {\n      await writeStorage.writeStream(fileName, srcFileInfo.contentType, await readStorage.readStream(fileName));\n    }") = .{
            .allocator = allocator,
            .sourceStorage = readStorage,
            .destStorage = writeStorage,
            .fileName = fileName,
            .contentType = srcFileInfo.contentType,
        };
        try retry(io, &copyOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, null);

        if (!std.mem.startsWith(u8, fileName, ".db/")) {
            if (treeMutex) |mutex| {
                mutex.lockUncancelable(io);
            }
            defer if (treeMutex) |mutex| {
                mutex.unlock(io);
            };
            const existing = try getItemInfo(merkleTree, fileName);
            if (existing) |existingInfo| {
                var updatedInfoOperation: retry_operations.InfoOperation("() => writeStorage.info(fileName)") = .{
                    .allocator = allocator,
                    .storage = writeStorage,
                    .fileName = fileName,
                };
                const updatedInfo = try retry(io, &updatedInfoOperation, 3, 1_000, 2, 30_000, null) orelse {
                    return errors.throwError("Written file \"{s}\" has no info.", .{fileName});
                };

                _ = try updateItem(merkleTree, .{
                    .name = fileName,
                    .hash = existingInfo.hash,
                    .length = updatedInfo.length,
                    .lastModified = updatedInfo.lastModified,
                });
            }
        }

        return true;
    }
    else {
        log.verbose(try std.fmt.allocPrint(allocator, "Already encrypted {s}", .{fileName}));
        return false;
    }
}

//
// Yields file names from readStorage that should be encrypted, skipping metadata and config files
// that are either handled separately or not encrypted at all.
// (Zig: an iterator; call `next` for each file name, like iterating the TypeScript encryptableFiles generator.)
//
pub const EncryptableFilesIterator = struct {
    // The walk of the whole storage.
    walker: DirectoryWalker,

    //
    // Returns the next file to encrypt, or null when the walk is done.
    //
    pub fn next(self: *EncryptableFilesIterator) !?[]const u8 {
        while (try self.walker.next()) |file| {
            const fileName = file.fileName;
            if (!std.mem.eql(u8, fileName, ".db/files.dat") and !std.mem.eql(u8, fileName, ".db/encryption.pub") and !std.mem.eql(u8, fileName, ".db/config.json") and !std.mem.eql(u8, fileName, "README.md")) {
                return fileName;
            }
        }
        return null;
    }
};

//
// Yields file names from readStorage that should be encrypted, skipping metadata and config files
// that are either handled separately or not encrypted at all.
//
pub fn encryptableFiles(allocator: std.mem.Allocator, io: std.Io, readStorage: IStorage) !EncryptableFilesIterator {
    return .{
        .walker = try walkDirectory(allocator, io, readStorage, "", &.{}),
    };
}

//
// Encrypts one file of a batch (TypeScript: the `async fileName => { ... }` arrow function that `batch.map` runs).
// Runs concurrently with the rest of its batch, with its own allocator because the caller's is not shared between
// threads.
//
const EncryptFileTask = struct {
    // The storage the file is read from.
    readStorage: IStorage,

    // The storage the encrypted file is written to.
    writeStorage: IStorage,

    // The raw storage used to peek the encryption header.
    rawReadStorage: IStorage,

    // The hash of the public key the file is encrypted with.
    publicKeyHash: []const u8,

    // The files tree whose entry for the file is updated.
    merkleTree: *IMerkleTree,

    // Held while the files tree is read and updated.
    treeMutex: *std.Io.Mutex,

    // The file to encrypt.
    fileName: []const u8,

    // True when the file was encrypted, false when it was skipped.
    wasEncrypted: bool = false,

    // The error the task failed with, or null when it succeeded.
    failure: ?anyerror = null,

    // The message of the error the task failed with, captured on the thread that ran it.
    errorRecord: errors.ErrorRecord = .{},

    //
    // Encrypts the file, recording the error when it fails.
    //
    fn run(self: *EncryptFileTask, io: std.Io) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        if (encryptFile(arena.allocator(), io, self.fileName, self.readStorage, self.writeStorage, self.rawReadStorage, self.publicKeyHash, self.merkleTree, self.treeMutex)) |wasEncrypted| {
            self.wasEncrypted = wasEncrypted;
        }
        else |err| {
            self.failure = err;
            errors.captureError(&self.errorRecord);
        }
    }
};

//
// Encrypts the database in place: reads each file from readStorage, writes it encrypted
// to writeStorage (same path). Can be run on an already encrypted database to re-encrypt
// with a new key. Use readStorage = plain, writeStorage = encrypted for plain→encrypted;
// or both encrypted for re-encrypt with a new key. The caller must only store the new
// public key in .db/encryption.pub after the entire database has been re-encrypted.
// Files already encrypted with this key are skipped.
// rawReadStorage is the raw storage (no decryption layer) used to peek encryption headers; pass the same path as readStorage.
//
pub fn encrypt(
    allocator: std.mem.Allocator,
    io: std.Io,
    readStorage: IStorage,
    writeStorage: IStorage,
    progressCallback: IEncryptProgress,
    encryptionPublicKey: *const PublicKey,
    rawReadStorage: IStorage,
) !IEncryptResult {
    var loadOperation: retry_operations.LoadMerkleTreeOperation("() => loadMerkleTree(readStorage)") = .{
        .allocator = allocator,
        .storage = readStorage,
    };
    var merkleTree = try retry(io, &loadOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwError("Failed to load merkle tree from database.", .{});
    };

    const publicKeyHash = try hashPublicKey(allocator, encryptionPublicKey);

    var encrypted: u64 = 0;
    var skipped: u64 = 0;
    const BATCH_SIZE = 10;

    var treeMutex: std.Io.Mutex = .init;
    var files = try encryptableFiles(allocator, io, readStorage);
    var batches = batchGenerator([]const u8, allocator, &files, BATCH_SIZE);
    while (try batches.next()) |batch| {
        const tasks = try allocator.alloc(EncryptFileTask, batch.len);
        for (batch, tasks) |fileName, *task| {
            task.* = .{
                .readStorage = readStorage,
                .writeStorage = writeStorage,
                .rawReadStorage = rawReadStorage,
                .publicKeyHash = &publicKeyHash,
                .merkleTree = &merkleTree,
                .treeMutex = &treeMutex,
                .fileName = fileName,
            };
        }

        var group: std.Io.Group = .init;
        for (tasks) |*task| {
            group.async(io, EncryptFileTask.run, .{ task, io });
        }
        try group.await(io);

        for (tasks) |*task| {
            if (task.failure) |failure| {
                errors.restoreError(&task.errorRecord);
                return failure;
            }
        }
        for (tasks) |*task| {
            if (task.wasEncrypted) {
                encrypted += 1;
            }
            else {
                skipped += 1;
            }
        }
        progressCallback.call(try std.fmt.allocPrint(allocator, "Encrypted {d} files, skipped {d} already encrypted", .{ encrypted, skipped }));
    }

    var saveOperation: retry_operations.SaveMerkleTreeOperation("() => saveMerkleTree(merkleTree, writeStorage)") = .{
        .allocator = allocator,
        .merkleTree = &merkleTree,
        .storage = writeStorage,
    };
    try retry(io, &saveOperation, 3, 1_000, 2, 30_000, null);
    progressCallback.call(try std.fmt.allocPrint(allocator, "Encrypted {d} files, skipped {d} already encrypted, saved merkle tree", .{ encrypted, skipped }));
    return .{
        .encrypted = encrypted,
        .skipped = skipped,
    };
}
