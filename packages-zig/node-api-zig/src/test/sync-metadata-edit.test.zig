//
// Tests for a metadata edit reaching the origin through a sync (port of src/test/lib/sync-metadata-edit.test.ts).
//

const std = @import("std");
const storage_zig = @import("storage-zig");
const serialization_zig = @import("serialization-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const helpers = @import("test-helpers.zig");
const sync_helpers = @import("sync-test-helpers.zig");
const tree = node_api.tree;
const media_file_database = node_api.media_file_database;
const createStorage = storage_zig.storage_factory.createStorage;
const BsonDocument = serialization_zig.bson.BsonDocument;
const SettableTimestampProvider = sync_helpers.SettableTimestampProvider;
const syncDatabases = node_api.sync.syncDatabases;
const replicate = node_api.replicate.replicate;

//
// The asset whose description is edited.
//
const assetId = "11111111-2222-3333-4444-555555555555";

//
// Builds a database at the given directory holding one metadata record, and returns its path.
// `originDescription` is the description the record is created with. Passing null leaves the
// field off the record entirely; passing "" is what the real add path does, because
// upload-asset.worker.ts writes `description: description || ""` on every asset it imports. The
// two are not interchangeable in a merge: an absent field loses to any present one outright,
// while an empty string is a value that competes on its timestamp like any other.
//
fn makeOriginDatabase(allocator: std.mem.Allocator, io: std.Io, workingDir: []const u8, clock: *SettableTimestampProvider, originDescription: ?[]const u8) ![]const u8 {
    const originPath = try std.fmt.allocPrint(allocator, "{s}/origin", .{workingDir});
    try std.Io.Dir.cwd().createDirPath(io, originPath);

    const uuidGenerator = try sync_helpers.testUuidGenerator(allocator);
    const created = try createStorage(allocator, io, originPath, null, null);
    const database = try media_file_database.createMediaFileDatabase(allocator, created.storage, uuidGenerator, clock.timestampProvider());
    try media_file_database.createDatabase(allocator, io, created.storage, created.rawStorage, uuidGenerator, database.metadataCollection, null);

    var originRecord = try BsonDocument.fromFields(allocator, &.{
        .{
            .key = "_id",
            .value = .{ .string = assetId },
        },
        .{
            .key = "origFileName",
            .value = .{ .string = "test.jpg" },
        },
        .{
            .key = "contentType",
            .value = .{ .string = "image/jpeg" },
        },
    });
    if (originDescription) |description| {
        try originRecord.put(allocator, "description", .{ .string = description });
    }

    try database.metadataCollection.insertOne(io, &originRecord, null);
    try database.bsonDatabase.commit(io);
    try database.bsonDatabase.flush();

    return originPath;
}

//
// Applies a "set" op to a record of the metadata collection of the database at a path.
// (Zig: applyDatabaseOps is not ported; this is what it does for a "set" op on the metadata collection.)
//
fn applySetOp(allocator: std.mem.Allocator, io: std.Io, clock: *SettableTimestampProvider, databasePath: []const u8, recordId: []const u8, fields: BsonDocument) !void {
    const created = try createStorage(allocator, io, databasePath, null, null);
    const assetStorage = try media_file_database.openLazyOriginStorage(allocator, io, created.storage, created.rawStorage);
    const database = try media_file_database.createMediaFileDatabase(allocator, assetStorage, try sync_helpers.testUuidGenerator(allocator), clock.timestampProvider());
    try media_file_database.loadSortIndexes(allocator, assetStorage, database.metadataCollection);

    if (!try api.write_lock.acquireWriteLock(allocator, io, created.rawStorage, "session-edit", 3)) {
        return error.FailedToAcquireWriteLock;
    }
    _ = try database.metadataCollection.updateOne(io, recordId, fields, .{ .upsert = true });
    try database.bsonDatabase.commit(io);
    try tree.stampDatabaseModified(allocator, io, assetStorage, created.rawStorage);
    try api.write_lock.releaseWriteLock(allocator, io, created.rawStorage);
}

//
// Runs the whole journey and returns what the origin ends up holding as the description:
// build an origin, replicate it, edit the replica as applyDatabaseOps does, sync back up, then
// reopen the origin from disk. `editClockOffsetMs` shifts the clock the edit is stamped with, so
// a device running behind the machine that wrote the origin can be expressed directly.
// `originDescription` is what the origin's record holds before the edit.
//
fn runEditAndSync(allocator: std.mem.Allocator, io: std.Io, workingDir: []const u8, partial: bool, editClockOffsetMs: i64, originDescription: ?[]const u8) !?[]const u8 {
    // The origin is written first, so its record carries the earlier timestamp.
    const clock = try allocator.create(SettableTimestampProvider);
    clock.* = .{ .current = 1767225600000 }; // 2026-01-01T00:00:00.000Z
    const originPath = try makeOriginDatabase(allocator, io, workingDir, clock, originDescription);

    // The replica, exactly as the app makes it: a replicate of the origin, which records the
    // origin path in the replica's own config.
    const replicaPath = try std.fmt.allocPrint(allocator, "{s}/replica", .{workingDir});
    const sourceForReplicate = try createStorage(allocator, io, originPath, null, null);
    const sourceDbForReplicate = try media_file_database.createMediaFileDatabase(allocator, sourceForReplicate.storage, try sync_helpers.testUuidGenerator(allocator), clock.timestampProvider());
    const destForReplicate = try createStorage(allocator, io, replicaPath, null, null);
    _ = try replicate(
        allocator,
        io,
        originPath,
        sourceForReplicate.storage,
        sourceDbForReplicate.bsonDatabase,
        try sync_helpers.testUuidGenerator(allocator),
        clock.timestampProvider(),
        destForReplicate.storage,
        destForReplicate.rawStorage,
        .{ .partial = partial },
        null,
    );

    // The edit happens after the origin was written, so on a last-write-wins merge it must win,
    // unless the caller has asked for a clock far enough behind to change that.
    clock.advance(60_000 + editClockOffsetMs);

    try applySetOp(allocator, io, clock, replicaPath, assetId, try BsonDocument.fromFields(allocator, &.{
        .{
            .key = "description",
            .value = .{ .string = "Edited on the replica" },
        },
    }));

    // Sync the replica up to its origin, the way syncDatabaseHandler does: source is the local
    // replica, target is the origin.
    const replicaStorage = try createStorage(allocator, io, replicaPath, null, null);
    const originStorage = try createStorage(allocator, io, originPath, null, null);
    const replicaDb = try media_file_database.createMediaFileDatabase(allocator, replicaStorage.storage, try sync_helpers.testUuidGenerator(allocator), clock.timestampProvider());
    const originDb = try media_file_database.createMediaFileDatabase(allocator, originStorage.storage, try sync_helpers.testUuidGenerator(allocator), clock.timestampProvider());

    const result = try syncDatabases(
        allocator,
        io,
        replicaStorage.storage,
        replicaStorage.rawStorage,
        replicaDb.bsonDatabase,
        originStorage.storage,
        originStorage.rawStorage,
        originDb.bsonDatabase,
        "session-sync",
        null,
    );

    try std.testing.expectEqual(true, result.synced);

    // Read the origin back from disk with a database of its own, so this cannot pass on anything
    // the sync left cached in memory.
    try originDb.bsonDatabase.flush();
    try replicaDb.bsonDatabase.flush();

    const verifyStorage = try createStorage(allocator, io, originPath, null, null);
    const verifyDb = try media_file_database.createMediaFileDatabase(allocator, verifyStorage.storage, try sync_helpers.testUuidGenerator(allocator), clock.timestampProvider());
    const originRecord = try verifyDb.metadataCollection.getOne(io, assetId);
    try verifyDb.bsonDatabase.flush();

    const record = originRecord orelse {
        return null;
    };
    const description = record.get("description") orelse {
        return null;
    };
    return description.string;
}

//
// Runs the journey in a fresh working directory and checks the edit reached the origin.
//
fn expectEditReachesTheOrigin(partial: bool, editClockOffsetMs: i64, originDescription: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try helpers.setupEnvironment(io);
    var capture: sync_helpers.Capture = undefined;
    capture.start(allocator);
    defer capture.stop();
    const workingDir = try helpers.makeTempDir(allocator, io, "psphere-sync-edit");
    defer helpers.removeTempDir(io, workingDir);

    const description = try runEditAndSync(allocator, io, workingDir, partial, editClockOffsetMs, originDescription);
    try std.testing.expectEqualStrings("Edited on the replica", description.?);
}

test "a description set on a full replica reaches the origin" {
    try expectEditReachesTheOrigin(false, 0, null);
}

test "a description set on a partial replica reaches the origin" {
    try expectEditReachesTheOrigin(true, 0, null);
}

test "a description set on a device whose clock is behind still reaches the origin" {
    // The emulator the mobile suite runs on was measured 30 seconds behind the host that wrote
    // the origin. The edit is made a minute after the origin, so even 30 seconds behind it is
    // still the later write and must win.
    try expectEditReachesTheOrigin(true, -30_000, null);
}

test "a description set on a device whose clock is far behind still reaches the origin" {
    // The failure this guards against is silent: last-write-wins compares timestamps taken from
    // two different machines' clocks, so a device far enough behind loses an edit it genuinely
    // made later, and the sync still reports that it pushed changes.
    try expectEditReachesTheOrigin(true, -600_000, null);
}

// The four cases above all leave the description off the origin record, and an absent field wins
// nothing and loses nothing: mergeValues returns the other side outright when one value is
// undefined, before it compares timestamps at all. That is why they passed while smoke test 45
// failed. Every asset the real import path writes carries `description: ""`
// (upload-asset.worker.ts), which is a value, not an absence, so it competes on its timestamp.
// These are the cases test 45 actually exercises.

test "a description set over an empty one reaches the origin" {
    try expectEditReachesTheOrigin(true, 0, "");
}

test "a description set over an empty one on a device whose clock is behind reaches the origin" {
    try expectEditReachesTheOrigin(true, -30_000, "");
}

test "a description set over an empty one on a device whose clock is far behind reaches the origin" {
    // This is smoke test 45's failure, reproduced on the host in a second. The device edits the
    // description a minute after the origin was written, but its clock is far enough behind that
    // the edit is stamped earlier than the origin's record, so the origin's empty string wins and
    // the edit is dropped. The sync still reports that it pushed changes, so nothing fails loudly.
    try expectEditReachesTheOrigin(true, -600_000, "");
}
