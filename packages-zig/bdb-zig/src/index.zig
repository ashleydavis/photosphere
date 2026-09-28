pub const database = @import("lib/database.zig");
pub const shard = @import("lib/shard.zig");
pub const collection = @import("lib/collection.zig");
pub const sort_index = @import("lib/sort-index.zig");
pub const merge_records = @import("lib/merge-records.zig");
pub const merkle_tree = @import("lib/merkle-tree.zig");
pub const merkle_tree_ref = @import("lib/merkle-tree-ref.zig");
// Not ported: tests/mock-database, tests/mock-collection (TypeScript test helpers).

//
// Not exported by the TypeScript index (collection.ts imports them); exported here so the tests can reach them.
//
pub const update_fields = @import("lib/update-fields.zig");
pub const update_metadata = @import("lib/update-metadata.zig");

//
// Files with no TypeScript counterpart (replacements for the npm json-stable-stringify package, ICU localeCompare and
// JavaScript value semantics).
//
pub const json_stable_stringify = @import("lib/json-stable-stringify.zig");
pub const locale_compare = @import("lib/locale-compare.zig");
pub const js_value = @import("lib/js-value.zig");
