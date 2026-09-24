const std = @import("std");
const bdb = @import("bdb-zig");

test "compile everything" {
    std.testing.refAllDecls(bdb.database);
    std.testing.refAllDecls(bdb.database.BsonDatabase);
    std.testing.refAllDecls(bdb.collection);
    std.testing.refAllDecls(bdb.collection.BsonCollection);
    std.testing.refAllDecls(bdb.shard);
    std.testing.refAllDecls(bdb.shard.BsonShard);
    std.testing.refAllDecls(bdb.sort_index);
    std.testing.refAllDecls(bdb.sort_index.SortIndex);
    std.testing.refAllDecls(bdb.merkle_tree);
    std.testing.refAllDecls(bdb.merkle_tree_ref.MerkleRef);
    std.testing.refAllDecls(bdb.json_stable_stringify);
    std.testing.refAllDecls(bdb.locale_compare);
    std.testing.refAllDecls(bdb.js_value);
}
