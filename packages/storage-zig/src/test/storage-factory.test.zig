const std = @import("std");
const storage_zig = @import("storage-zig");
const encryption = @import("encryption-zig");
const utils = @import("utils-zig");

const pathJoin = storage_zig.storage_factory.pathJoin;
const createStorage = storage_zig.storage_factory.createStorage;
const StoragePrefixWrapper = storage_zig.storage_prefix_wrapper.StoragePrefixWrapper;
const IPrivateKeyMap = encryption.encryption_types.IPrivateKeyMap;
const crypto = encryption.node_crypto;
const key_utils = encryption.key_utils;

//
// Reads a key fixture of encryption-zig (tests run with the package directory as cwd).
//
fn readKeyFixture(allocator: std.mem.Allocator, fileName: []const u8) ![]u8 {
    const fixturePath = try std.fmt.allocPrint(allocator, "../encryption-zig/src/test/fixtures/{s}", .{fileName});
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, fixturePath, allocator, .unlimited);
}

//
// Loads the TypeScript fixture key pair and builds its key map ("default" and the key hash).
//
const FixtureKeys = struct {
    // The public key.
    publicKey: *const crypto.PublicKey,

    // The key map.
    keyMap: IPrivateKeyMap,
};

//
// Loads the fixture keys.
//
fn loadFixtureKeys(allocator: std.mem.Allocator) !FixtureKeys {
    const privateKey = try crypto.createPrivateKey(allocator, try readKeyFixture(allocator, "ts-private.pem"));
    const publicKey = try crypto.createPublicKey(allocator, try readKeyFixture(allocator, "ts-public.pem"));
    const keyHashHex = try allocator.dupe(u8, &std.fmt.bytesToHex(try key_utils.hashPublicKey(allocator, publicKey), .lower));
    var keyMap: IPrivateKeyMap = .empty;
    try keyMap.put(allocator, "default", privateKey);
    try keyMap.put(allocator, keyHashHex, privateKey);
    return .{ .publicKey = publicKey, .keyMap = keyMap };
}

//
// Returns Node's `path.resolve(text).replace(/\\/g, '/')` for the tests.
//
fn resolved(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.fs.path.resolve(allocator, &.{text});
}

//
// Returns true when the storage is a StoragePrefixWrapper (TypeScript: `toBeInstanceOf(StoragePrefixWrapper)`).
//
fn isStoragePrefixWrapper(storage: storage_zig.storage.IStorage) bool {
    return storage.vtable == storage_zig.storage.implement(StoragePrefixWrapper);
}

// describe('pathJoin')

test "joins multiple segments with forward slashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a/b/c", try pathJoin(arena.allocator(), &.{ "a", "b", "c" }));
}

test "filters out empty string segments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a/b", try pathJoin(arena.allocator(), &.{ "a", "", "b" }));
}

test "removes trailing slash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a/b", try pathJoin(arena.allocator(), &.{ "a", "b/" }));
}

test "collapses consecutive slashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("a/b", try pathJoin(arena.allocator(), &.{"a//b"}));
}

test "returns empty string when all segments are empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("", try pathJoin(arena.allocator(), &.{ "", "" }));
}

test "returns empty string when called with no arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("", try pathJoin(arena.allocator(), &.{}));
}

test "handles a single segment with no slashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("foo", try pathJoin(arena.allocator(), &.{"foo"}));
}

test "handles a protocol-style prefix followed by a path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("fs:/some/path", try pathJoin(arena.allocator(), &.{ "fs:", "/some/path" }));
}

test "pathJoin removes several trailing slashes and a lone slash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("/abs/db", try pathJoin(arena.allocator(), &.{ "/abs/db", "/" }));
    try std.testing.expectEqualStrings("", try pathJoin(arena.allocator(), &.{"/"}));
    try std.testing.expectEqualStrings("/abs/db/.", try pathJoin(arena.allocator(), &.{ "/abs/db", "./" }));
}

// describe('createStorage')

test "throws when rootPath is an empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Thrown, createStorage(arena.allocator(), std.testing.io, "", null, null));
    try std.testing.expectEqualStrings("Path is required", utils.errors.lastErrorMessage());
}

// describe('fs: prefix')

test "returns type \"fs\"" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try createStorage(arena.allocator(), std.testing.io, "fs:/some/path", null, null);
    try std.testing.expectEqualStrings("fs", result.@"type");
}

test "normalizedPath resolves the path after stripping the prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = try createStorage(allocator, std.testing.io, "fs:/some/path", null, null);
    try std.testing.expectEqualStrings(try resolved(allocator, "/some/path"), result.normalizedPath);
}

test "storage is a StoragePrefixWrapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try createStorage(arena.allocator(), std.testing.io, "fs:/some/path", null, null);
    try std.testing.expect(isStoragePrefixWrapper(result.storage));
}

test "rawStorage is a StoragePrefixWrapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try createStorage(arena.allocator(), std.testing.io, "fs:/some/path", null, null);
    try std.testing.expect(isStoragePrefixWrapper(result.rawStorage));
}

test "storage and rawStorage have the same location" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try createStorage(arena.allocator(), std.testing.io, "fs:/some/path", null, null);
    try std.testing.expectEqualStrings(result.rawStorage.location, result.storage.location);
    try std.testing.expectEqualStrings("fs:/some/path", result.storage.location);
}

// describe('s3: prefix')

test "returns type \"s3\"" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try createStorage(arena.allocator(), std.testing.io, "s3:my-bucket/my-prefix", null, null);
    try std.testing.expectEqualStrings("s3", result.@"type");
}

test "normalizedPath strips the s3: prefix without resolving" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try createStorage(arena.allocator(), std.testing.io, "s3:my-bucket/my-prefix", null, null);
    try std.testing.expectEqualStrings("my-bucket/my-prefix", result.normalizedPath);
}

test "s3 storage is a StoragePrefixWrapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try createStorage(arena.allocator(), std.testing.io, "s3:my-bucket/my-prefix", null, null);
    try std.testing.expect(isStoragePrefixWrapper(result.storage));
}

test "s3 storage and rawStorage have the same location" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try createStorage(arena.allocator(), std.testing.io, "s3:my-bucket/my-prefix", null, null);
    try std.testing.expectEqualStrings(result.rawStorage.location, result.storage.location);
    try std.testing.expectEqualStrings("s3:/my-bucket/my-prefix", result.storage.location);
}

// describe('no prefix (bare path)')

test "returns type \"fs\" for a bare absolute path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try createStorage(arena.allocator(), std.testing.io, "/absolute/path", null, null);
    try std.testing.expectEqualStrings("fs", result.@"type");
}

test "normalizedPath resolves the bare path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = try createStorage(allocator, std.testing.io, "/absolute/path", null, null);
    try std.testing.expectEqualStrings(try resolved(allocator, "/absolute/path"), result.normalizedPath);
}

test "bare storage and rawStorage have the same location" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try createStorage(arena.allocator(), std.testing.io, "/absolute/path", null, null);
    try std.testing.expectEqualStrings(result.rawStorage.location, result.storage.location);
}

test "normalizedPath resolves a relative bare path against the current directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = try createStorage(allocator, std.testing.io, "some/../relative/./path/", null, null);
    const currentPath = try std.process.currentPathAlloc(std.testing.io, allocator);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "{s}/relative/path", .{currentPath}), result.normalizedPath);
}

// describe('with encryption options')

test "returns type \"encrypted-fs\" when both keys are provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadFixtureKeys(allocator);
    const result = try createStorage(allocator, std.testing.io, "fs:/some/path", null, .{
        .encryptionPublicKey = keys.publicKey,
        .decryptionKeyMap = keys.keyMap,
    });
    try std.testing.expectEqualStrings("encrypted-fs", result.@"type");
}

test "returns type \"encrypted-s3\" for s3 path with encryption" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadFixtureKeys(allocator);
    const result = try createStorage(allocator, std.testing.io, "s3:my-bucket/path", null, .{
        .encryptionPublicKey = keys.publicKey,
        .decryptionKeyMap = keys.keyMap,
    });
    try std.testing.expectEqualStrings("encrypted-s3", result.@"type");
}

test "storage and rawStorage have the same location when encrypted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadFixtureKeys(allocator);
    const result = try createStorage(allocator, std.testing.io, "fs:/some/path", null, .{
        .encryptionPublicKey = keys.publicKey,
        .decryptionKeyMap = keys.keyMap,
    });
    try std.testing.expectEqualStrings(result.rawStorage.location, result.storage.location);
}

test "rawStorage is a StoragePrefixWrapper when encrypted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadFixtureKeys(allocator);
    const result = try createStorage(allocator, std.testing.io, "fs:/some/path", null, .{
        .encryptionPublicKey = keys.publicKey,
        .decryptionKeyMap = keys.keyMap,
    });
    try std.testing.expect(isStoragePrefixWrapper(result.rawStorage));
}

test "does not encrypt when only decryptionKeyMap is provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadFixtureKeys(allocator);
    const result = try createStorage(allocator, std.testing.io, "fs:/some/path", null, .{
        .decryptionKeyMap = keys.keyMap,
    });
    try std.testing.expectEqualStrings("fs", result.@"type");
}

test "does not encrypt when only encryptionPublicKey is provided" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const keys = try loadFixtureKeys(allocator);
    const result = try createStorage(allocator, std.testing.io, "fs:/some/path", null, .{
        .encryptionPublicKey = keys.publicKey,
    });
    try std.testing.expectEqualStrings("fs", result.@"type");
}
