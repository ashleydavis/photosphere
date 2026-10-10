const std = @import("std");
const utils = @import("utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const storage_zig = @import("storage-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const database_fixture = @import("database-fixture.zig");
const temp_dirs = @import("temp-dirs.zig");
const test_task_context = @import("test-task-context.zig");
const evict_originals_worker = node_api.evict_originals_worker;
const evictOriginalsHandler = evict_originals_worker.evictOriginalsHandler;
const IEvictOriginalsResult = evict_originals_worker.IEvictOriginalsResult;
const ILocalFile = evict_originals_worker.ILocalFile;
const LocalFileMap = evict_originals_worker.LocalFileMap;
const media_file_database = node_api.media_file_database;
const loadMerkleTree = node_api.tree.loadMerkleTree;
const saveMerkleTree = node_api.tree.saveMerkleTree;
const addItem = merkle_tree_zig.merkle_tree.addItem;
const IStorage = storage_zig.storage.IStorage;
const DatabaseFixture = database_fixture.DatabaseFixture;
const TestTaskContext = test_task_context.TestTaskContext;
const errors = utils.errors;

//
// These tests build two real databases in directories of their own, the local one and
// its origin, write the files and merkle trees each test describes, and check the files that were deleted and the tree that
// was saved.
//

const MEGABYTE: u64 = 1024 * 1024;
const GIGABYTE: u64 = 1024 * MEGABYTE;

//
// One file to put in a database's merkle tree.
//
const TreeFile = struct {
    // The path in the database, such as "asset/one".
    name: []const u8,

    // The byte every byte of the content hash is made of.
    hashByte: u8,

    // The size in bytes.
    size: u64,

    // How many days ago the file was last modified, which is what stands in for import time.
    daysAgo: u64,
};

//
// A huge original, so the two gigabyte size budget always wants it gone.
//
fn hugeOriginal(assetId: []const u8, hashByte: u8, daysAgo: u64, allocator: std.mem.Allocator) !TreeFile {
    return .{
        .name = try std.fmt.allocPrint(allocator, "asset/{s}", .{assetId}),
        .hashByte = hashByte,
        .size = 3 * GIGABYTE,
        .daysAgo = daysAgo,
    };
}

//
// The local database, its origin and the context the handler runs with.
//
const World = struct {
    // The local database.
    local: DatabaseFixture,

    // The database the local one names as its origin.
    origin: DatabaseFixture,

    // A directory that holds no database, for an origin that cannot be read.
    emptyDir: []const u8,

    // The task context.
    testContext: TestTaskContext,

    //
    // Creates the databases.
    //
    fn init(world: *World, allocator: std.mem.Allocator, io: std.Io) !void {
        try world.local.init(allocator, io, "evict-originals-local");
        try world.origin.init(allocator, io, "evict-originals-origin");
        world.emptyDir = try temp_dirs.makeTempDir(allocator, io, "evict-originals-empty");
        world.testContext.init(world.local.uuidGenerator.uuidGenerator());
    }

    //
    // Deletes the directories.
    //
    fn deinit(world: *World, io: std.Io) void {
        world.local.deinit(io);
        world.origin.deinit(io);
        temp_dirs.removeTempDir(io, world.emptyDir);
    }
};

//
// Puts the files in a database's merkle tree, with the given database metadata.
//
fn writeTree(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, files: []const TreeFile, filesImported: f64, isPartial: bool) !void {
    var merkleTree = (try loadMerkleTree(allocator, io, storage)).?;
    const nowMs = std.Io.Clock.real.now(io).toMilliseconds();
    for (files) |file| {
        const hash = try allocator.alloc(u8, 32);
        @memset(hash, file.hashByte);
        merkleTree = try addItem(allocator, &merkleTree, .{
            .name = file.name,
            .hash = hash,
            .length = file.size,
            .lastModified = nowMs - @as(i64, @intCast(file.daysAgo)) * 24 * 60 * 60 * 1000,
        });
    }
    var metadata = try media_file_database.emptyDatabaseMetadata(allocator);
    try metadata.put(allocator, "filesImported", .{ .number = filesImported });
    if (isPartial) {
        try metadata.put(allocator, "isPartial", .{ .boolean = true });
    }
    merkleTree.databaseMetadata = metadata;
    try saveMerkleTree(allocator, io, &merkleTree, storage);
}

//
// Writes the files that a tree names into the storage, so there is something to delete.
//
fn writeFiles(allocator: std.mem.Allocator, io: std.Io, storage: IStorage, files: []const TreeFile) !void {
    for (files) |file| {
        try storage.write(allocator, io, file.name, null, "content");
    }
}

//
// How the local database names its origin.
//
const OriginSetUp = enum {
    // The database names no origin.
    none,

    // The origin is a database holding the origin files.
    database,

    // The origin is a directory that holds no database.
    unreadable,
};

//
// Points the handler at a local database and its origin.
//
fn setUpDatabases(
    allocator: std.mem.Allocator,
    io: std.Io,
    world: *World,
    localFiles: []const TreeFile,
    originFiles: []const TreeFile,
    originSetUp: OriginSetUp,
    localFilesImported: f64,
    localIsPartial: bool,
) !void {
    try writeFiles(allocator, io, world.local.database.assetStorage, localFiles);
    try writeTree(allocator, io, world.local.database.assetStorage, localFiles, localFilesImported, localIsPartial);
    switch (originSetUp) {
        .none => {},
        .database => {
            try writeFiles(allocator, io, world.origin.database.assetStorage, originFiles);
            try writeTree(allocator, io, world.origin.database.assetStorage, originFiles, @floatFromInt(originFiles.len), false);
            try api.database_config.saveDatabaseConfig(allocator, io, world.local.rawStorage, .{
                .origin = world.origin.dir,
            });
        },
        .unreadable => {
            try api.database_config.saveDatabaseConfig(allocator, io, world.local.rawStorage, .{
                .origin = world.emptyDir,
            });
        },
    }
}

//
// Runs the handler for the local database, with a budget when one is given.
//
fn runWithBudget(allocator: std.mem.Allocator, io: std.Io, world: *World, budgetBytes: ?f64) !IEvictOriginalsResult {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "databasePath", .{ .string = world.local.dir });
    try object.put(allocator, "sessionId", .{ .string = "session-1" });
    if (budgetBytes) |budget| {
        try object.put(allocator, "localOriginalBudgetBytes", .{ .float = budget });
    }
    const output = try evictOriginalsHandler(allocator, io, .{ .object = object }, world.testContext.context.taskContext());
    return std.json.parseFromValueLeaky(IEvictOriginalsResult, allocator, output, .{});
}

//
// Runs the handler for the local database with the active retention policy.
//
fn run(allocator: std.mem.Allocator, io: std.Io, world: *World) !IEvictOriginalsResult {
    return runWithBudget(allocator, io, world, null);
}

//
// Expects the evicted asset ids to be the expected ones, in order.
//
fn expectEvicted(expected: []const []const u8, result: IEvictOriginalsResult) !void {
    try std.testing.expectEqual(expected.len, result.evictedAssetIds.len);
    for (expected, result.evictedAssetIds) |expectedId, actualId| {
        try std.testing.expectEqualStrings(expectedId, actualId);
    }
}

//
// Whether the local database still holds a file.
//
fn localHas(allocator: std.mem.Allocator, io: std.Io, world: *World, name: []const u8) !bool {
    return world.local.database.assetStorage.fileExists(allocator, io, name);
}

//
// The modification time that setTreeAge gives the local merkle tree file, a moment long before any test runs.
//
const MARKED_TREE_TIME_NANOSECONDS: i96 = 1_000_000_000;

//
// Gives the local merkle tree file a modification time long ago, so that a later rewrite of it can be seen.
//
fn markLocalTree(io: std.Io, allocator: std.mem.Allocator, world: *World) !void {
    try std.Io.Dir.cwd().setTimestamps(io, try std.fs.path.join(allocator, &.{ world.local.dir, node_api.tree.FILES_TREE_PATH }), .{
        .modify_timestamp = .{
            .new = .fromNanoseconds(MARKED_TREE_TIME_NANOSECONDS),
        },
    });
}

//
// Whether the local merkle tree file still has the modification time markLocalTree gave it, which means nothing rewrote it.
//
fn localTreeUntouched(io: std.Io, allocator: std.mem.Allocator, world: *World) !bool {
    const stat = try std.Io.Dir.cwd().statFile(io, try std.fs.path.join(allocator, &.{ world.local.dir, node_api.tree.FILES_TREE_PATH }), .{});
    return stat.mtime.nanoseconds == MARKED_TREE_TIME_NANOSECONDS;
}

test "evicts nothing when there is no origin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io);
    defer world.deinit(io);
    const localFiles = [_]TreeFile{try hugeOriginal("one", 0xaa, 10, allocator)};
    try setUpDatabases(allocator, io, &world, &localFiles, &.{}, .none, 1, false);

    const result = try run(allocator, io, &world);

    try expectEvicted(&.{}, result);
    try std.testing.expectEqualStrings("no origin configured", result.skippedReason.?);
    try std.testing.expect(try localHas(allocator, io, &world, "asset/one"));
}

test "evicts nothing when the origin cannot be read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io);
    defer world.deinit(io);
    const localFiles = [_]TreeFile{try hugeOriginal("one", 0xaa, 10, allocator)};
    try setUpDatabases(allocator, io, &world, &localFiles, &.{}, .unreadable, 1, false);

    const result = try run(allocator, io, &world);

    try expectEvicted(&.{}, result);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "origin not accessible ({s})", .{world.emptyDir}), result.skippedReason.?);
    try std.testing.expect(try localHas(allocator, io, &world, "asset/one"));
}

test "evicts nothing when the local database has no merkle tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io);
    defer world.deinit(io);
    try setUpDatabases(allocator, io, &world, &.{}, &.{}, .database, 0, false);
    try world.local.database.assetStorage.deleteFile(allocator, io, node_api.tree.FILES_TREE_PATH);

    const result = try run(allocator, io, &world);

    try expectEvicted(&.{}, result);
    try std.testing.expectEqualStrings("no local merkle tree", result.skippedReason.?);
}

test "evicts an original the origin holds with a matching hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io);
    defer world.deinit(io);
    const files = [_]TreeFile{try hugeOriginal("one", 0xaa, 10, allocator)};
    try setUpDatabases(allocator, io, &world, &files, &files, .database, 1, false);

    const result = try run(allocator, io, &world);

    try expectEvicted(&.{"one"}, result);
    try std.testing.expect(result.skippedReason == null);
    try std.testing.expect(!try localHas(allocator, io, &world, "asset/one"));
    try std.testing.expectEqual(@as(f64, @floatFromInt(3 * GIGABYTE)), result.freedBytes);
}

test "never evicts an original the origin does not hold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io);
    defer world.deinit(io);
    const localFiles = [_]TreeFile{try hugeOriginal("one", 0xaa, 10, allocator)};
    try setUpDatabases(allocator, io, &world, &localFiles, &.{}, .database, 1, false);

    const result = try run(allocator, io, &world);

    try expectEvicted(&.{}, result);
    try std.testing.expect(try localHas(allocator, io, &world, "asset/one"));
}

test "never evicts an original whose hash on the origin is different" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io);
    defer world.deinit(io);
    const localFiles = [_]TreeFile{try hugeOriginal("one", 0xaa, 10, allocator)};
    const originFiles = [_]TreeFile{try hugeOriginal("one", 0xbb, 10, allocator)};
    try setUpDatabases(allocator, io, &world, &localFiles, &originFiles, .database, 1, false);

    const result = try run(allocator, io, &world);

    try expectEvicted(&.{}, result);
    try std.testing.expect(try localHas(allocator, io, &world, "asset/one"));
}

test "leaves the thumbnail and the micro thumbnail in place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io);
    defer world.deinit(io);
    const files = [_]TreeFile{
        try hugeOriginal("one", 0xaa, 10, allocator),
        .{
            .name = "display/one",
            .hashByte = 0xdd,
            .size = 1000,
            .daysAgo = 10,
        },
        .{
            .name = "thumb/one",
            .hashByte = 0x77,
            .size = 100,
            .daysAgo = 10,
        },
        .{
            .name = "micro/one",
            .hashByte = 0x66,
            .size = 10,
            .daysAgo = 10,
        },
    };
    try setUpDatabases(allocator, io, &world, &files, &files, .database, 1, false);

    _ = try run(allocator, io, &world);

    try std.testing.expect(!try localHas(allocator, io, &world, "asset/one"));
    try std.testing.expect(!try localHas(allocator, io, &world, "display/one"));
    try std.testing.expect(try localHas(allocator, io, &world, "thumb/one"));
    try std.testing.expect(try localHas(allocator, io, &world, "micro/one"));
}

test "keeps the display copy when the origin does not hold a matching one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io);
    defer world.deinit(io);
    const localFiles = [_]TreeFile{
        try hugeOriginal("one", 0xaa, 10, allocator),
        .{
            .name = "display/one",
            .hashByte = 0xdd,
            .size = 1000,
            .daysAgo = 10,
        },
    };
    const originFiles = [_]TreeFile{
        try hugeOriginal("one", 0xaa, 10, allocator),
        .{
            .name = "display/one",
            .hashByte = 0xee,
            .size = 1000,
            .daysAgo = 10,
        },
    };
    try setUpDatabases(allocator, io, &world, &localFiles, &originFiles, .database, 1, false);

    _ = try run(allocator, io, &world);

    try std.testing.expect(!try localHas(allocator, io, &world, "asset/one"));
    try std.testing.expect(try localHas(allocator, io, &world, "display/one"));
}

test "marks the database partial once something has been evicted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io);
    defer world.deinit(io);
    const files = [_]TreeFile{try hugeOriginal("one", 0xaa, 10, allocator)};
    try setUpDatabases(allocator, io, &world, &files, &files, .database, 1, false);

    _ = try run(allocator, io, &world);

    const savedTree = (try loadMerkleTree(allocator, io, world.local.database.assetStorage)).?;
    try std.testing.expect(media_file_database.isPartialDatabase(savedTree.databaseMetadata));
    try std.testing.expectEqual(@as(u64, 1), media_file_database.getFilesImported(savedTree.databaseMetadata));
}

test "does not rewrite the tree when nothing was evicted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io);
    defer world.deinit(io);
    const localFiles = [_]TreeFile{try hugeOriginal("one", 0xaa, 10, allocator)};
    try setUpDatabases(allocator, io, &world, &localFiles, &.{}, .database, 1, false);
    try markLocalTree(io, allocator, &world);

    _ = try run(allocator, io, &world);

    try std.testing.expect(try localTreeUntouched(io, allocator, &world));
    const savedTree = (try loadMerkleTree(allocator, io, world.local.database.assetStorage)).?;
    try std.testing.expect(!media_file_database.isPartialDatabase(savedTree.databaseMetadata));
}

test "does not rewrite the tree when the database is already partial" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io);
    defer world.deinit(io);
    const files = [_]TreeFile{try hugeOriginal("one", 0xaa, 10, allocator)};
    try setUpDatabases(allocator, io, &world, &files, &files, .database, 1, true);
    try markLocalTree(io, allocator, &world);

    const result = try run(allocator, io, &world);

    try expectEvicted(&.{"one"}, result);
    try std.testing.expect(try localTreeUntouched(io, allocator, &world));
}

test "evicts the oldest first and stops once the budget is met" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io);
    defer world.deinit(io);
    // Three originals of one gigabyte each, against a two gigabyte budget: one has to go, and it
    // is the oldest.
    const files = [_]TreeFile{
        .{
            .name = "asset/newest",
            .hashByte = 0x11,
            .size = GIGABYTE,
            .daysAgo = 1,
        },
        .{
            .name = "asset/oldest",
            .hashByte = 0x22,
            .size = GIGABYTE,
            .daysAgo = 100,
        },
        .{
            .name = "asset/middle",
            .hashByte = 0x33,
            .size = GIGABYTE,
            .daysAgo = 50,
        },
    };
    try setUpDatabases(allocator, io, &world, &files, &files, .database, 3, false);

    const result = try run(allocator, io, &world);

    try expectEvicted(&.{"oldest"}, result);
}

test "evicts nothing when the originals are already under the budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io);
    defer world.deinit(io);
    const files = [_]TreeFile{
        .{
            .name = "asset/one",
            .hashByte = 0x11,
            .size = 1000,
            .daysAgo = 100,
        },
    };
    try setUpDatabases(allocator, io, &world, &files, &files, .database, 1, false);

    const result = try run(allocator, io, &world);

    try expectEvicted(&.{}, result);
    try std.testing.expect(try localHas(allocator, io, &world, "asset/one"));
}

test "an original already gone from disk frees nothing and is not an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io);
    defer world.deinit(io);
    const files = [_]TreeFile{try hugeOriginal("one", 0xaa, 10, allocator)};
    try setUpDatabases(allocator, io, &world, &files, &files, .database, 1, false);
    try world.local.database.assetStorage.deleteFile(allocator, io, "asset/one");

    const result = try run(allocator, io, &world);

    try expectEvicted(&.{"one"}, result);
    try std.testing.expectEqual(@as(f64, 0), result.freedBytes);
}

test "a budget given in the task data is used instead of the active policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io);
    defer world.deinit(io);
    // Small originals that the active two gigabyte policy would never touch.
    const files = [_]TreeFile{
        .{
            .name = "asset/one",
            .hashByte = 0x11,
            .size = 1000,
            .daysAgo = 100,
        },
        .{
            .name = "asset/two",
            .hashByte = 0x22,
            .size = 1000,
            .daysAgo = 1,
        },
    };
    try setUpDatabases(allocator, io, &world, &files, &files, .database, 2, false);

    const result = try runWithBudget(allocator, io, &world, 1000);

    try expectEvicted(&.{"one"}, result);
}

test "a budget of zero drops every confirmed original" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io);
    defer world.deinit(io);
    const files = [_]TreeFile{
        .{
            .name = "asset/one",
            .hashByte = 0x11,
            .size = 1000,
            .daysAgo = 100,
        },
        .{
            .name = "asset/two",
            .hashByte = 0x22,
            .size = 1000,
            .daysAgo = 1,
        },
    };
    try setUpDatabases(allocator, io, &world, &files, &files, .database, 2, false);

    const result = try runWithBudget(allocator, io, &world, 0);

    try expectEvicted(&.{ "one", "two" }, result);
}

test "a budget does not override the rule about the origin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io);
    defer world.deinit(io);
    const localFiles = [_]TreeFile{
        .{
            .name = "asset/one",
            .hashByte = 0x11,
            .size = 1000,
            .daysAgo = 100,
        },
    };
    try setUpDatabases(allocator, io, &world, &localFiles, &.{}, .database, 1, false);

    const result = try runWithBudget(allocator, io, &world, 0);

    try expectEvicted(&.{}, result);
    try std.testing.expect(try localHas(allocator, io, &world, "asset/one"));
}

test "stops evicting once the task is cancelled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io);
    defer world.deinit(io);
    const files = [_]TreeFile{try hugeOriginal("one", 0xaa, 10, allocator)};
    try setUpDatabases(allocator, io, &world, &files, &files, .database, 1, false);
    world.testContext.context.cancel();

    const result = try run(allocator, io, &world);

    try expectEvicted(&.{}, result);
    try std.testing.expect(try localHas(allocator, io, &world, "asset/one"));
}

test "refuses a database path that is not given" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io);
    defer world.deinit(io);
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "databasePath", .{ .string = "" });
    try object.put(allocator, "sessionId", .{ .string = "s" });

    try std.testing.expectError(error.Thrown, evictOriginalsHandler(allocator, io, .{ .object = object }, world.testContext.context.taskContext()));
    try std.testing.expectEqualStrings("databasePath is required", errors.lastErrorMessage());

    try std.testing.expectError(error.Thrown, evictOriginalsHandler(allocator, io, .{ .object = .empty }, world.testContext.context.taskContext()));
    try std.testing.expectEqualStrings("databasePath is required", errors.lastErrorMessage());
}

test "throws a descriptive error when the task data is not valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var world: World = undefined;
    try world.init(allocator, io);
    defer world.deinit(io);
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "databasePath", .{ .integer = 5 });

    try std.testing.expectError(error.Thrown, evictOriginalsHandler(allocator, io, .{ .object = object }, world.testContext.context.taskContext()));
    try std.testing.expectEqualStrings("The evict-originals task data is not valid: databasePath and sessionId must be strings, and localOriginalBudgetBytes must be a number", errors.lastErrorMessage());
}

test "buildEvictionCandidates lists the local originals and confirms those the origin holds with the same hash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var localFiles: LocalFileMap = .empty;
    try localFiles.put(allocator, "asset/same", .{
        .contentHash = "aa",
        .sizeBytes = 10,
        .lastModifiedMs = 1000,
    });
    try localFiles.put(allocator, "asset/different", .{
        .contentHash = "bb",
        .sizeBytes = 20,
        .lastModifiedMs = 2000,
    });
    try localFiles.put(allocator, "asset/absent", .{
        .contentHash = "cc",
        .sizeBytes = 30,
        .lastModifiedMs = 3000,
    });
    try localFiles.put(allocator, "display/same", .{
        .contentHash = "dd",
        .sizeBytes = 40,
        .lastModifiedMs = 4000,
    });
    var originFiles: LocalFileMap = .empty;
    try originFiles.put(allocator, "asset/same", .{
        .contentHash = "aa",
        .sizeBytes = 10,
        .lastModifiedMs = 1,
    });
    try originFiles.put(allocator, "asset/different", .{
        .contentHash = "xx",
        .sizeBytes = 20,
        .lastModifiedMs = 2,
    });

    const candidates = try evict_originals_worker.buildEvictionCandidates(allocator, localFiles, originFiles);

    try std.testing.expectEqual(@as(usize, 3), candidates.len);
    try std.testing.expectEqualStrings("same", candidates[0].assetId);
    try std.testing.expectEqual(@as(f64, 10), candidates[0].originalSizeBytes);
    try std.testing.expectEqual(@as(f64, 1000), candidates[0].importedAtMs);
    try std.testing.expect(candidates[0].lastViewedAtMs == null);
    try std.testing.expect(candidates[0].confirmedOnOrigin);
    try std.testing.expectEqualStrings("different", candidates[1].assetId);
    try std.testing.expect(!candidates[1].confirmedOnOrigin);
    try std.testing.expectEqualStrings("absent", candidates[2].assetId);
    try std.testing.expect(!candidates[2].confirmedOnOrigin);
}

test "getDeviceFreeBytes reports zero for a path that is not on a local filesystem" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    try std.testing.expectEqual(@as(f64, 0), try evict_originals_worker.getDeviceFreeBytes(allocator, io, "s3:bucket/path"));
    try std.testing.expectEqual(@as(f64, 0), try evict_originals_worker.getDeviceFreeBytes(allocator, io, "https://example.com/db"));
    try std.testing.expectEqual(@as(f64, 0), try evict_originals_worker.getDeviceFreeBytes(allocator, io, "fs:s3://bucket"));
}

test "getDeviceFreeBytes measures the filesystem of a directory, with or without the fs: prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tempDir = try temp_dirs.makeTempDir(allocator, io, "evict-originals-free-bytes");
    defer temp_dirs.removeTempDir(io, tempDir);

    try std.testing.expect(try evict_originals_worker.getDeviceFreeBytes(allocator, io, tempDir) > 0);
    try std.testing.expect(try evict_originals_worker.getDeviceFreeBytes(allocator, io, try std.fmt.allocPrint(allocator, "fs:{s}", .{tempDir})) > 0);
}

test "getDeviceFreeBytes measures the nearest existing ancestor of a directory that does not exist yet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tempDir = try temp_dirs.makeTempDir(allocator, io, "evict-originals-free-bytes");
    defer temp_dirs.removeTempDir(io, tempDir);

    const missing = try std.fs.path.join(allocator, &.{ tempDir, "not", "made", "yet" });

    try std.testing.expect(try evict_originals_worker.getDeviceFreeBytes(allocator, io, missing) > 0);
    try std.testing.expectEqual(
        try evict_originals_worker.getDeviceFreeBytes(allocator, io, tempDir),
        try evict_originals_worker.getDeviceFreeBytes(allocator, io, missing),
    );
}
