const std = @import("std");
const node_api = @import("node-api-zig");

test "every file of the package compiles" {
    std.testing.refAllDecls(node_api.media_file_database);
    std.testing.refAllDecls(node_api.file_scanner);
    std.testing.refAllDecls(node_api.verify);
    std.testing.refAllDecls(node_api.verify_worker);
    std.testing.refAllDecls(node_api.task_handlers);
    std.testing.refAllDecls(node_api.replicate);
    std.testing.refAllDecls(node_api.replicate.LeafNameIterator);
    std.testing.refAllDecls(node_api.replicate.ShardDifferenceIterator);
    std.testing.refAllDecls(node_api.replicate.CollectionDifferenceIterator);
    std.testing.refAllDecls(node_api.replicate.DatabaseDifferenceIterator);
    std.testing.refAllDecls(node_api.replicate_database);
    std.testing.refAllDecls(node_api.replicate_database_worker);
    std.testing.refAllDecls(node_api.tree);
    std.testing.refAllDecls(node_api.hash);
    std.testing.refAllDecls(node_api.resolve_storage_credentials);
    std.testing.refAllDecls(node_api.open_storage);
    std.testing.refAllDecls(node_api.databases_config);
    std.testing.refAllDecls(node_api.retry_operations);
}
