const std = @import("std");
const serialization_zig = @import("serialization-zig");
const bdb = @import("bdb-zig");
const BsonValue = serialization_zig.bson.BsonValue;

//
// Returns the record ids of a sort index in page order (a stand in for walking getPage, which is not ported), reading
// the leaves from the leaf cache or from storage.
//
pub fn walkSortIndex(allocator: std.mem.Allocator, io: std.Io, sortIndex: *bdb.sort_index.SortIndex) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    var currentId = sortIndex.rootPageId orelse {
        return ids.items;
    };
    var node = sortIndex.treeNodes.get(currentId).?;
    while (node.children.items.len > 0) {
        currentId = node.children.items[0];
        node = sortIndex.treeNodes.get(currentId).?;
    }
    while (true) {
        if (sortIndex.leafCache.get(currentId)) |cached| {
            for (cached.records.items) |entry| {
                try ids.append(allocator, entry._id);
            }
        }
        else {
            // Leaf pages are loaded through findByValue, which caches every leaf it reads.
            _ = try sortIndex.findByValue(io, .{ .string = "\x00never-matches" }, null);
            if (sortIndex.leafCache.get(currentId)) |loaded| {
                for (loaded.records.items) |entry| {
                    try ids.append(allocator, entry._id);
                }
            }
        }
        const nextLeaf = node.nextLeaf orelse {
            break;
        };
        currentId = nextLeaf;
        node = sortIndex.treeNodes.get(currentId).?;
    }
    return ids.items;
}

//
// Returns the values of a sort index in page order.
//
pub fn sortIndexValues(allocator: std.mem.Allocator, io: std.Io, sortIndex: *bdb.sort_index.SortIndex) ![]const BsonValue {
    _ = try walkSortIndex(allocator, io, sortIndex);
    var values: std.ArrayList(BsonValue) = .empty;
    var currentId = sortIndex.rootPageId orelse {
        return values.items;
    };
    var node = sortIndex.treeNodes.get(currentId).?;
    while (node.children.items.len > 0) {
        currentId = node.children.items[0];
        node = sortIndex.treeNodes.get(currentId).?;
    }
    while (true) {
        if (sortIndex.leafCache.get(currentId)) |cached| {
            for (cached.records.items) |entry| {
                try values.append(allocator, entry.value);
            }
        }
        const nextLeaf = node.nextLeaf orelse {
            break;
        };
        currentId = nextLeaf;
        node = sortIndex.treeNodes.get(currentId).?;
    }
    return values.items;
}
