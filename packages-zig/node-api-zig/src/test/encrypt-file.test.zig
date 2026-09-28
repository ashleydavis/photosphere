//
// Tests for encryptFile (port of src/test/lib/encrypt-file.test.ts).
//

const std = @import("std");
const utils = @import("utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const encryption = @import("encryption-zig");
const node_api = @import("node-api-zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const sync_helpers = @import("sync-test-helpers.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const errors = utils.errors;
const IMerkleTree = merkle_tree.IMerkleTree;
const generateKeyPair = encryption.key_utils.generateKeyPair;
const hashPublicKey = encryption.key_utils.hashPublicKey;
const encryptFile = node_api.encrypt.encryptFile;
const computeHash = node_api.hash.computeHash;
const Sha256 = std.crypto.hash.sha2.Sha256;

//
// Stable UUID used for tree construction in tests.
//
const VALID_UUID = "12345678-1234-5678-9abc-123456789abc";

//
// Hash of the public key of the key pair used across all encryptFile tests, derived on first use
// (TypeScript: generated when the file loads).
//
var publicKeyHash: ?[32]u8 = null;

//
// Gets the hash of the public key of the tests, generating the key pair the first time.
//
fn getPublicKeyHash() ![]const u8 {
    if (publicKeyHash == null) {
        const encryptKeyPair = try generateKeyPair(std.heap.page_allocator, std.testing.io);
        publicKeyHash = try hashPublicKey(std.heap.page_allocator, encryptKeyPair.publicKey);
    }
    return &publicKeyHash.?;
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
fn buildTree(allocator: std.mem.Allocator, leafNames: []const []const u8) !IMerkleTree {
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

test "encryptFile writes file to writeStorage" {
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
    var tree = try buildTree(allocator, &.{"asset/f1"});
    try readStorage.write(allocator, io, "asset/f1", "application/octet-stream", "hello");

    _ = try encryptFile(allocator, io, "asset/f1", readStorage, writeStorage, readStorage, try getPublicKeyHash(), &tree, null);

    try std.testing.expect(try writeStorage.fileExists(allocator, io, "asset/f1"));
    const written = try writeStorage.read(allocator, io, "asset/f1");
    try std.testing.expectEqualStrings("hello", written.?);
}

test "encryptFile updates merkle tree entry after writing" {
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
    const content = "update me";
    var contentReader: std.Io.Reader = .fixed(content);
    const contentHash = try computeHash(&contentReader);
    var tree = try buildTree(allocator, &.{"asset/f1"});
    tree = try merkle_tree.upsertItem(allocator, &tree, .{
        .name = "asset/f1",
        .hash = try allocator.dupe(u8, &contentHash),
        .length = content.len,
        .lastModified = std.Io.Clock.real.now(io).toMilliseconds(),
    });
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    tree.dirty = false;
    try readStorage.write(allocator, io, "asset/f1", "application/octet-stream", content);

    _ = try encryptFile(allocator, io, "asset/f1", readStorage, writeStorage, readStorage, try getPublicKeyHash(), &tree, null);

    const info = try merkle_tree.getItemInfo(&tree, "asset/f1");
    try std.testing.expect(info != null);
    try std.testing.expectEqualSlices(u8, &contentHash, info.?.hash);
}

test "encryptFile does not update merkle tree when file has no existing tree entry" {
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
    // Tree has no entry for "asset/f1"
    var tree = try buildTree(allocator, &.{});
    try readStorage.write(allocator, io, "asset/f1", "application/octet-stream", "no tree entry");

    _ = try encryptFile(allocator, io, "asset/f1", readStorage, writeStorage, readStorage, try getPublicKeyHash(), &tree, null);

    try std.testing.expect(try writeStorage.fileExists(allocator, io, "asset/f1"));
    try std.testing.expect(try merkle_tree.getItemInfo(&tree, "asset/f1") == null);
}

test "encryptFile does not update merkle tree for .db/ files" {
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
    var tree = try buildTree(allocator, &.{});
    try readStorage.write(allocator, io, ".db/something", "application/octet-stream", "db file");

    _ = try encryptFile(allocator, io, ".db/something", readStorage, writeStorage, readStorage, try getPublicKeyHash(), &tree, null);

    try std.testing.expect(try writeStorage.fileExists(allocator, io, ".db/something"));
    // Tree should be unmodified (no entry for .db/ files)
    const info = try merkle_tree.getItemInfo(&tree, ".db/something");
    try std.testing.expect(info == null);
}

test "encryptFile throws when source file does not exist" {
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
    var tree = try buildTree(allocator, &.{});

    try std.testing.expectError(error.Thrown, encryptFile(allocator, io, "missing/file.dat", readStorage, writeStorage, readStorage, try getPublicKeyHash(), &tree, null));
    try std.testing.expect(std.mem.indexOf(u8, errors.errorMessage(error.Thrown), "does not exist") != null);
}
