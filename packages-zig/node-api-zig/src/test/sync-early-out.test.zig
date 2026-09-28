//
// Tests for the early-out of syncDatabases (port of src/test/lib/sync-early-out.test.ts).
//

const std = @import("std");
const utils = @import("utils-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const sync_helpers = @import("sync-test-helpers.zig");
const ThrowingStorage = sync_helpers.ThrowingStorage;
const syncDatabases = node_api.sync.syncDatabases;
const saveDatabaseState = api.database_state.saveDatabaseState;

test "returns synced:false without touching the databases when content hashes match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var sourceRaw = MemoryStorage.init(allocator);
    var targetRaw = MemoryStorage.init(allocator);
    const contentHash = [_]u8{7} ** 32;
    try saveDatabaseState(allocator, io, sourceRaw.asStorage(), .{ .contentHash = &contentHash });
    try saveDatabaseState(allocator, io, targetRaw.asStorage(), .{ .contentHash = &contentHash });

    // Stand-ins that throw if any of them is used: storages that throw on every call, and databases over them.
    var sourceAsset: ThrowingStorage = .{ .label = "sourceAsset" };
    var targetAsset: ThrowingStorage = .{ .label = "targetAsset" };
    var sourceBsonStorage: ThrowingStorage = .{ .label = "sourceBson" };
    var targetBsonStorage: ThrowingStorage = .{ .label = "targetBson" };
    const sourceBson = try sync_helpers.makeBsonDatabase(allocator, sourceBsonStorage.storage());
    const targetBson = try sync_helpers.makeBsonDatabase(allocator, targetBsonStorage.storage());

    const result = try syncDatabases(
        allocator,
        io,
        sourceAsset.storage(),
        sourceRaw.asStorage(),
        sourceBson,
        targetAsset.storage(),
        targetRaw.asStorage(),
        targetBson,
        "session-1",
        null,
    );

    try std.testing.expectEqual(false, result.synced);
}

test "proceeds past the early-out when content hashes differ" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var sourceRaw = MemoryStorage.init(allocator);
    var targetRaw = MemoryStorage.init(allocator);
    try saveDatabaseState(allocator, io, sourceRaw.asStorage(), .{ .contentHash = &([_]u8{1} ** 32) });
    try saveDatabaseState(allocator, io, targetRaw.asStorage(), .{ .contentHash = &([_]u8{2} ** 32) });

    var sourceAsset: ThrowingStorage = .{ .label = "sourceAsset" };
    var targetAsset: ThrowingStorage = .{ .label = "targetAsset" };
    var sourceBsonStorage: ThrowingStorage = .{ .label = "sourceBson" };
    var targetBsonStorage: ThrowingStorage = .{ .label = "targetBson" };
    const sourceBson = try sync_helpers.makeBsonDatabase(allocator, sourceBsonStorage.storage());
    const targetBson = try sync_helpers.makeBsonDatabase(allocator, targetBsonStorage.storage());

    // The first thing syncDatabases does after the early-out is flush the source bson database.
    // (Zig: a database with uncommitted changes refuses to flush, which stands in for the TypeScript's sentinel.)
    sourceBson.dirty = true;

    try std.testing.expectError(error.Thrown, syncDatabases(
        allocator,
        io,
        sourceAsset.storage(),
        sourceRaw.asStorage(),
        sourceBson,
        targetAsset.storage(),
        targetRaw.asStorage(),
        targetBson,
        "session-1",
        null,
    ));
    try std.testing.expectEqualStrings("Cannot flush: database has uncommitted changes. Call commit() first.", utils.errors.lastErrorMessage());
}

test "proceeds past the early-out when a content hash is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var sourceRaw = MemoryStorage.init(allocator);
    var targetRaw = MemoryStorage.init(allocator);
    try saveDatabaseState(allocator, io, sourceRaw.asStorage(), .{ .contentHash = &([_]u8{1} ** 32) });
    // The target has no state file, so there is no content hash to compare.

    var sourceAsset: ThrowingStorage = .{ .label = "sourceAsset" };
    var targetAsset: ThrowingStorage = .{ .label = "targetAsset" };
    var sourceBsonStorage: ThrowingStorage = .{ .label = "sourceBson" };
    var targetBsonStorage: ThrowingStorage = .{ .label = "targetBson" };
    const sourceBson = try sync_helpers.makeBsonDatabase(allocator, sourceBsonStorage.storage());
    const targetBson = try sync_helpers.makeBsonDatabase(allocator, targetBsonStorage.storage());
    sourceBson.dirty = true;

    try std.testing.expectError(error.Thrown, syncDatabases(
        allocator,
        io,
        sourceAsset.storage(),
        sourceRaw.asStorage(),
        sourceBson,
        targetAsset.storage(),
        targetRaw.asStorage(),
        targetBson,
        "session-1",
        null,
    ));
    try std.testing.expectEqualStrings("Cannot flush: database has uncommitted changes. Call commit() first.", utils.errors.lastErrorMessage());
}
