//
// Port of apps/cli/src/lib/find-orphans.ts.
//

const std = @import("std");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const log = &utils.log.log;
const IStorage = storage_zig.storage.IStorage;
const IgnorePattern = storage_zig.walk_directory.IgnorePattern;
const walkDirectory = storage_zig.walk_directory.walkDirectory;
const IMerkleTree = merkle_tree_zig.merkle_tree.IMerkleTree;
const SortNode = merkle_tree_zig.merkle_tree.SortNode;
const traverseTreeAsync = merkle_tree_zig.traverse.traverseTreeAsync;

//
// Removes the optional leading slash of a path (TypeScript: the `^\/?` of the ignore patterns).
//
fn withoutLeadingSlash(fullPath: []const u8) []const u8 {
    if (std.mem.startsWith(u8, fullPath, "/")) {
        return fullPath[1..];
    }
    return fullPath;
}

//
// Matches /^\/?\.db/ (the metadata storage).
//
fn matchesDb(fullPath: []const u8) bool {
    return std.mem.startsWith(u8, withoutLeadingSlash(fullPath), ".db");
}

//
// Matches /^\/?metadata/ (the BSON database storage).
//
fn matchesMetadata(fullPath: []const u8) bool {
    return std.mem.startsWith(u8, withoutLeadingSlash(fullPath), "metadata");
}

//
// Matches /\.DS_Store/.
//
fn matchesDsStore(fullPath: []const u8) bool {
    return std.mem.indexOf(u8, fullPath, ".DS_Store") != null;
}

//
// The file names of the merkle tree, collected as the tree is traversed.
//
const IMerkleFileNames = struct {
    // Allocates the set.
    allocator: std.mem.Allocator,

    // The names of the leaves of the tree.
    names: std.StringHashMapUnmanaged(void),
};

//
// Adds the name of a node to the set (TypeScript: the callback given to traverseTreeAsync).
//
fn addNodeName(merkleFileNames: *IMerkleFileNames, node: *SortNode) anyerror!bool {
    if (node.name) |name| {
        try merkleFileNames.names.put(merkleFileNames.allocator, name, {});
    }
    return true;
}

//
// Finds files that exist in storage but are no longer in the merkle tree.
// Returns an array of orphaned file paths.
//
pub fn findOrphans(allocator: std.mem.Allocator, io: std.Io, assetStorage: IStorage, merkleTree: *const IMerkleTree) ![]const []const u8 {
    var orphans: std.ArrayList([]const u8) = .empty;

    // Collect all file names from the merkle tree
    var merkleFileNames: IMerkleFileNames = .{
        .allocator = allocator,
        .names = .empty,
    };

    if (merkleTree.sort) |sort| {
        try traverseTreeAsync(SortNode, sort, &merkleFileNames, addNodeName);
    }

    log.verbose(try std.fmt.allocPrint(allocator, "Found {d} files in merkle tree", .{merkleFileNames.names.count()}));

    // Walk through asset storage and find files not in merkle tree
    // Ignore .db directory (metadata storage) and metadata directory (BSON database storage)
    const ignorePatterns = [_]IgnorePattern{ matchesDb, matchesMetadata, matchesDsStore };

    var walker = try walkDirectory(allocator, io, assetStorage, "/", &ignorePatterns);
    while (try walker.next()) |file| {
        // Normalize path: remove leading slash to match merkle tree format
        const fileName = withoutLeadingSlash(file.fileName);

        // Skip if file is in merkle tree
        if (merkleFileNames.names.contains(fileName)) {
            continue;
        }

        // This is an orphan
        try orphans.append(allocator, fileName);
    }

    return orphans.items;
}
