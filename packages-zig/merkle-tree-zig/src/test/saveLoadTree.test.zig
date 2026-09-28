//
// Tests for saveTree, loadTree and loadTreeVersion (port of src/test/saveLoadTree.test.ts).
// (Zig: the TypeScript tests use FileStorage on temporary files; these use the in-memory storage.)
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
const memory_storage = @import("memory-storage.zig");
const errors = @import("utils-zig").errors;
const bson = @import("serialization-zig").bson;
const serialization = @import("serialization-zig").serialization;
const merkle_tree = merkle_tree_zig.merkle_tree;
const IMerkleTree = merkle_tree.IMerkleTree;
const SortNode = merkle_tree.SortNode;
const MemoryStorage = memory_storage.MemoryStorage;

//
// The Io used by the tests.
//
const io = std.testing.io;

//
// The file the tests save to.
//
const TEST_FILE_PATH = "test-tree-v2.bin";

//
// Helper function to build a tree with the given file names
//
fn buildTree(allocator: std.mem.Allocator, fileNames: []const []const u8) !IMerkleTree {
    var merkleTree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    for (fileNames) |fileName| {
        merkleTree = try merkle_tree.addItem(allocator, &merkleTree, try merkle_verify.createSha256HashedItem(allocator, fileName, fileName, fileName.len));
    }
    merkleTree.dirty = false;
    merkleTree.merkle = try merkle_tree.buildMerkleTree(allocator, merkleTree.sort);
    return merkleTree;
}

//
// Helper function to compare two binary trees
//
fn compareTrees(original: ?*const SortNode, loaded: ?*const SortNode) !void {
    if (original == null and loaded == null) {
        return;
    }
    if (original == null or loaded == null) {
        return error.TreeStructureMismatch;
    }
    try std.testing.expectEqual(original.?.nodeCount, loaded.?.nodeCount);
    try std.testing.expectEqual(original.?.leafCount, loaded.?.leafCount);
    try std.testing.expectEqual(original.?.size, loaded.?.size);
    try std.testing.expectEqualStrings(original.?.minName, loaded.?.minName);
    try std.testing.expectEqual(original.?.lastModified, loaded.?.lastModified);
    try compareTrees(original.?.left, loaded.?.left);
    try compareTrees(original.?.right, loaded.?.right);
}

//
// Saves a tree and loads it back.
//
fn saveAndLoad(allocator: std.mem.Allocator, tree: *const IMerkleTree) !IMerkleTree {
    var storage = MemoryStorage.init(allocator);
    try merkle_tree.saveTree(allocator, io, TEST_FILE_PATH, tree, storage.asStorage(), "FTRE");
    return (try merkle_tree.loadTree(allocator, io, TEST_FILE_PATH, storage.asStorage(), "FTRE")).?;
}

test "should save and load a small tree correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const originalTree = try buildTree(allocator, &.{ "A", "B" });
    const loadedTree = try saveAndLoad(allocator, &originalTree);

    try std.testing.expectEqual(originalTree.sort.?.leafCount, loadedTree.sort.?.leafCount);
    try std.testing.expectEqual(originalTree.sort.?.nodeCount, loadedTree.sort.?.nodeCount);
    try std.testing.expectEqual(@as(u32, 2), loadedTree.sort.?.leafCount);

    var leaves = merkle_tree.iterateLeaves(SortNode, allocator, loadedTree.sort);
    const leafA = (try leaves.next()).?;
    const leafB = (try leaves.next()).?;
    try std.testing.expectEqualStrings("A", leafA.name.?);
    try std.testing.expectEqualStrings("B", leafB.name.?);
    try std.testing.expectEqual(@as(usize, 32), leafA.contentHash.?.len);
    try std.testing.expectEqual(@as(usize, 32), leafB.contentHash.?.len);

    try compareTrees(originalTree.sort, loadedTree.sort);
}

test "should save and load a complex tree correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const fileNames = [_][]const u8{ "A", "B", "C", "D", "E", "F", "G" };
    const originalTree = try buildTree(allocator, &fileNames);
    const loadedTree = try saveAndLoad(allocator, &originalTree);

    try std.testing.expectEqual(@as(u32, fileNames.len), loadedTree.sort.?.leafCount);
    try std.testing.expectEqual(originalTree.sort.?.nodeCount, loadedTree.sort.?.nodeCount);
    try compareTrees(originalTree.sort, loadedTree.sort);

    // Verify hash integrity - the root hash should match
    try std.testing.expectEqualSlices(u8, originalTree.merkle.?.hash, loadedTree.merkle.?.hash);
    try std.testing.expectEqual(originalTree.merkle.?.nodeCount, loadedTree.merkle.?.nodeCount);
}

test "should handle trees with special characters in file names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const specialChars = "file-with-special-chars-!@#$%^&*()_+.txt";
    const tree = try buildTree(allocator, &.{specialChars});
    const loadedTree = try saveAndLoad(allocator, &tree);

    try std.testing.expectEqual(tree.sort.?.nodeCount, loadedTree.sort.?.nodeCount);
    try std.testing.expectEqualStrings(specialChars, loadedTree.sort.?.name.?);
    try std.testing.expectEqualSlices(u8, tree.sort.?.contentHash.?, loadedTree.sort.?.contentHash.?);
}

test "should handle large trees efficiently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fileNames: [100][]const u8 = undefined;
    for (&fileNames, 0..) |*fileName, index| {
        fileName.* = try std.fmt.allocPrint(allocator, "file-{d}.txt", .{index});
    }
    const originalTree = try buildTree(allocator, &fileNames);
    const loadedTree = try saveAndLoad(allocator, &originalTree);

    try std.testing.expectEqual(@as(u32, 100), loadedTree.sort.?.leafCount);
    try std.testing.expectEqual(originalTree.sort.?.nodeCount, loadedTree.sort.?.nodeCount);
    try compareTrees(originalTree.sort, loadedTree.sort);
}

test "saveTree throws for a dirty tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTree(allocator, &.{"A"});
    tree.dirty = true;
    var storage = MemoryStorage.init(allocator);
    try std.testing.expectError(error.Thrown, merkle_tree.saveTree(allocator, io, TEST_FILE_PATH, &tree, storage.asStorage(), "FTRE"));
    try std.testing.expectEqualStrings("Tree is dirty. Cannot save. Make sure to rebuild the tree before saving.", errors.lastErrorMessage());
}

test "saveTree throws for an id that is not a UUID" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = merkle_tree.createTree("test-tree");
    var storage = MemoryStorage.init(allocator);
    try std.testing.expectError(error.Thrown, merkle_tree.saveTree(allocator, io, TEST_FILE_PATH, &tree, storage.asStorage(), "FTRE"));
    try std.testing.expectEqualStrings("Invalid UUID", errors.lastErrorMessage());
}

test "saveTree throws like Buffer.writeUInt32LE for a last modified date before 1970" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildTree(allocator, &.{"A"});
    tree.sort.?.lastModified = -315619200000; // 1960-01-01T00:00:00.000Z
    var storage = MemoryStorage.init(allocator);
    try std.testing.expectError(error.Thrown, merkle_tree.saveTree(allocator, io, TEST_FILE_PATH, &tree, storage.asStorage(), "FTRE"));
    try std.testing.expectEqualStrings("The value of \"value\" is out of range. It must be >= 0 and <= 4294967295. Received -74", errors.lastErrorMessage());
}

test "saves and loads an empty tree and its database metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    var metadata: bson.BsonDocument = .empty;
    try metadata.put(allocator, "filesImported", .{ .number = 3 });
    tree.databaseMetadata = metadata;

    const loadedTree = try saveAndLoad(allocator, &tree);
    try std.testing.expect(loadedTree.sort == null);
    try std.testing.expect(loadedTree.merkle == null);
    try std.testing.expectEqual(@as(u32, 6), loadedTree.version);
    try std.testing.expect(!loadedTree.dirty);
    try std.testing.expect(loadedTree.databaseMetadata.?.eql(metadata));
}

test "loadTree returns undefined for a missing file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try std.testing.expect((try merkle_tree.loadTree(allocator, io, "missing.dat", storage.asStorage(), "FTRE")) == null);
}

test "should load version from a valid tree file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const originalTree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    var storage = MemoryStorage.init(allocator);
    try merkle_tree.saveTree(allocator, io, "test-tree-version.bin", &originalTree, storage.asStorage(), "FTRE");
    try std.testing.expectEqual(@as(?u32, merkle_tree.CURRENT_DATABASE_VERSION), merkle_tree.loadTreeVersion(allocator, io, "test-tree-version.bin", storage.asStorage()));
}

test "should return undefined for non-existent file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try std.testing.expectEqual(@as(?u32, null), merkle_tree.loadTreeVersion(allocator, io, "non-existent-file.bin", storage.asStorage()));
}

test "should return undefined for empty file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try storage.putFile("test-tree-version.bin", "");
    try std.testing.expectEqual(@as(?u32, null), merkle_tree.loadTreeVersion(allocator, io, "test-tree-version.bin", storage.asStorage()));
}

test "should return undefined for file with less than 4 bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try storage.putFile("test-tree-version.bin", &.{ 0x01, 0x02 });
    try std.testing.expectEqual(@as(?u32, null), merkle_tree.loadTreeVersion(allocator, io, "test-tree-version.bin", storage.asStorage()));
}

test "should correctly read version from file with exactly 4 bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var versionBuffer: [4]u8 = undefined;
    std.mem.writeInt(u32, &versionBuffer, 42, .little);
    try storage.putFile("test-tree-version.bin", &versionBuffer);
    try std.testing.expectEqual(@as(?u32, 42), merkle_tree.loadTreeVersion(allocator, io, "test-tree-version.bin", storage.asStorage()));
}

test "should read version from large file without loading entire file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const completeFile = try allocator.alloc(u8, 4 + 1024 * 1024);
    @memset(completeFile, 0xFF);
    std.mem.writeInt(u32, completeFile[0..4], 123, .little);
    try storage.putFile("test-tree-version.bin", completeFile);
    try std.testing.expectEqual(@as(?u32, 123), merkle_tree.loadTreeVersion(allocator, io, "test-tree-version.bin", storage.asStorage()));
}

test "should handle different version values correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const testVersions = [_]u32{ 0, 1, 2, 3, 255, 65535, 4294967295 }; // Test edge cases
    for (testVersions) |expectedVersion| {
        var versionBuffer: [4]u8 = undefined;
        std.mem.writeInt(u32, &versionBuffer, expectedVersion, .little);
        try storage.putFile("test-tree-version.bin", &versionBuffer);
        try std.testing.expectEqual(@as(?u32, expectedVersion), merkle_tree.loadTreeVersion(allocator, io, "test-tree-version.bin", storage.asStorage()));
    }
}

test "should work correctly with large tree files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var originalTree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    var index: usize = 0;
    while (index < 100) {
        const fileName = try std.fmt.allocPrint(allocator, "file-{d:0>3}.txt", .{index});
        originalTree = try merkle_tree.addItem(allocator, &originalTree, try merkle_verify.createSha256HashedItem(allocator, fileName, fileName, fileName.len));
        index += 1;
    }
    originalTree.dirty = false;
    originalTree.merkle = try merkle_tree.buildMerkleTree(allocator, originalTree.sort);

    var storage = MemoryStorage.init(allocator);
    try merkle_tree.saveTree(allocator, io, "test-tree-version.bin", &originalTree, storage.asStorage(), "FTRE");

    const version = merkle_tree.loadTreeVersion(allocator, io, "test-tree-version.bin", storage.asStorage());
    const fullTree = (try merkle_tree.loadTree(allocator, io, "test-tree-version.bin", storage.asStorage(), "FTRE")).?;

    try std.testing.expectEqual(@as(?u32, merkle_tree.CURRENT_DATABASE_VERSION), version);
    try std.testing.expectEqual(merkle_tree.CURRENT_DATABASE_VERSION, fullTree.version);
    try std.testing.expectEqual(@as(u32, 100), fullTree.sort.?.leafCount);
}

//
// The streams of a hand-written tree file, to check how loadTree reads files that are not what saveTree writes.
// Files of version 5 and later hold a string table of one string ("a") and a hash table of one hash.
//
const ITreeFile = struct {
    // The file format version.
    version: u32,

    // The 32-bit values of the sort tree.
    sortTree: []const u32,

    // The 32-bit values of the merkle tree.
    merkleTree: []const u32,
};

//
// Writes the values of a stream through a compressed serializer when compressed, otherwise straight to the file.
//
fn writeStream(allocator: std.mem.Allocator, serializer: serialization.ISerializer, values: []const u32, compressed: bool) !void {
    if (!compressed) {
        for (values) |value| {
            try serializer.writeUInt32(value);
        }
        return;
    }
    var streamSerializer = try serialization.CompressedBinarySerializer.init(allocator, serializer, 64);
    for (values) |value| {
        try streamSerializer.writeUInt32(value);
    }
    try streamSerializer.finish();
}

//
// Serializes a hand-written tree file (the SerializerFunction of serialization.save).
//
fn writeTreeFile(allocator: std.mem.Allocator, file: ITreeFile, serializer: serialization.ISerializer) anyerror!void {
    try serializer.writeBSON(bson.BsonDocument.empty);
    try serializer.writeBytes(&([_]u8{0} ** 16));
    const withTables = file.version >= 5;
    if (withTables) {
        var strings = try serialization.CompressedBinarySerializer.init(allocator, serializer, 64);
        try strings.writeUInt32(1);
        try strings.writeString("a");
        try strings.finish();
        try serializer.writeUInt32(1);
        try serializer.writeBytes(&([_]u8{7} ** 32));
    }
    try writeStream(allocator, serializer, file.sortTree, withTables);
    try writeStream(allocator, serializer, file.merkleTree, withTables);
}

//
// Saves a hand-written tree file and loads it with loadTree.
//
fn loadTreeFile(allocator: std.mem.Allocator, file: ITreeFile) !?IMerkleTree {
    var storage = MemoryStorage.init(allocator);
    try serialization.save(allocator, io, storage.asStorage(), TEST_FILE_PATH, file, file.version, "FTRE", writeTreeFile);
    return merkle_tree.loadTree(allocator, io, TEST_FILE_PATH, storage.asStorage(), "FTRE");
}

//
// A version 6 tree file with an index out of bounds, and the message loadTree throws for it.
//
const IOutOfBoundsTreeFile = struct {
    // The 32-bit values of the sort tree.
    sortTree: []const u32,

    // The 32-bit values of the merkle tree.
    merkleTree: []const u32,

    // The message thrown.
    message: []const u8,
};

test "loadTree throws for a string or hash index outside the file's tables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cases = [_]IOutOfBoundsTreeFile{
        // A sort leaf naming string 5.
        .{ .sortTree = &.{ 1, 5, 0, 0, 0, 0, 0 }, .merkleTree = &.{0}, .message = "name index 5 is out of bounds for string table of size 1" },
        // A sort leaf whose content is hash 9.
        .{ .sortTree = &.{ 1, 0, 9, 0, 0, 0, 0 }, .merkleTree = &.{0}, .message = "Content hash index 9 is out of bounds for hash table of size 1" },
        // A merkle root whose hash is hash 3.
        .{ .sortTree = &.{0}, .merkleTree = &.{ 1, 3 }, .message = "Hash index 3 is out of bounds for hash table of size 1" },
        // A merkle root leaf naming string 4.
        .{ .sortTree = &.{0}, .merkleTree = &.{ 1, 0, 4 }, .message = "name index 4 is out of bounds for string table of size 1" },
        // A merkle child whose hash is hash 2.
        .{ .sortTree = &.{0}, .merkleTree = &.{ 3, 0, 1, 2 }, .message = "Hash index 2 is out of bounds for hash table of size 1" },
        // A merkle child leaf naming string 6.
        .{ .sortTree = &.{0}, .merkleTree = &.{ 3, 0, 1, 0, 6 }, .message = "name index 6 is out of bounds for string table of size 1" },
    };
    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.message});
        try std.testing.expectError(error.Thrown, loadTreeFile(allocator, .{ .version = 6, .sortTree = case.sortTree, .merkleTree = case.merkleTree }));
        try std.testing.expectEqualStrings(case.message, errors.lastErrorMessage());
    }
}

test "loadTree reads a version 6 file of an empty tree, and a version 4 file with no sort or merkle tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const versionSix = (try loadTreeFile(allocator, .{ .version = 6, .sortTree = &.{0}, .merkleTree = &.{0} })).?;
    try std.testing.expect(versionSix.sort == null and versionSix.merkle == null);

    const versionFour = (try loadTreeFile(allocator, .{ .version = 4, .sortTree = &.{0}, .merkleTree = &.{0} })).?;
    try std.testing.expectEqual(@as(u32, 4), versionFour.version);
    try std.testing.expect(versionFour.sort == null and versionFour.merkle == null);
}

test "saveTree refuses a hash that is not 32 bytes, or a leaf without a name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    var shortHashLeaf: SortNode = .{ .name = "A", .contentHash = "short", .nodeCount = 1, .leafCount = 1, .size = 1, .minName = "A" };
    var shortHashTree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    shortHashTree.sort = &shortHashLeaf;
    try std.testing.expectError(error.Thrown, merkle_tree.saveTree(allocator, io, TEST_FILE_PATH, &shortHashTree, storage.asStorage(), "FTRE"));
    try std.testing.expectEqualStrings("BufferSet expects 32-byte hashes (SHA-256), got 5 bytes", errors.lastErrorMessage());

    const hash = [_]u8{1} ** 32;
    var namelessLeaf: SortNode = .{ .contentHash = &hash, .nodeCount = 1, .leafCount = 1, .size = 1, .minName = "" };
    var namelessTree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    namelessTree.sort = &namelessLeaf;
    try std.testing.expectError(error.Thrown, merkle_tree.saveTree(allocator, io, TEST_FILE_PATH, &namelessTree, storage.asStorage(), "FTRE"));
    try std.testing.expectEqualStrings("Leaf node has no name. This could be a bug.", errors.lastErrorMessage());

    // A merkle leaf without a name, under a sort tree that is fine.
    var namedLeaf: SortNode = .{ .name = "A", .contentHash = &hash, .nodeCount = 1, .leafCount = 1, .size = 1, .minName = "A" };
    var namelessMerkleLeaf: merkle_tree.MerkleNode = .{ .hash = &hash, .nodeCount = 1 };
    var namelessMerkleTree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    namelessMerkleTree.sort = &namedLeaf;
    namelessMerkleTree.merkle = &namelessMerkleLeaf;
    try std.testing.expectError(error.Thrown, merkle_tree.saveTree(allocator, io, TEST_FILE_PATH, &namelessMerkleTree, storage.asStorage(), "FTRE"));
    try std.testing.expectEqualStrings("Leaf node has no name", errors.lastErrorMessage());

    // buildMerkleTree refuses the nameless sort leaf too.
    try std.testing.expectError(error.Thrown, merkle_tree.buildMerkleTree(allocator, &namelessLeaf));
    try std.testing.expectEqualStrings("Leaf node has no name", errors.lastErrorMessage());
}

test "loadTree throws for an internal sort node whose child is an empty tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Version 6: an internal node (3) whose left child is empty (0).
    try std.testing.expectError(error.Thrown, loadTreeFile(allocator, .{ .version = 6, .sortTree = &.{ 3, 0, 0 }, .merkleTree = &.{0} }));
    try std.testing.expectEqualStrings("TypeError: Cannot read properties of undefined (reading 'leafCount')", errors.lastErrorMessage());

    // Version 4: the same, with the leaf count and size of the internal node.
    try std.testing.expectError(error.Thrown, loadTreeFile(allocator, .{ .version = 4, .sortTree = &.{ 3, 2, 0, 0, 0, 0 }, .merkleTree = &.{0} }));
    try std.testing.expectEqualStrings("TypeError: Cannot read properties of undefined (reading 'leafCount')", errors.lastErrorMessage());
}
