const std = @import("std");
const bdb = @import("bdb-zig");
const utils = @import("utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const IMerkleTree = merkle_tree.IMerkleTree;
const HashedItem = merkle_tree.HashedItem;
const MerkleRef = bdb.merkle_tree_ref.MerkleRef;

const io = std.testing.io;

//
// Creates a simple HashedItem for testing.
//
fn makeItem(name: []const u8) HashedItem {
    return .{
        .name = name,
        .hash = name,
        .length = name.len,
        .lastModified = 1704067200000,
    };
}

//
// Generates ids for the trees the tests create.
//
var uuid_generator: utils.test_uuid_generator.TestUuidGenerator = .{};

//
// Creates a new empty tree for use as a stub.
//
fn makeTree(allocator: std.mem.Allocator) !IMerkleTree {
    return merkle_tree.createTree(try uuid_generator.generate(allocator));
}

//
// In-memory state behind a MerkleRef (TypeScript: the variables captured by makeRef's arrow functions).
//
const RefState = struct {
    // The stored tree (null when there is none).
    stored: ?IMerkleTree,

    // Number of saver calls.
    saveCount: u32 = 0,

    // Number of deleter calls.
    deleteCount: u32 = 0,

    // Number of loader calls.
    loadCount: u32 = 0,

    //
    // Returns the stored tree.
    //
    fn loader(context: *anyopaque, allocator: std.mem.Allocator, ioValue: std.Io) anyerror!?IMerkleTree {
        _ = allocator;
        _ = ioValue;
        const self: *RefState = @ptrCast(@alignCast(context));
        self.loadCount += 1;
        return self.stored;
    }

    //
    // Stores the tree.
    //
    fn saver(context: *anyopaque, allocator: std.mem.Allocator, ioValue: std.Io, tree: *IMerkleTree) anyerror!void {
        _ = allocator;
        _ = ioValue;
        const self: *RefState = @ptrCast(@alignCast(context));
        self.stored = tree.*;
        self.saveCount += 1;
    }

    //
    // Deletes the stored tree.
    //
    fn deleter(context: *anyopaque, allocator: std.mem.Allocator, ioValue: std.Io) anyerror!void {
        _ = allocator;
        _ = ioValue;
        const self: *RefState = @ptrCast(@alignCast(context));
        self.stored = null;
        self.deleteCount += 1;
    }

    //
    // Creates a new empty tree.
    //
    fn creator(context: *anyopaque, allocator: std.mem.Allocator, ioValue: std.Io) anyerror!IMerkleTree {
        _ = context;
        _ = ioValue;
        return makeTree(allocator);
    }

    //
    // Builds a MerkleRef backed by this state (TypeScript: makeRef).
    //
    fn makeRef(self: *RefState, allocator: std.mem.Allocator) MerkleRef {
        return MerkleRef.init(allocator, self, loader, saver, deleter, creator);
    }
};

test "get returns undefined when loader returns undefined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: RefState = .{ .stored = null };
    var ref = state.makeRef(arena.allocator());
    try std.testing.expectEqual(@as(?*IMerkleTree, null), try ref.get(io));
}

test "get returns the tree when loader returns one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tree = try makeTree(arena.allocator());
    var state: RefState = .{ .stored = tree };
    var ref = state.makeRef(arena.allocator());
    const result = (try ref.get(io)).?;
    try std.testing.expectEqualStrings(tree.id, result.id);
}

test "get only calls loader once (caches result)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: RefState = .{ .stored = try makeTree(arena.allocator()) };
    var ref = state.makeRef(arena.allocator());
    _ = try ref.get(io);
    _ = try ref.get(io);
    try std.testing.expectEqual(@as(u32, 1), state.loadCount);
}

test "upsert creates a tree via creator when tree is undefined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: RefState = .{ .stored = null };
    var ref = state.makeRef(arena.allocator());
    try ref.upsert(io, makeItem("file1"));
    const tree = (try ref.get(io)).?;
    try std.testing.expect(tree.sort != null);
}

test "upsert inserts item into existing tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: RefState = .{ .stored = try makeTree(arena.allocator()) };
    var ref = state.makeRef(arena.allocator());
    try ref.upsert(io, makeItem("file1"));
    const tree = (try ref.get(io)).?;
    try std.testing.expectEqual(@as(u32, 1), tree.sort.?.leafCount);
}

test "upsert marks the ref as dirty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: RefState = .{ .stored = try makeTree(arena.allocator()) };
    var ref = state.makeRef(arena.allocator());
    try ref.upsert(io, makeItem("file1"));
    try ref.commit(io);
    try std.testing.expectEqual(@as(u32, 1), state.saveCount);
}

test "remove on empty tree is a no-op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: RefState = .{ .stored = null };
    var ref = state.makeRef(arena.allocator());
    try ref.remove(io, "file1");
    try std.testing.expectEqual(@as(?*IMerkleTree, null), try ref.get(io));
}

test "remove deletes an existing item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: RefState = .{ .stored = try makeTree(arena.allocator()) };
    var ref = state.makeRef(arena.allocator());
    try ref.upsert(io, makeItem("file1"));
    try ref.commit(io);

    // (Zig: flush is not ported; the removal works on the cached tree.)
    try ref.remove(io, "file1");
    // After removing the only item, _tree is set to undefined internally
    try std.testing.expectEqual(@as(?*IMerkleTree, null), try ref.get(io));
}

test "remove sets tree to undefined when it becomes empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: RefState = .{ .stored = try makeTree(arena.allocator()) };
    var ref = state.makeRef(arena.allocator());
    try ref.upsert(io, makeItem("file1"));
    try ref.commit(io);

    try ref.remove(io, "file1");
    try ref.commit(io);
    try std.testing.expectEqual(@as(?*IMerkleTree, null), try ref.get(io));
    try std.testing.expectEqual(@as(?IMerkleTree, null), state.stored);
}

test "commit saves the tree when dirty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: RefState = .{ .stored = try makeTree(arena.allocator()) };
    var ref = state.makeRef(arena.allocator());
    try ref.upsert(io, makeItem("file1"));
    try ref.commit(io);
    try std.testing.expectEqual(@as(u32, 1), state.saveCount);
}

test "commit calls deleter when tree is empty after remove" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: RefState = .{ .stored = try makeTree(arena.allocator()) };
    var ref = state.makeRef(arena.allocator());
    try ref.upsert(io, makeItem("file1"));
    try ref.commit(io);

    try ref.remove(io, "file1");
    try ref.commit(io);
    try std.testing.expectEqual(@as(u32, 1), state.deleteCount);
}

test "commit is a no-op when not dirty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: RefState = .{ .stored = try makeTree(arena.allocator()) };
    var ref = state.makeRef(arena.allocator());
    try ref.commit(io);
    try std.testing.expectEqual(@as(u32, 0), state.saveCount);
    try std.testing.expectEqual(@as(u32, 0), state.deleteCount);
}

test "commit clears the dirty flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: RefState = .{ .stored = try makeTree(arena.allocator()) };
    var ref = state.makeRef(arena.allocator());
    try ref.upsert(io, makeItem("file1"));
    try ref.commit(io);
    // second commit should be a no-op
    try ref.commit(io);
    try std.testing.expectEqual(@as(u32, 1), state.saveCount);
}

test "multiple upserts accumulate items in the tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: RefState = .{ .stored = try makeTree(arena.allocator()) };
    var ref = state.makeRef(arena.allocator());
    try ref.upsert(io, makeItem("file1"));
    try ref.upsert(io, makeItem("file2"));
    try ref.upsert(io, makeItem("file3"));
    const tree = (try ref.get(io)).?;
    try std.testing.expectEqual(@as(u32, 3), tree.sort.?.leafCount);
}

test "get rebuilds the merkle tree when the tree is dirty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: RefState = .{ .stored = try makeTree(arena.allocator()) };
    var ref = state.makeRef(arena.allocator());
    try ref.upsert(io, makeItem("file1"));
    const tree = (try ref.get(io)).?;
    try std.testing.expect(!tree.dirty);
    try std.testing.expect(tree.merkle != null);
}
