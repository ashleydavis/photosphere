//
// Tests of visualize.zig (the TypeScript visualize.ts has no tests of its own; the expected text was produced by
// the TypeScript visualizeTree for the same trees).
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const serialization_zig = @import("serialization-zig");
const merkle_verify = @import("merkle-verify.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const visualize = merkle_tree_zig.visualize;
const BsonDocument = serialization_zig.bson.BsonDocument;
const IMerkleTree = merkle_tree.IMerkleTree;

//
// Builds a tree of the items A, B and C, each hashed from its name, with a length of 1.
//
fn buildAbcTree(allocator: std.mem.Allocator) !IMerkleTree {
    var tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);
    for ([_][]const u8{ "A", "B", "C" }) |name| {
        tree = try merkle_tree.addItem(allocator, &tree, try merkle_verify.createSha256HashedItem(allocator, name, name, 1));
    }
    return tree;
}

test "visualizeTree shows the sort tree of a tree with no merkle tree or database metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = try buildAbcTree(allocator);

    try std.testing.expectEqualStrings(
        "Tree Metadata:\n  UUID: 12345678-1234-5678-9abc-123456789abc\n  Total Nodes: 5\n  Total Items: 3\n  Total Size: 3 bytes\n\nVersion: 6\n\n==================================================\nSort Tree:\n==================================================\n\n└── A (5)\n    ├── A (3)\n    │   ├── A (55fd)\n    │   └── B (df5c)\n    └── C (6b0d)\n",
        try visualize.visualizeTree(allocator, &tree),
    );
}

test "visualizeTree shows the database metadata, merkle tree, root hash and leaves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tree = try buildAbcTree(allocator);
    tree.merkle = try merkle_tree.buildMerkleTree(allocator, tree.sort);
    tree.dirty = false;
    tree.databaseMetadata = try BsonDocument.fromFields(allocator, &.{
        .{
            .key = "filesImported",
            .value = .{ .number = 3 },
        },
        .{
            .key = "note",
            .value = .{ .string = "x" },
        },
    });

    try std.testing.expectEqualStrings(
        "Tree Metadata:\n  UUID: 12345678-1234-5678-9abc-123456789abc\n  Total Nodes: 5\n  Total Items: 3\n  Total Size: 3 bytes\n\nDatabase Metadata:\n  filesImported: 3\n  note: x\n\nVersion: 6\n\n==================================================\nSort Tree:\n==================================================\n\n└── A (5)\n    ├── A (3)\n    │   ├── A (55fd)\n    │   └── B (df5c)\n    └── C (6b0d)\n\n==================================================\nMerkle Tree:\n==================================================\n\n└──  db27\n    ├──  6340\n    │   ├──  55fd A\n    │   └──  df5c B\n    └──  6b0d C\n\n==================================================\nRoot Hash: dbe11e36aa89a963103de7f8ad09c1100c06ccd5c5ad424ca741efb0689dc427\n==================================================\n\n==================================================\nLeaf Nodes:\n==================================================\nA (559aead08264d5795d3909718cdd05abd49572e84fe55590eef31a88a08fdffd)\nB (df7e70e5021544f4834bbee64a9e3789febc4be81470df629cad6ddb03320a5c)\nC (6b23c0d5f35d1b11f9b683f0b0a617355deb11277d91ae091d399c655b87940d)\n==================================================\n",
        try visualize.visualizeTree(allocator, &tree),
    );
}

test "visualizeTree of an empty tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tree = merkle_tree.createTree(merkle_verify.TEST_TREE_ID);

    try std.testing.expectEqualStrings("Empty tree", try visualize.visualizeTree(allocator, &tree));
    try std.testing.expectEqualStrings("Empty tree", try visualize.visualizeTree(allocator, null));
}

test "visualizeSortTree throws for a leaf without a content hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var leaf: merkle_tree.SortNode = .{
        .name = "A",
        .nodeCount = 1,
        .leafCount = 1,
        .size = 1,
        .minName = "A",
    };
    var output: std.Io.Writer.Allocating = .init(allocator);
    try std.testing.expectError(error.Thrown, visualize.visualizeSortTree(allocator, &output.writer, &leaf, "", true));
}
