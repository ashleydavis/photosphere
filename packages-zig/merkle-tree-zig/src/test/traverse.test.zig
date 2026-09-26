//
// Tests for traverseTreeAsync (port of src/test/traverse.test.ts; the traverseTreeSync tests are not ported
// because traverseTreeSync is not ported).
// (Zig: test names are prefixed with the describe name. The TypeScript async callbacks await timers;
// the Zig callbacks are blocking functions.)
//

const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_verify = @import("merkle-verify.zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const traverse = merkle_tree_zig.traverse;
const errors = @import("utils-zig").errors;
const SortNode = merkle_tree.SortNode;
const buildTree = merkle_verify.buildTree;
const leaf = merkle_verify.leaf;
const node = merkle_verify.node;

//
// Records the nodes a traversal visits and decides when to stop.
//
const Recorder = struct {
    // Allocates the recorded lists.
    allocator: std.mem.Allocator,

    // The minName of every visited node, in visit order.
    visited: std.ArrayList([]const u8) = .empty,

    // The names of the visited leaves.
    leafNames: std.ArrayList([]const u8) = .empty,

    // The nodeCount of every visited node.
    nodeCounts: std.ArrayList(u32) = .empty,

    // When true, returning false for the internal node with nodeCount 3 and minName 'A'.
    stopAtFirstInternal: bool = false,

    // When true, returning false for every leaf.
    stopAtLeaves: bool = false,

    // When set, returning false once this many nodes have been visited (TypeScript: `return count < limit`).
    limit: ?usize = null,

    // When set, failing with 'Stop here' when this many nodes have been visited.
    failAt: ?usize = null,

    //
    // Records a node and returns whether to continue into its children.
    //
    fn visit(self: *Recorder, current: *SortNode) !bool {
        try self.visited.append(self.allocator, current.minName);
        try self.nodeCounts.append(self.allocator, current.nodeCount);
        if (self.failAt) |failAt| {
            if (self.visited.items.len == failAt) {
                return errors.throwError("Stop here", .{});
            }
        }
        if (current.name) |name| {
            try self.leafNames.append(self.allocator, name);
            if (self.stopAtLeaves) {
                return false;
            }
        }
        if (self.stopAtFirstInternal and current.nodeCount == 3 and std.mem.eql(u8, current.minName, "A")) {
            return false;
        }
        if (self.limit) |limit| {
            return self.visited.items.len < limit;
        }
        return true;
    }

    //
    // The traverseTreeAsync callback.
    //
    fn asyncCallback(self: *Recorder, current: *SortNode) anyerror!bool {
        return self.visit(current);
    }
};

//
// Traverses a tree with the async traversal and a recorder.
//
fn traverseAsync(root: ?*SortNode, recorder: *Recorder) !void {
    try traverse.traverseTreeAsync(SortNode, root, recorder, Recorder.asyncCallback);
}

//
// Checks two lists of names are equal.
//
fn expectNames(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expectedName, actualName| {
        try std.testing.expectEqualStrings(expectedName, actualName);
    }
}

//
// Names like `file_000`.
//
fn paddedFileNames(allocator: std.mem.Allocator, count: usize) ![]const []const u8 {
    const names = try allocator.alloc([]const u8, count);
    for (names, 0..) |*name, index| {
        name.* = try std.fmt.allocPrint(allocator, "file_{d:0>3}", .{index});
    }
    return names;
}

//
// Builds the tree ((A, B), (C, D)) from leaves.
//
fn buildFourLeafTree(allocator: std.mem.Allocator) !*SortNode {
    return node(
        allocator,
        try node(allocator, try leaf(allocator, "A", 100), try leaf(allocator, "B", 100)),
        try node(allocator, try leaf(allocator, "C", 100), try leaf(allocator, "D", 100)),
    );
}

test "traverseTreeAsync: handles undefined node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder: Recorder = .{ .allocator = arena.allocator() };
    try traverseAsync(null, &recorder);
    try std.testing.expectEqual(@as(usize, 0), recorder.visited.items.len);
}

test "traverseTreeAsync: traverses single leaf node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var recorder: Recorder = .{ .allocator = allocator };
    try traverseAsync(try leaf(allocator, "A", 100), &recorder);
    try expectNames(&.{"A"}, recorder.visited.items);
}

test "traverseTreeAsync: traverses two leaf nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var recorder: Recorder = .{ .allocator = allocator };
    try traverseAsync(try node(allocator, try leaf(allocator, "A", 100), try leaf(allocator, "B", 100)), &recorder);
    try expectNames(&.{ "A", "A", "B" }, recorder.visited.items);
}

test "traverseTreeAsync: performs pre-order traversal (parent, left, right)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var recorder: Recorder = .{ .allocator = allocator };
    const sortTree = try node(allocator, try node(allocator, try leaf(allocator, "A", 100), try leaf(allocator, "B", 100)), try leaf(allocator, "C", 100));
    try traverseAsync(sortTree, &recorder);
    try expectNames(&.{ "A", "A", "A", "B", "C" }, recorder.visited.items);
}

test "traverseTreeAsync: visits all nodes in pre-order for balanced tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D" });
    var recorder: Recorder = .{ .allocator = allocator };
    try traverseAsync(tree.sort, &recorder);
    try std.testing.expectEqual(@as(usize, 7), recorder.visited.items.len);
}

test "traverseTreeAsync: waits for async callback to complete" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C" });
    var recorder: Recorder = .{ .allocator = allocator };
    try traverseAsync(tree.sort, &recorder);
    try std.testing.expectEqual(@as(usize, 5), recorder.visited.items.len);
}

test "traverseTreeAsync: processes nodes sequentially in pre-order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D" });
    var recorder: Recorder = .{ .allocator = allocator };
    try traverseAsync(tree.sort, &recorder);

    // Should be sequential: 0, 1, 2, 3, 4, 5, 6 (the root first)
    try std.testing.expectEqual(@as(usize, 7), recorder.visited.items.len);
    try std.testing.expectEqual(@as(u32, 7), recorder.nodeCounts.items[0]);
}

test "traverseTreeAsync: can perform async operations in callback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C" });
    var recorder: Recorder = .{ .allocator = allocator };
    try traverseAsync(tree.sort, &recorder);
    try std.testing.expectEqual(@as(usize, 5), recorder.visited.items.len);
}

test "traverseTreeAsync: stops node children when callback returns false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var recorder: Recorder = .{ .allocator = allocator, .stopAtFirstInternal = true };
    try traverseAsync(try buildFourLeafTree(allocator), &recorder);
    try std.testing.expect(merkle_verify.containsName(recorder.visited.items, "C"));
    try std.testing.expect(merkle_verify.containsName(recorder.visited.items, "D"));
    try std.testing.expect(recorder.visited.items.len < 7);
}

test "traverseTreeAsync: stops after async operation returns false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D" });
    var recorder: Recorder = .{ .allocator = allocator, .stopAtLeaves = true };
    try traverseAsync(tree.sort, &recorder);
    try expectNames(&.{ "A", "B", "C", "D" }, recorder.leafNames.items);
}

test "traverseTreeAsync: can conditionally terminate based on async check" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D" });
    var recorder: Recorder = .{ .allocator = allocator, .limit = 4 };
    try traverseAsync(tree.sort, &recorder);
    try std.testing.expect(recorder.visited.items.len > 0);
    try std.testing.expect(recorder.visited.items.len <= 7);
}

test "traverseTreeAsync: collects all leaf nodes asynchronously" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D" });
    var recorder: Recorder = .{ .allocator = allocator };
    try traverseAsync(tree.sort, &recorder);
    try expectNames(&.{ "A", "B", "C", "D" }, recorder.leafNames.items);
}

test "traverseTreeAsync: can perform async filtering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D", "E" });
    var recorder: Recorder = .{ .allocator = allocator };
    try traverseAsync(tree.sort, &recorder);
    var filtered: usize = 0;
    for (recorder.nodeCounts.items) |nodeCount| {
        if (nodeCount > 1) {
            filtered += 1;
        }
    }
    try std.testing.expect(filtered > 0);
}

//
// A traverseTreeAsync callback that always fails.
//
fn failingCallback(context: void, current: *SortNode) anyerror!bool {
    _ = context;
    _ = current;
    return errors.throwError("Callback error", .{});
}

test "traverseTreeAsync: propagates errors from async callback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tree = try buildTree(arena.allocator(), &.{ "A", "B", "C" });
    try std.testing.expectError(error.Thrown, traverse.traverseTreeAsync(SortNode, tree.sort, {}, failingCallback));
    try std.testing.expectEqualStrings("Callback error", errors.lastErrorMessage());
}

test "traverseTreeAsync: stops traversal on error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, &.{ "A", "B", "C", "D" });
    var recorder: Recorder = .{ .allocator = allocator, .failAt = 3 };
    try std.testing.expectError(error.Thrown, traverseAsync(tree.sort, &recorder));
    try std.testing.expectEqual(@as(usize, 3), recorder.visited.items.len);
}

test "traverseTreeAsync: traverses tree with 100 nodes asynchronously" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, try paddedFileNames(allocator, 100));
    var recorder: Recorder = .{ .allocator = allocator };
    try traverseAsync(tree.sort, &recorder);
    try std.testing.expect(recorder.visited.items.len >= 100);
}

test "traverseTreeAsync: can limit traversal in large tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tree = try buildTree(allocator, try paddedFileNames(allocator, 100));
    var recorder: Recorder = .{ .allocator = allocator, .limit = 50 };
    try traverseAsync(tree.sort, &recorder);
    try std.testing.expect(recorder.visited.items.len < 199);
    try std.testing.expect(recorder.visited.items.len > 0);
}

test "traverseTreeAsync: handles nodes with only left child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const leftLeaf = try leaf(allocator, "A", 100);
    var parent: SortNode = .{ .nodeCount = 2, .leafCount = 1, .size = leftLeaf.size, .minName = "A", .left = leftLeaf };
    var recorder: Recorder = .{ .allocator = allocator };
    try traverseAsync(&parent, &recorder);
    try expectNames(&.{ "A", "A" }, recorder.visited.items);
}

test "traverseTreeAsync: handles nodes with only right child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const rightLeaf = try leaf(allocator, "B", 100);
    var parent: SortNode = .{ .nodeCount = 2, .leafCount = 1, .size = rightLeaf.size, .minName = "B", .right = rightLeaf };
    var recorder: Recorder = .{ .allocator = allocator };
    try traverseAsync(&parent, &recorder);
    try expectNames(&.{ "B", "B" }, recorder.visited.items);
}
