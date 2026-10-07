//
// Tests for encryptableFiles and encrypt (port of src/test/lib/encrypt.test.ts).
//

const std = @import("std");
const utils = @import("utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const encryption = @import("encryption-zig");
const node_api = @import("node-api-zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const fixture_keys = @import("fixture-keys.zig");
const sync_helpers = @import("sync-test-helpers.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const errors = utils.errors;
const HashedItem = merkle_tree.HashedItem;
const IMerkleTree = merkle_tree.IMerkleTree;
const MerkleNode = merkle_tree.MerkleNode;
const IKeyPair = encryption.key_utils.IKeyPair;
const hashPublicKey = encryption.key_utils.hashPublicKey;
const encrypt = node_api.encrypt.encrypt;
const encryptableFiles = node_api.encrypt.encryptableFiles;
const IEncryptProgress = node_api.encrypt.IEncryptProgress;
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
// Gets the key pair all the encrypt tests use, loaded from the fixture keys (TypeScript: generated when the file loads).
//
fn getEncryptKeyPair(allocator: std.mem.Allocator) !IKeyPair {
    return fixture_keys.loadFixtureKeyPair(allocator, std.testing.io);
}

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
// Collects every file name the encryptableFiles iterator yields.
//
fn collectFiles(allocator: std.mem.Allocator, storage: *MemoryStorage) ![]const []const u8 {
    var results: std.ArrayList([]const u8) = .empty;
    var files = try encryptableFiles(allocator, std.testing.io, storage.asStorage());
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
const noProgress: IEncryptProgress = .{
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

test "encryptableFiles yields regular files" {
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

test "encryptableFiles excludes .db/files.dat" {
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

test "encryptableFiles excludes .db/encryption.pub" {
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

test "encryptableFiles excludes README.md" {
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

test "encryptableFiles yields nothing for empty storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const files = try collectFiles(allocator, &storage);
    try std.testing.expectEqual(@as(usize, 0), files.len);
}

test "encryptableFiles excludes .db/config.json" {
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

test "encrypt copies all files from read storage to write storage and updates merkle tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    const keyPair = try getEncryptKeyPair(allocator);
    var readStore = MemoryStorage.init(allocator);
    var writeStore = MemoryStorage.init(allocator);
    const readStorage = readStore.asStorage();
    const writeStorage = writeStore.asStorage();

    const leafFile = "some/file.dat";
    const tree = try buildMinimalFilesTree(allocator, &.{leafFile});
    try merkle_tree.saveTree(allocator, io, FILES_TREE_PATH, &tree, readStorage, "FTRE");
    try readStorage.write(allocator, io, leafFile, "application/octet-stream", "file content");

    _ = try encrypt(allocator, io, readStorage, writeStorage, noProgress, keyPair.publicKey, readStorage);

    try std.testing.expect(try writeStorage.fileExists(allocator, io, FILES_TREE_PATH));
    try std.testing.expect(try writeStorage.fileExists(allocator, io, leafFile));
    const writtenContent = try writeStorage.read(allocator, io, leafFile);
    try std.testing.expectEqualStrings("file content", writtenContent.?);

    const loadedTree = try loadMerkleTree(allocator, io, writeStorage);
    try std.testing.expect(loadedTree.?.merkle != null);
}

test "encrypt invokes progressCallback when provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    const keyPair = try getEncryptKeyPair(allocator);
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
    const progressCallback: IEncryptProgress = .{
        .context = &messages,
        .function = ProgressMessages.push,
    };
    _ = try encrypt(allocator, io, readStorage, writeStorage, progressCallback, keyPair.publicKey, readStorage);

    var sawSavedMerkleTree = false;
    for (messages.messages.items) |message| {
        if (std.mem.indexOf(u8, message, "saved merkle tree") != null) {
            sawSavedMerkleTree = true;
        }
    }
    try std.testing.expect(sawSavedMerkleTree);
}

test "encrypt throws when merkle tree cannot be loaded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    const keyPair = try getEncryptKeyPair(allocator);
    var readStore = MemoryStorage.init(allocator);
    var writeStore = MemoryStorage.init(allocator);
    const readStorage = readStore.asStorage();
    const writeStorage = writeStore.asStorage();
    try readStorage.write(allocator, io, "asset/x", "application/octet-stream", "x");

    try std.testing.expectError(error.Thrown, encrypt(allocator, io, readStorage, writeStorage, noProgress, keyPair.publicKey, readStorage));
    try std.testing.expect(std.mem.indexOf(u8, errors.errorMessage(error.Thrown), "Failed to load merkle tree from database") != null);
}

test "encrypt returns correct encrypted count for newly encrypted files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    const keyPair = try getEncryptKeyPair(allocator);
    var readStore = MemoryStorage.init(allocator);
    var writeStore = MemoryStorage.init(allocator);
    const readStorage = readStore.asStorage();
    const writeStorage = writeStore.asStorage();
    // Use empty tree to avoid BSON leaf files being written to storage.
    const tree = try buildMinimalFilesTree(allocator, &.{});
    try merkle_tree.saveTree(allocator, io, FILES_TREE_PATH, &tree, readStorage, "FTRE");
    try readStorage.write(allocator, io, "a.dat", "application/octet-stream", "a");
    try readStorage.write(allocator, io, "b.dat", "application/octet-stream", "b");

    const result = try encrypt(allocator, io, readStorage, writeStorage, noProgress, keyPair.publicKey, readStorage);

    try std.testing.expectEqual(@as(u64, 2), result.encrypted);
    try std.testing.expectEqual(@as(u64, 0), result.skipped);
}

test "encrypt skips files already encrypted with the same key and returns correct skipped count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    const keyPair = try getEncryptKeyPair(allocator);
    var readStore = MemoryStorage.init(allocator);
    var writeStore = MemoryStorage.init(allocator);
    const readStorage = readStore.asStorage();
    const writeStorage = writeStore.asStorage();
    const publicKeyHash = try hashPublicKey(allocator, keyPair.publicKey);
    const fakeHeader = try std.mem.concat(allocator, u8, &.{
        "PSEN",
        &[_]u8{0} ** 4,
        "A2CB",
        &publicKeyHash,
    });
    // Use empty tree to avoid BSON leaf files being written to storage.
    const tree = try buildMinimalFilesTree(allocator, &.{});
    try merkle_tree.saveTree(allocator, io, FILES_TREE_PATH, &tree, readStorage, "FTRE");
    try readStorage.write(allocator, io, "already.dat", "application/octet-stream", fakeHeader);

    const result = try encrypt(allocator, io, readStorage, writeStorage, noProgress, keyPair.publicKey, readStorage);

    try std.testing.expectEqual(@as(u64, 1), result.skipped);
    try std.testing.expectEqual(@as(u64, 0), result.encrypted);
}

test "encrypt tree entries for tree-tracked files use logical hash, length, lastModified; tree has no .db/files.dat entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    const keyPair = try getEncryptKeyPair(allocator);
    var readStore = MemoryStorage.init(allocator);
    var writeStore = MemoryStorage.init(allocator);
    const readStorage = readStore.asStorage();
    const writeStorage = writeStore.asStorage();
    const logicalContent = "logical file content";
    const assetPath = "asset/f1";
    var contentReader: std.Io.Reader = .fixed(logicalContent);
    const contentHash = try computeHash(&contentReader);
    var tree = try buildMinimalFilesTree(allocator, &.{assetPath});
    tree = try merkle_tree.upsertItem(allocator, &tree, .{
        .name = assetPath,
        .hash = try allocator.dupe(u8, &contentHash),
        .length = logicalContent.len,
        .lastModified = std.Io.Clock.real.now(io).toMilliseconds(),
    });
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    tree.dirty = false;
    try merkle_tree.saveTree(allocator, io, FILES_TREE_PATH, &tree, readStorage, "FTRE");
    try readStorage.write(allocator, io, assetPath, "application/octet-stream", logicalContent);

    _ = try encrypt(allocator, io, readStorage, writeStorage, noProgress, keyPair.publicKey, readStorage);

    const loadedTree = try loadMerkleTree(allocator, io, writeStorage);
    try std.testing.expect(loadedTree.?.merkle != null);
    var leaves = merkle_tree.iterateLeaves(MerkleNode, allocator, loadedTree.?.merkle);
    while (try leaves.next()) |leaf| {
        if (leaf.name) |name| {
            try std.testing.expect(!std.mem.eql(u8, name, ".db/files.dat"));
        }
    }
    const itemInfo = try merkle_tree.getItemInfo(&loadedTree.?, assetPath);
    try std.testing.expect(itemInfo != null);
    try std.testing.expectEqualSlices(u8, &contentHash, itemInfo.?.hash);
    try std.testing.expectEqual(@as(u64, logicalContent.len), itemInfo.?.length);
    try std.testing.expect(itemInfo.?.lastModified > 0);
}
