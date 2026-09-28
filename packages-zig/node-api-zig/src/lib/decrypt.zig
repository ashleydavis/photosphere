//
// In-place decrypt: copy every file from read storage (encrypted) to write storage (plain),
// update the merkle tree for tree-tracked files, then save the tree.
//

const std = @import("std");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
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
const merkle_tree = merkle_tree_zig.merkle_tree;
const IMerkleTree = merkle_tree.IMerkleTree;
const getItemInfo = merkle_tree.getItemInfo;
const updateItem = merkle_tree.updateItem;
const LARGE_FILE_TIMEOUT = api.constants.LARGE_FILE_TIMEOUT;

//
// Callback invoked periodically during decrypt to report progress.
//
pub const IDecryptProgress = struct {
    // The state of the callback, passed to function.
    context: ?*anyopaque,

    // The callback function.
    function: *const fn (context: ?*anyopaque, message: []const u8) void,

    //
    // Invokes the callback.
    //
    pub fn call(self: IDecryptProgress, message: []const u8) void {
        self.function(self.context, message);
    }
};

//
// Result returned by decrypt with counts of files processed.
//
pub const IDecryptResult = struct {
    // The number of files that were decrypted.
    decrypted: u64,

    // The number of files skipped because they were already plain.
    skipped: u64,
};

//
// Decrypts a single file from readStorage and writes it plain to writeStorage.
// Skips files that are not encrypted. Updates the merkle tree entry for non-.db/ files.
// Returns true if the file was decrypted, false if it was skipped (already plain).
// (Zig: treeMutex, when given, is held while the merkle tree is read and updated, because the files of a batch
// are decrypted on separate threads where TypeScript interleaves them on one.)
//
pub fn decryptFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    fileName: []const u8,
    readStorage: IStorage,
    writeStorage: IStorage,
    rawReadStorage: IStorage,
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

    // TypeScript: `readStorage !== writeStorage`, the identity of the two storage objects.
    const sameStorage = readStorage.ptr == writeStorage.ptr and readStorage.vtable == writeStorage.vtable;
    const shouldDecrypt = header != null or !sameStorage;
    if (shouldDecrypt) {
        log.verbose(try std.fmt.allocPrint(allocator, "Decrypting {s}", .{fileName}));

        var copyOperation: retry_operations.CopyStreamWithLengthOperation("async () => {\n      const stream = await readStorage.readStream(fileName);\n      await writeStorage.writeStream(fileName, srcFileInfo.contentType, stream, srcFileInfo.length);\n    }") = .{
            .allocator = allocator,
            .sourceStorage = readStorage,
            .destStorage = writeStorage,
            .fileName = fileName,
            .contentType = srcFileInfo.contentType,
            .contentLength = srcFileInfo.length,
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
        log.info(try std.fmt.allocPrint(allocator, "Already decrypted {s}", .{fileName}));
        return false;
    }
}

//
// Yields file names from readStorage that should be decrypted, skipping metadata and config files
// that are either handled separately or not decrypted at all.
// (Zig: an iterator; call `next` for each file name, like iterating the TypeScript decryptableFiles generator.)
//
pub const DecryptableFilesIterator = struct {
    // The walk of the whole storage.
    walker: DirectoryWalker,

    //
    // Returns the next file to decrypt, or null when the walk is done.
    //
    pub fn next(self: *DecryptableFilesIterator) !?[]const u8 {
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
// Yields file names from readStorage that should be decrypted, skipping metadata and config files
// that are either handled separately or not decrypted at all.
//
pub fn decryptableFiles(allocator: std.mem.Allocator, io: std.Io, readStorage: IStorage) !DecryptableFilesIterator {
    return .{
        .walker = try walkDirectory(allocator, io, readStorage, "", &.{}),
    };
}

//
// Decrypts one file of a batch (TypeScript: the `async fileName => { ... }` arrow function that `batch.map` runs).
// Runs concurrently with the rest of its batch, with its own allocator because the caller's is not shared between
// threads.
//
const DecryptFileTask = struct {
    // The storage the file is read from.
    readStorage: IStorage,

    // The storage the plain file is written to.
    writeStorage: IStorage,

    // The raw storage used to peek the encryption header.
    rawReadStorage: IStorage,

    // The files tree whose entry for the file is updated.
    merkleTree: *IMerkleTree,

    // Held while the files tree is read and updated.
    treeMutex: *std.Io.Mutex,

    // The file to decrypt.
    fileName: []const u8,

    // True when the file was decrypted, false when it was skipped.
    wasDecrypted: bool = false,

    // The error the task failed with, or null when it succeeded.
    failure: ?anyerror = null,

    // The message of the error the task failed with, captured on the thread that ran it.
    errorRecord: errors.ErrorRecord = .{},

    //
    // Decrypts the file, recording the error when it fails.
    //
    fn run(self: *DecryptFileTask, io: std.Io) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        if (decryptFile(arena.allocator(), io, self.fileName, self.readStorage, self.writeStorage, self.rawReadStorage, self.merkleTree, self.treeMutex)) |wasDecrypted| {
            self.wasDecrypted = wasDecrypted;
        }
        else |err| {
            self.failure = err;
            errors.captureError(&self.errorRecord);
        }
    }
};

//
// Decrypts the database in place: reads each file from readStorage (encrypted),
// writes it plain to writeStorage (same path).
// rawReadStorage is the raw storage (no decryption layer) used to peek encryption headers.
//
pub fn decrypt(
    allocator: std.mem.Allocator,
    io: std.Io,
    readStorage: IStorage,
    writeStorage: IStorage,
    progressCallback: IDecryptProgress,
    rawReadStorage: IStorage,
) !IDecryptResult {
    var loadOperation: retry_operations.LoadMerkleTreeOperation("() => loadMerkleTree(readStorage)") = .{
        .allocator = allocator,
        .storage = readStorage,
    };
    var merkleTree = try retry(io, &loadOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwError("Failed to load merkle tree.", .{});
    };

    var decrypted: u64 = 0;
    var skipped: u64 = 0;
    const BATCH_SIZE = 10;

    var treeMutex: std.Io.Mutex = .init;
    var files = try decryptableFiles(allocator, io, readStorage);
    var batches = batchGenerator([]const u8, allocator, &files, BATCH_SIZE);
    while (try batches.next()) |batch| {
        const tasks = try allocator.alloc(DecryptFileTask, batch.len);
        for (batch, tasks) |fileName, *task| {
            task.* = .{
                .readStorage = readStorage,
                .writeStorage = writeStorage,
                .rawReadStorage = rawReadStorage,
                .merkleTree = &merkleTree,
                .treeMutex = &treeMutex,
                .fileName = fileName,
            };
        }

        var group: std.Io.Group = .init;
        for (tasks) |*task| {
            group.async(io, DecryptFileTask.run, .{ task, io });
        }
        try group.await(io);

        for (tasks) |*task| {
            if (task.failure) |failure| {
                errors.restoreError(&task.errorRecord);
                return failure;
            }
        }
        for (tasks) |*task| {
            if (task.wasDecrypted) {
                decrypted += 1;
            }
            else {
                skipped += 1;
            }
        }
        progressCallback.call(try std.fmt.allocPrint(allocator, "Decrypted {d} files, skipped {d} already plain", .{ decrypted, skipped }));
    }

    var saveOperation: retry_operations.SaveMerkleTreeOperation("() => saveMerkleTree(merkleTree, writeStorage)") = .{
        .allocator = allocator,
        .merkleTree = &merkleTree,
        .storage = writeStorage,
    };
    try retry(io, &saveOperation, 3, 1_000, 2, 30_000, null);

    progressCallback.call(try std.fmt.allocPrint(allocator, "Decrypted {d} files, skipped {d} already plain, saved merkle tree", .{ decrypted, skipped }));
    return .{
        .decrypted = decrypted,
        .skipped = skipped,
    };
}
