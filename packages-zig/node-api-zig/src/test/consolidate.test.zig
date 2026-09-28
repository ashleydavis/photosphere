const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const node_api = @import("node-api-zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const IMerkleTree = merkle_tree.IMerkleTree;
const planConsolidation = node_api.consolidate.planConsolidation;

//
// One file to put in a database's merkle tree.
//
const ITreeFile = struct {
    // The path in the database, such as "asset/one".
    name: []const u8,

    // The content hash, as hex.
    hash: []const u8,
};

//
// A merkle tree holding the given files.
//
fn treeOf(allocator: std.mem.Allocator, files: []const ITreeFile) !IMerkleTree {
    var tree = merkle_tree.createTree("test-tree");
    for (files) |file| {
        const hash = try allocator.alloc(u8, file.hash.len / 2);
        _ = try std.fmt.hexToBytes(hash, file.hash);
        tree = try merkle_tree.addItem(allocator, &tree, .{
            .name = file.name,
            .hash = hash,
            .length = 100,
            .lastModified = 1767225600000,
        });
    }
    return tree;
}

//
// An original with the given asset id and content hash.
//
fn original(comptime assetId: []const u8, hash: []const u8) ITreeFile {
    return .{
        .name = "asset/" ++ assetId,
        .hash = hash,
    };
}

//
// Sorts asset ids, like `.sort()` on the TypeScript array.
//
fn sorted(allocator: std.mem.Allocator, assetIds: []const []const u8) ![]const []const u8 {
    const copy = try allocator.dupe([]const u8, assetIds);
    std.mem.sort([]const u8, copy, {}, lessThan);
    return copy;
}

//
// Orders two strings for sorted.
//
fn lessThan(context: void, left: []const u8, right: []const u8) bool {
    _ = context;
    return std.mem.lessThan(u8, left, right);
}

//
// Checks a list of asset ids against the expected one.
//
fn expectIds(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expectedId, actualId| {
        try std.testing.expectEqualStrings(expectedId, actualId);
    }
}

test "everything is absent from an empty remote" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const local = try treeOf(allocator, &.{ original("one", "aaaa"), original("two", "bbbb") });
    const remote = try treeOf(allocator, &.{});

    const plan = try planConsolidation(allocator, &local, &remote);

    try expectIds(&.{ "one", "two" }, try sorted(allocator, plan.absentAssetIds));
    try expectIds(&.{}, plan.presentAssetIds);
}

test "content the remote already holds is not pushed, whatever id it has there" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The same photo, given a different asset id in each database. The id says nothing about
    // whether the remote has the content; the hash does.
    const local = try treeOf(allocator, &.{original("local-id", "aaaa")});
    const remote = try treeOf(allocator, &.{original("remote-id", "aaaa")});

    const plan = try planConsolidation(allocator, &local, &remote);

    try expectIds(&.{}, plan.absentAssetIds);
    try expectIds(&.{"local-id"}, plan.presentAssetIds);
}

test "separates what the remote has from what it does not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const local = try treeOf(allocator, &.{
        original("shared", "aaaa"),
        original("only-here", "bbbb"),
        original("also-only-here", "cccc"),
    });
    const remote = try treeOf(allocator, &.{ original("their-copy", "aaaa"), original("only-there", "dddd") });

    const plan = try planConsolidation(allocator, &local, &remote);

    try expectIds(&.{ "also-only-here", "only-here" }, try sorted(allocator, plan.absentAssetIds));
    try expectIds(&.{"shared"}, plan.presentAssetIds);
}

test "matches hashes regardless of letter case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const local = try treeOf(allocator, &.{original("one", "AABB")});
    const remote = try treeOf(allocator, &.{original("two", "aabb")});

    try expectIds(&.{"one"}, (try planConsolidation(allocator, &local, &remote)).presentAssetIds);
}

test "only originals are considered, not thumbnails or display copies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const local = try treeOf(allocator, &.{
        original("one", "aaaa"),
        .{
            .name = "thumb/one",
            .hash = "1111",
        },
        .{
            .name = "display/one",
            .hash = "2222",
        },
    });
    const remote = try treeOf(allocator, &.{});

    const plan = try planConsolidation(allocator, &local, &remote);

    try expectIds(&.{"one"}, plan.absentAssetIds);
    try expectIds(&.{}, plan.presentAssetIds);
}

test "a thumbnail on the remote with a matching hash does not count as the original" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const local = try treeOf(allocator, &.{original("one", "aaaa")});
    const remote = try treeOf(allocator, &.{.{
        .name = "thumb/other",
        .hash = "aaaa",
    }});

    try expectIds(&.{"one"}, (try planConsolidation(allocator, &local, &remote)).absentAssetIds);
}

test "an empty local database has nothing to push" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const local = try treeOf(allocator, &.{});
    const remote = try treeOf(allocator, &.{original("theirs", "aaaa")});

    const plan = try planConsolidation(allocator, &local, &remote);

    try expectIds(&.{}, plan.absentAssetIds);
    try expectIds(&.{}, plan.presentAssetIds);
}

test "a missing local tree has nothing to push" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const remote = try treeOf(allocator, &.{original("theirs", "aaaa")});

    const plan = try planConsolidation(allocator, null, &remote);

    try expectIds(&.{}, plan.absentAssetIds);
    try expectIds(&.{}, plan.presentAssetIds);
}

test "a missing remote tree means everything is absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const local = try treeOf(allocator, &.{original("one", "aaaa")});

    const plan = try planConsolidation(allocator, &local, null);

    try expectIds(&.{"one"}, plan.absentAssetIds);
}
