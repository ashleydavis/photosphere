const std = @import("std");
const merkle_tree_zig = @import("merkle-tree-zig");
const merkle_tree = merkle_tree_zig.merkle_tree;
const IMerkleTree = merkle_tree.IMerkleTree;
const HashedItem = merkle_tree.HashedItem;

//
// Lazily-loaded, committable handle for a merkle tree.
// Works at shard, collection, and database level via injected callbacks.
// (Zig: IMerkleRef has a single implementation, so callers use *MerkleRef directly.)
//
pub const IMerkleRef = MerkleRef;

//
// Loads (and, if needed, builds) the tree. Returns null when there is no tree.
//
pub const Loader = *const fn (context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!?IMerkleTree;

//
// Saves the tree to storage.
//
pub const Saver = *const fn (context: *anyopaque, allocator: std.mem.Allocator, io: std.Io, tree: *IMerkleTree) anyerror!void;

//
// Deletes the tree from storage.
//
pub const Deleter = *const fn (context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!void;

//
// Creates a new empty tree when upsert() is called and the tree is undefined.
//
pub const Creator = *const fn (context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!IMerkleTree;

//
// Concrete lazily-loaded merkle ref.
// The caller supplies load/save/delete callbacks appropriate for the level
// (shard, collection, or database). An optional creator callback is needed
// when upsert() may be called on a level whose tree starts empty (e.g. database).
// (Zig: the TypeScript arrow functions become function pointers that receive `context`, the object that owns the
// ref. The ref keeps the allocator it was created with; tree nodes are allocated with it.)
//
pub const MerkleRef = struct {
    //
    // Allocates the tree nodes (must live as long as the ref).
    //
    allocator: std.mem.Allocator,

    //
    // Cached tree; null when empty or not yet loaded.
    //
    _tree: ?IMerkleTree = null,

    //
    // True once get() has completed at least once.
    //
    _loaded: bool = false,

    //
    // True when the in-memory tree differs from what is on disk.
    //
    _dirty: bool = false,

    //
    // The object the callbacks act on (the shard, collection or database).
    //
    context: *anyopaque,

    //
    // Loads (and, if needed, builds) the tree. Returns undefined when there is no tree.
    //
    loader: Loader,

    //
    // Saves the tree to storage.
    //
    saver: Saver,

    //
    // Deletes the tree from storage.
    //
    deleter: Deleter,

    //
    // Creates a new empty tree when upsert() is called and the tree is undefined.
    // Required when the tree may not exist yet (e.g. first collection in a database).
    //
    creator: Creator,

    //
    // Creates a ref (TypeScript: the constructor).
    //
    pub fn init(allocator: std.mem.Allocator, context: *anyopaque, loader: Loader, saver: Saver, deleter: Deleter, creator: Creator) MerkleRef {
        return .{
            .allocator = allocator,
            .context = context,
            .loader = loader,
            .saver = saver,
            .deleter = deleter,
            .creator = creator,
        };
    }

    //
    // Returns the tree, invoking the loader on first access.
    //
    pub fn get(self: *MerkleRef, io: std.Io) !?*IMerkleTree {
        if (!self._loaded) {
            self._tree = try self.loader(self.context, self.allocator, io);
            self._loaded = true;
        }

        if (self._tree) |*tree| {
            if (tree.dirty) {
                tree.merkle = try merkle_tree.buildMerkleTree(self.allocator, tree.sort);
                tree.dirty = false;
            }
            return tree;
        }

        return null;
    }

    //
    // Inserts or updates a hashed item in the tree.
    // If the tree is undefined and a creator was supplied, creates a new tree first.
    //
    pub fn upsert(self: *MerkleRef, io: std.Io, item: HashedItem) !void {
        var tree: IMerkleTree = undefined;
        if (try self.get(io)) |existing| {
            tree = existing.*;
        }
        else {
            tree = try self.creator(self.context, self.allocator, io);
        }

        self._tree = try merkle_tree.upsertItem(self.allocator, &tree, item);
        self._dirty = true;
    }

    //
    // Removes an item by name. Sets the tree to undefined if it becomes empty.
    //
    pub fn remove(self: *MerkleRef, io: std.Io, name: []const u8) !void {
        const tree = try self.get(io) orelse {
            return;
        };
        if (tree.sort == null) {
            return;
        }

        try merkle_tree.deleteItem(self.allocator, tree, name);

        if (tree.sort == null) {
            self._tree = null;
        }

        self._dirty = true;
    }

    //
    // Writes the tree to storage (or deletes it if empty); clears the dirty flag.
    //
    pub fn commit(self: *MerkleRef, io: std.Io) !void {
        if (!self._dirty) {
            return;
        }

        if (self._tree) |*tree| {
            try self.saver(self.context, self.allocator, io, tree);
        }
        else {
            try self.deleter(self.context, self.allocator, io);
        }

        self._dirty = false;
    }

    // Not ported: flush (psi replicate and psi verify never flush a database).
};
