//
// Tests for decryptableFiles and decrypt (port of src/test/lib/decrypt.test.ts).
//

const std = @import("std");
const utils = @import("utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const node_api = @import("node-api-zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const sync_helpers = @import("sync-test-helpers.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const errors = utils.errors;
const HashedItem = merkle_tree.HashedItem;
const IMerkleTree = merkle_tree.IMerkleTree;
const MerkleNode = merkle_tree.MerkleNode;
const decrypt = node_api.decrypt.decrypt;
const decryptableFiles = node_api.decrypt.decryptableFiles;
const IDecryptProgress = node_api.decrypt.IDecryptProgress;
const loadMerkleTree = node_api.tree.loadMerkleTree;
const computeHash = node_api.hash.computeHash;
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// Path to the merkle tree file within storage.
//
const FILES_TREE_PATH = ".db/files.dat";

//
// Stable UUID used for tree construction in tests.
//
const VALID_UUID = "12345678-1234-5678-9abc-123456789abc";

//
// Returns a deterministic SHA-256 hash derived from a string seed.
//
fn makeHash(allocator: std.mem.Allocator, seed: []const u8) ![]const u8 {
    const digest = try allocator.create([32]u8);
    Sha256.hash(seed, digest, .{});
    return digest;
}

//
// Builds a minimal merkle tree containing the given leaf file names.
//
fn buildMinimalFilesTree(allocator: std.mem.Allocator, leafNames: []const []const u8) !IMerkleTree {
    var tree = merkle_tree.createTree(VALID_UUID);
    for (leafNames) |name| {
        tree = try merkle_tree.addItem(allocator, &tree, .{
            .name = name,
            .hash = try makeHash(allocator, name),
            .length = 0,
            .lastModified = std.Io.Clock.real.now(std.testing.io).toMilliseconds(),
        });
    }
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    tree.dirty = false;
    return tree;
}

//
// Collects every file name the decryptableFiles iterator yields.
//
fn collectFiles(allocator: std.mem.Allocator, storage: *MemoryStorage) ![]const []const u8 {
    var results: std.ArrayList([]const u8) = .empty;
    var files = try decryptableFiles(allocator, std.testing.io, storage.asStorage());
    while (try files.next()) |fileName| {
        try results.append(allocator, fileName);
    }
    return results.items;
}

//
// Returns true when the list holds the name.
//
fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) {
            return true;
        }
    }
    return false;
}

//
// A progress callback that ignores the messages (TypeScript: `() => {}`).
//
fn ignoreProgress(context: ?*anyopaque, message: []const u8) void {
    _ = context;
    _ = message;
}

//
// A progress callback that ignores the messages.
//
const noProgress: IDecryptProgress = .{
    .context = null,
    .function = ignoreProgress,
};

//
// The messages a progress callback received (TypeScript: `msg => messages.push(msg)`).
//
const ProgressMessages = struct {
    // Allocates the copies of the messages.
    allocator: std.mem.Allocator,

    // The messages received.
    messages: std.ArrayList([]const u8) = .empty,

    //
    // Records a message.
    //
    fn push(context: ?*anyopaque, message: []const u8) void {
        const self: *ProgressMessages = @ptrCast(@alignCast(context.?));
        const copy = self.allocator.dupe(u8, message) catch {
            @panic("out of memory");
        };
        self.messages.append(self.allocator, copy) catch {
            @panic("out of memory");
        };
    }
};

test "decryptableFiles yields regular files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var storage = MemoryStorage.init(allocator);
    try storage.asStorage().write(allocator, io, "photo/img.jpg", "image/jpeg", "x");
    try storage.asStorage().write(allocator, io, ".db/bson/meta", "application/octet-stream", "x");
    const files = try collectFiles(allocator, &storage);
    try std.testing.expect(contains(files, "photo/img.jpg"));
    try std.testing.expect(contains(files, ".db/bson/meta"));
}

test "decryptableFiles excludes .db/files.dat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var storage = MemoryStorage.init(allocator);
    try storage.asStorage().write(allocator, io, ".db/files.dat", "application/octet-stream", "x");
    try storage.asStorage().write(allocator, io, "photo/img.jpg", "image/jpeg", "x");
    const files = try collectFiles(allocator, &storage);
    try std.testing.expect(!contains(files, ".db/files.dat"));
    try std.testing.expect(contains(files, "photo/img.jpg"));
}

test "decryptableFiles excludes .db/encryption.pub" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var storage = MemoryStorage.init(allocator);
    try storage.asStorage().write(allocator, io, ".db/encryption.pub", "application/octet-stream", "x");
    try storage.asStorage().write(allocator, io, "photo/img.jpg", "image/jpeg", "x");
    const files = try collectFiles(allocator, &storage);
    try std.testing.expect(!contains(files, ".db/encryption.pub"));
}

test "decryptableFiles excludes README.md" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var storage = MemoryStorage.init(allocator);
    try storage.asStorage().write(allocator, io, "README.md", "text/markdown", "x");
    try storage.asStorage().write(allocator, io, "photo/img.jpg", "image/jpeg", "x");
    const files = try collectFiles(allocator, &storage);
    try std.testing.expect(!contains(files, "README.md"));
}

test "decryptableFiles yields nothing for empty storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const files = try collectFiles(allocator, &storage);
    try std.testing.expectEqual(@as(usize, 0), files.len);
}

test "decryptableFiles excludes .db/config.json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var storage = MemoryStorage.init(allocator);
    try storage.asStorage().write(allocator, io, ".db/config.json", "application/json", "{}");
    try storage.asStorage().write(allocator, io, "photo/img.jpg", "image/jpeg", "x");
    const files = try collectFiles(allocator, &storage);
    try std.testing.expect(!contains(files, ".db/config.json"));
    try std.testing.expect(contains(files, "photo/img.jpg"));
}

test "decrypt copies all files from read storage to write storage and updates merkle tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    var readStore = MemoryStorage.init(allocator);
    var writeStore = MemoryStorage.init(allocator);
    const readStorage = readStore.asStorage();
    const writeStorage = writeStore.asStorage();

    const leafFile = "other/data.bin";
    const tree = try buildMinimalFilesTree(allocator, &.{leafFile});
    try merkle_tree.saveTree(allocator, io, FILES_TREE_PATH, &tree, readStorage, "FTRE");
    try readStorage.write(allocator, io, leafFile, "application/octet-stream", "encrypted or plain payload");

    _ = try decrypt(allocator, io, readStorage, writeStorage, noProgress, readStorage);

    try std.testing.expect(try writeStorage.fileExists(allocator, io, FILES_TREE_PATH));
    try std.testing.expect(try writeStorage.fileExists(allocator, io, leafFile));
    const writtenContent = try writeStorage.read(allocator, io, leafFile);
    try std.testing.expectEqualStrings("encrypted or plain payload", writtenContent.?);

    const loadedTree = try loadMerkleTree(allocator, io, writeStorage);
    try std.testing.expect(loadedTree.?.merkle != null);
}

test "decrypt after decrypt, tree entries use logical hash/length and tree has no .db/files.dat entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    var readStore = MemoryStorage.init(allocator);
    var writeStore = MemoryStorage.init(allocator);
    const readStorage = readStore.asStorage();
    const writeStorage = writeStore.asStorage();
    const logicalContent = "decrypted payload";
    const displayPath = "display/d1";
    var contentReader: std.Io.Reader = .fixed(logicalContent);
    const contentHash = try computeHash(&contentReader);
    var tree = try buildMinimalFilesTree(allocator, &.{displayPath});
    tree = try merkle_tree.upsertItem(allocator, &tree, .{
        .name = displayPath,
        .hash = try allocator.dupe(u8, &contentHash),
        .length = logicalContent.len,
        .lastModified = std.Io.Clock.real.now(io).toMilliseconds(),
    });
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    tree.dirty = false;
    try merkle_tree.saveTree(allocator, io, FILES_TREE_PATH, &tree, readStorage, "FTRE");
    try readStorage.write(allocator, io, displayPath, "application/octet-stream", logicalContent);

    _ = try decrypt(allocator, io, readStorage, writeStorage, noProgress, readStorage);

    const loadedTree = try loadMerkleTree(allocator, io, writeStorage);
    try std.testing.expect(loadedTree.?.merkle != null);
    var leaves = merkle_tree.iterateLeaves(MerkleNode, allocator, loadedTree.?.merkle);
    while (try leaves.next()) |leaf| {
        if (leaf.name) |name| {
            try std.testing.expect(!std.mem.eql(u8, name, ".db/files.dat"));
        }
    }
    const itemInfo = try merkle_tree.getItemInfo(&loadedTree.?, displayPath);
    try std.testing.expect(itemInfo != null);
    try std.testing.expectEqualSlices(u8, &contentHash, itemInfo.?.hash);
    try std.testing.expectEqual(@as(u64, logicalContent.len), itemInfo.?.length);
}

test "decrypt invokes progressCallback when provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    var readStore = MemoryStorage.init(allocator);
    var writeStore = MemoryStorage.init(allocator);
    const readStorage = readStore.asStorage();
    const writeStorage = writeStore.asStorage();
    const tree = try buildMinimalFilesTree(allocator, &.{"a.dat"});
    try merkle_tree.saveTree(allocator, io, FILES_TREE_PATH, &tree, readStorage, "FTRE");
    try readStorage.write(allocator, io, "a.dat", "application/octet-stream", "a");

    var messages: ProgressMessages = .{
        .allocator = allocator,
    };
    const progressCallback: IDecryptProgress = .{
        .context = &messages,
        .function = ProgressMessages.push,
    };
    _ = try decrypt(allocator, io, readStorage, writeStorage, progressCallback, readStorage);

    var sawSavedMerkleTree = false;
    for (messages.messages.items) |message| {
        if (std.mem.indexOf(u8, message, "saved merkle tree") != null) {
            sawSavedMerkleTree = true;
        }
    }
    try std.testing.expect(sawSavedMerkleTree);
}

test "decrypt when readStorage === writeStorage and file is plain, skips write but updates tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    var store = MemoryStorage.init(allocator);
    const storage = store.asStorage();
    const leafFile = "asset/f1";
    const tree = try buildMinimalFilesTree(allocator, &.{leafFile});
    try merkle_tree.saveTree(allocator, io, FILES_TREE_PATH, &tree, storage, "FTRE");
    try storage.write(allocator, io, leafFile, "application/octet-stream", "plain content");

    _ = try decrypt(allocator, io, storage, storage, noProgress, storage);

    const readBack = try storage.read(allocator, io, leafFile);
    try std.testing.expectEqualStrings("plain content", readBack.?);
    const loadedTree = try loadMerkleTree(allocator, io, storage);
    try std.testing.expect(loadedTree.?.merkle != null);
}

test "decrypt returns correct decrypted count for files written to a different storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    var readStore = MemoryStorage.init(allocator);
    var writeStore = MemoryStorage.init(allocator);
    const readStorage = readStore.asStorage();
    const writeStorage = writeStore.asStorage();
    // Use empty tree to avoid BSON leaf files being written to storage.
    const tree = try buildMinimalFilesTree(allocator, &.{});
    try merkle_tree.saveTree(allocator, io, FILES_TREE_PATH, &tree, readStorage, "FTRE");
    try readStorage.write(allocator, io, "f1.dat", "application/octet-stream", "content1");
    try readStorage.write(allocator, io, "f2.dat", "application/octet-stream", "content2");

    const result = try decrypt(allocator, io, readStorage, writeStorage, noProgress, readStorage);

    try std.testing.expectEqual(@as(u64, 2), result.decrypted);
    try std.testing.expectEqual(@as(u64, 0), result.skipped);
}

test "decrypt returns correct skipped count when files are already plain and same storage is used" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    var store = MemoryStorage.init(allocator);
    const storage = store.asStorage();
    // Use empty tree to avoid BSON leaf files being written to storage.
    const tree = try buildMinimalFilesTree(allocator, &.{});
    try merkle_tree.saveTree(allocator, io, FILES_TREE_PATH, &tree, storage, "FTRE");
    try storage.write(allocator, io, "f1.dat", "application/octet-stream", "plain content");

    const result = try decrypt(allocator, io, storage, storage, noProgress, storage);

    try std.testing.expectEqual(@as(u64, 1), result.skipped);
    try std.testing.expectEqual(@as(u64, 0), result.decrypted);
}

test "decrypt throws when merkle tree cannot be loaded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    var readStore = MemoryStorage.init(allocator);
    var writeStore = MemoryStorage.init(allocator);
    const readStorage = readStore.asStorage();
    const writeStorage = writeStore.asStorage();
    try readStorage.write(allocator, io, "asset/x", "application/octet-stream", "x");

    try std.testing.expectError(error.Thrown, decrypt(allocator, io, readStorage, writeStorage, noProgress, readStorage));
    try std.testing.expect(std.mem.indexOf(u8, errors.errorMessage(error.Thrown), "Failed to load merkle tree") != null);
}
