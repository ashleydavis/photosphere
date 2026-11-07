//
// In-place decrypt: copy every file from read storage (encrypted) to write storage (plain),
// update the merkle tree for tree-tracked files, then save the tree.
//

const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const api = @import("api-zig");
const tree = @import("tree.zig");
const retry_operations = @import("retry-operations.zig");
const errors = utils.errors;
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
    function: *const fn (context: ?*anyopaque, log: ILog, message: []const u8) void,

    //
    // Invokes the callback.
    //
    pub fn call(self: IDecryptProgress, log: ILog, message: []const u8) void {
        self.function(self.context, log, message);
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
//
pub fn decryptFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    log: ILog,
    fileName: []const u8,
    readStorage: IStorage,
    writeStorage: IStorage,
    rawReadStorage: IStorage,
    merkleTree: *IMerkleTree,
) !bool {
    var srcInfoOperation: retry_operations.InfoOperation("() => readStorage.info(fileName)") = .{
        .allocator = allocator,
        .storage = readStorage,
        .fileName = fileName,
    };
    const srcFileInfo = try retry(io, log, &srcInfoOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwError("Source file \"{s}\" does not exist.", .{fileName});
    };

    const header = try readEncryptionHeader(allocator, io, log, rawReadStorage, fileName);

    // Whether the two storages are the same object.
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
        try retry(io, log, &copyOperation, 3, 1_000, 2, LARGE_FILE_TIMEOUT, null);

        if (!std.mem.startsWith(u8, fileName, ".db/")) {
            const existing = try getItemInfo(merkleTree, fileName);
            if (existing) |existingInfo| {
                var updatedInfoOperation: retry_operations.InfoOperation("() => writeStorage.info(fileName)") = .{
                    .allocator = allocator,
                    .storage = writeStorage,
                    .fileName = fileName,
                };
                const updatedInfo = try retry(io, log, &updatedInfoOperation, 3, 1_000, 2, 30_000, null) orelse {
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
// An iterator: call `next` for each file name.
//
pub const DecryptableFilesIterator = struct {
    // The walk of the whole storage.
    walker: DirectoryWalker,

    //
    // Returns the next file to decrypt, or null when the walk is done.
    //
    pub fn next(self: *DecryptableFilesIterator, log: ILog) !?[]const u8 {
        while (try self.walker.next(log)) |file| {
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
// Decrypts the database in place: reads each file from readStorage (encrypted),
// writes it plain to writeStorage (same path).
// rawReadStorage is the raw storage (no decryption layer) used to peek encryption headers.
//
pub fn decrypt(
    allocator: std.mem.Allocator,
    io: std.Io,
    log: ILog,
    readStorage: IStorage,
    writeStorage: IStorage,
    progressCallback: IDecryptProgress,
    rawReadStorage: IStorage,
) !IDecryptResult {
    var loadOperation: retry_operations.LoadMerkleTreeOperation("() => loadMerkleTree(readStorage)") = .{
        .allocator = allocator,
        .storage = readStorage,
    };
    var merkleTree = try retry(io, log, &loadOperation, 3, 1_000, 2, 30_000, null) orelse {
        return errors.throwError("Failed to load merkle tree.", .{});
    };

    var decrypted: u64 = 0;
    var skipped: u64 = 0;
    const BATCH_SIZE = 10;

    var files = try decryptableFiles(allocator, io, readStorage);
    var batches = batchGenerator([]const u8, allocator, &files, BATCH_SIZE);
    while (try batches.next(log)) |batch| {
        // The files of a batch are decrypted one after another, on the task's own thread.
        for (batch) |fileName| {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            if (try decryptFile(arena.allocator(), io, log, fileName, readStorage, writeStorage, rawReadStorage, &merkleTree)) {
                decrypted += 1;
            }
            else {
                skipped += 1;
            }
        }
        progressCallback.call(log, try std.fmt.allocPrint(allocator, "Decrypted {d} files, skipped {d} already plain", .{ decrypted, skipped }));
    }

    var saveOperation: retry_operations.SaveMerkleTreeOperation("() => saveMerkleTree(merkleTree, writeStorage)") = .{
        .allocator = allocator,
        .merkleTree = &merkleTree,
        .storage = writeStorage,
    };
    try retry(io, log, &saveOperation, 3, 1_000, 2, 30_000, null);

    progressCallback.call(log, try std.fmt.allocPrint(allocator, "Decrypted {d} files, skipped {d} already plain, saved merkle tree", .{ decrypted, skipped }));
    return .{
        .decrypted = decrypted,
        .skipped = skipped,
    };
}
