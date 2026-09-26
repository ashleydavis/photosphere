const std = @import("std");
const merkle_tree = @import("merkle-tree.zig");
const IMerkleTree = merkle_tree.IMerkleTree;
const SortNode = merkle_tree.SortNode;
const iterateLeaves = merkle_tree.iterateLeaves;

//
// The result of a comparison between two Merkle trees.
//
pub const ICompareResult = struct {
    // Names only in the first tree.
    onlyInA: []const []const u8,

    // Names only in the second tree.
    onlyInB: []const []const u8,

    // Names in both trees under different hashes.
    modified: []const []const u8,
};

//
// The optional progress callback of compareTrees (TypeScript: `(progress: string) => void`).
// (Zig: a closure; `function` is called with `context`.)
//
pub const CompareProgressCallback = struct {
    // The state of the callback, passed to function.
    context: ?*anyopaque,

    // The callback function.
    function: *const fn (context: ?*anyopaque, progress: []const u8) void,

    //
    // Invokes the callback.
    //
    pub fn call(self: CompareProgressCallback, progress: []const u8) void {
        self.function(self.context, progress);
    }
};

//
// Compares two merkle trees by name and says which names differ between them.
//
// By name, and not by the merkle diff. The merkle diff matches leaves by hash, counting how many
// times each hash appears, so two files with the same content under different names are the same
// file to it and which of them it calls "already there" is the order it visits them in. Every library
// holds such files: a photo imported twice sits under two ids with one content. Measured on a phone
// against an origin holding 15,491 files, 243 files the origin did not have were reported as present
// and 141 that it did have were reported as missing, and the sync that copied by the same diff left
// the 243 behind for good.
//
// Walking every leaf of both trees costs a map of one side's names: trees that are already in memory
// and a few hundred thousand names at the most, which is milliseconds. Trees whose roots hash the same
// are identical and are not walked at all.
//
pub fn compareTrees(allocator: std.mem.Allocator, treeA: *const IMerkleTree, treeB: *const IMerkleTree, progressCallback: ?CompareProgressCallback) !ICompareResult {
    if (progressCallback) |callback| {
        callback.call("Comparing merkle trees...");
    }

    var onlyInA: std.ArrayList([]const u8) = .empty;
    var onlyInB: std.ArrayList([]const u8) = .empty;
    var modified: std.ArrayList([]const u8) = .empty;

    if (treeA.merkle != null and treeB.merkle != null and std.mem.eql(u8, treeA.merkle.?.hash, treeB.merkle.?.hash)) {
        return .{
            .onlyInA = onlyInA.items,
            .onlyInB = onlyInB.items,
            .modified = modified.items,
        };
    }

    // (Zig: an array hash map keeps insertion order, like a JavaScript Map.)
    var hashesInB: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var leavesOfB = iterateLeaves(SortNode, allocator, treeB.sort);
    while (try leavesOfB.next()) |leaf| {
        if (leaf.name != null and leaf.contentHash != null) {
            try hashesInB.put(allocator, leaf.name.?, leaf.contentHash.?);
        }
    }

    var namesInA: std.StringHashMapUnmanaged(void) = .empty;
    var leavesOfA = iterateLeaves(SortNode, allocator, treeA.sort);
    while (try leavesOfA.next()) |leaf| {
        if (leaf.name == null or leaf.contentHash == null) {
            continue;
        }
        try namesInA.put(allocator, leaf.name.?, {});
        const hashInB = hashesInB.get(leaf.name.?);
        if (hashInB == null) {
            try onlyInA.append(allocator, leaf.name.?);
        }
        else if (!std.mem.eql(u8, hashInB.?, leaf.contentHash.?)) {
            try modified.append(allocator, leaf.name.?);
        }
    }

    for (hashesInB.keys()) |name| {
        if (!namesInA.contains(name)) {
            try onlyInB.append(allocator, name);
        }
    }

    return .{
        .onlyInA = onlyInA.items,
        .onlyInB = onlyInB.items,
        .modified = modified.items,
    };
}
