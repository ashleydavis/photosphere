//
// Tests for the lengths a push hands over (port of src/test/lib/sync-encrypted-lengths.test.ts).
//
// A database that is encrypted at rest holds ciphertext and reads out plaintext, and the plaintext's
// length cannot be worked back out of the ciphertext's, so the store says it cannot say. Taking the
// stored size instead and handing it over as the length of the stream made the target declare a
// Content-Length it then fell short of by the encryption's overhead. Measured on a Pixel 6 pushing to
// MinIO on the same LAN, S3 waited thirty seconds for a remainder that was never coming and refused
// every file with "A timeout occurred while trying to lock a resource, please reduce your request
// rate", three attempts each, and the sync copied nothing at all for as long as it was left running.
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const node_api = @import("node-api-zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const sync_helpers = @import("sync-test-helpers.zig");
const SpyStorage = sync_helpers.SpyStorage;
const merkle_tree = merkle_tree_zig.merkle_tree;
const IStorage = @import("storage-zig").storage.IStorage;
const BsonDocument = @import("serialization-zig").bson.BsonDocument;
const pushFiles = node_api.sync.pushFiles;
const throughTheDatabases = node_api.sync.throughTheDatabases;

//
// The id of the test databases.
//
const dbId = "7c3d4e5f-8a9b-4c0d-9e1f-2a3b4c5d6e7f";

//
// How much longer the stored file is than what the database holds, as the encrypted format makes it.
//
const ENCRYPTION_OVERHEAD = 576;

//
// The file the tests push.
//
const fileName = "asset/one.jpg";

//
// Fills a storage with the given files and a merkle tree describing exactly them, under the lengths
// the store reports, which is what every import records.
//
fn fillDatabase(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, fileNames: []const []const u8) !void {
    var tree = merkle_tree.createTree(dbId);
    for (fileNames) |name| {
        try storage.write(allocator, io, name, "image/jpeg", name);
        const info = (try storage.info(allocator, io, name)).?;
        tree = try merkle_tree.addItem(allocator, &tree, .{
            .name = name,
            .hash = try sync_helpers.hashOf(allocator, name),
            .length = info.length,
            .lastModified = 1767225600000, // 2026-01-01T00:00:00.000Z
        });
    }
    var databaseMetadata: BsonDocument = .empty;
    try databaseMetadata.put(allocator, "filesImported", .{ .number = @floatFromInt(fileNames.len) });
    tree.databaseMetadata = databaseMetadata;
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    tree.dirty = false;
    try merkle_tree.saveTree(allocator, io, ".db/files.dat", &tree, storage, "FTRE");
}

test "a source that cannot say how long it reads has no length declared for it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();

    var sourceStore = MemoryStorage.init(allocator);
    var source: SpyStorage = .{ .allocator = allocator, .inner = sourceStore.asStorage(), .infoLengthOverhead = ENCRYPTION_OVERHEAD, .readableLengthUnknown = true };
    try fillDatabase(allocator, io, source.storage(), &.{fileName});

    var targetStore = MemoryStorage.init(allocator);
    var target: SpyStorage = .{ .allocator = allocator, .inner = targetStore.asStorage() };
    try fillDatabase(allocator, io, target.storage(), &.{});

    try pushFiles(allocator, io, source.storage(), target.storage(), try sync_helpers.makeBsonDatabase(allocator, target.storage()), throughTheDatabases(source.storage(), target.storage()));

    try std.testing.expect(target.declaredLengths.contains(fileName));
    try std.testing.expectEqual(@as(?u64, null), target.declaredLengths.get(fileName).?);
}

test "a source that reads out what it stores has its own length declared for it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();

    var source = MemoryStorage.init(allocator);
    try fillDatabase(allocator, io, source.asStorage(), &.{fileName});

    var targetStore = MemoryStorage.init(allocator);
    var target: SpyStorage = .{ .allocator = allocator, .inner = targetStore.asStorage() };
    try fillDatabase(allocator, io, target.storage(), &.{});

    try pushFiles(allocator, io, source.asStorage(), target.storage(), try sync_helpers.makeBsonDatabase(allocator, target.storage()), throughTheDatabases(source.asStorage(), target.storage()));

    try std.testing.expectEqual(@as(?u64, fileName.len), target.declaredLengths.get(fileName).?);
}

test "the target's tree records the same length as the source's, so the file is not copied again" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();

    var sourceStore = MemoryStorage.init(allocator);
    var source: SpyStorage = .{ .allocator = allocator, .inner = sourceStore.asStorage(), .infoLengthOverhead = ENCRYPTION_OVERHEAD, .readableLengthUnknown = true };
    try fillDatabase(allocator, io, source.storage(), &.{fileName});

    var target = MemoryStorage.init(allocator);
    try fillDatabase(allocator, io, target.asStorage(), &.{});

    try pushFiles(allocator, io, source.storage(), target.asStorage(), try sync_helpers.makeBsonDatabase(allocator, target.asStorage()), throughTheDatabases(source.storage(), target.asStorage()));

    const sourceTree = (try merkle_tree.loadTree(allocator, io, ".db/files.dat", source.storage(), "FTRE")).?;
    const targetTree = (try merkle_tree.loadTree(allocator, io, ".db/files.dat", target.asStorage(), "FTRE")).?;
    try std.testing.expectEqual((try merkle_tree.getItemInfo(&sourceTree, fileName)).?.length, (try merkle_tree.getItemInfo(&targetTree, fileName)).?.length);
}
