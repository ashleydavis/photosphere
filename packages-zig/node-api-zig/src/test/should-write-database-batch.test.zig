const std = @import("std");
const node_api = @import("node-api-zig");
const import_assets_worker = node_api.import_assets_worker;
const DATABASE_BATCH_SIZE = import_assets_worker.DATABASE_BATCH_SIZE;
const shouldWriteDatabaseBatch = import_assets_worker.shouldWriteDatabaseBatch;

//
// Covers when the import writes what it is holding into the database. Every write pays for a full
// database commit whatever its size, so writing too eagerly is what makes a long import crawl.
//

test "nothing waiting is nothing to write" {
    try std.testing.expectEqual(false, shouldWriteDatabaseBatch(0, true, false));
}

test "a full batch is written" {
    try std.testing.expectEqual(true, shouldWriteDatabaseBatch(DATABASE_BATCH_SIZE, false, true));
}

test "more than a full batch is written" {
    try std.testing.expectEqual(true, shouldWriteDatabaseBatch(DATABASE_BATCH_SIZE + 1, false, true));
}

test "a part-filled batch waits while the scanner still has photos to hand over" {
    try std.testing.expectEqual(false, shouldWriteDatabaseBatch(1, false, false));
}

test "a part-filled batch waits while photos already handed over are still being worked on" {
    // This is the backfill: the scanner reaches the end of the library long before the import
    // finishes with the photos it pushed. Writing here gives each of those a commit of its own.
    try std.testing.expectEqual(false, shouldWriteDatabaseBatch(1, true, true));
}

test "a part-filled batch is written once the scanner is caught up and nothing is in flight" {
    // An automatic import that took in a few photos and went quiet: those few have to be written
    // rather than held for a batch that may be hours away.
    try std.testing.expectEqual(true, shouldWriteDatabaseBatch(1, true, false));
}
