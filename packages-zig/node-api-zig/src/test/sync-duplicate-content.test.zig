//
// Tests for pushing a file whose content the target already holds under another name (port of
// src/test/lib/sync-duplicate-content.test.ts).
//
// A push decides what to copy by name, not by content.
//
// It used to decide with the merkle diff, and the merkle diff matches leaves by hash: a file whose
// content the target already held under another name was never offered for copying, so it never
// arrived. A library holds such files whenever a photo has been imported twice, which happens when an
// import stops before its batch is written and the next run imports the same photos again under new
// ids. Measured on a Pixel 6 against an origin holding 15,491 files, 243 files of 101 assets were
// missing at the origin after five passes that had each reported nothing left behind.
//
// The merkle diff counts each hash and matches the source's leaves against that count in the order
// it visits them, so which of two same-content leaves it calls "already there" is the visiting order,
// not the name: when the target holds the second, the first is matched away and the second is offered,
// and the second copies nothing because it is already there.
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const node_api = @import("node-api-zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const sync_helpers = @import("sync-test-helpers.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const pushFiles = node_api.sync.pushFiles;
const throughTheDatabases = node_api.sync.throughTheDatabases;

//
// The id of the test databases.
//
const dbId = "6f1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d";

test "the file arrives at the target under its own name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();

    const photo = "the same photo imported twice";
    var source = MemoryStorage.init(allocator);
    try sync_helpers.fillDatabase(allocator, io, source.asStorage(), dbId, &.{
        .{
            .name = "asset/first-import",
            .contents = photo,
        },
        .{
            .name = "asset/second-import",
            .contents = photo,
        },
    }, &.{});
    var target = MemoryStorage.init(allocator);
    try sync_helpers.fillDatabase(allocator, io, target.asStorage(), dbId, &.{
        .{
            .name = "asset/second-import",
            .contents = photo,
        },
    }, &.{});

    try pushFiles(allocator, io, source.asStorage(), target.asStorage(), try sync_helpers.makeBsonDatabase(allocator, target.asStorage()), throughTheDatabases(source.asStorage(), target.asStorage()));

    try std.testing.expect(try target.asStorage().fileExists(allocator, io, "asset/first-import"));
    const targetTree = (try merkle_tree.loadTree(allocator, io, ".db/files.dat", target.asStorage(), "FTRE")).?;
    try std.testing.expect((try merkle_tree.getItemInfo(&targetTree, "asset/first-import")) != null);
}
