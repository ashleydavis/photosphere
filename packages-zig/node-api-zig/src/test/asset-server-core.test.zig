//
// Tests for asset-server-core.zig.
//
// These run the core against real databases in directories of their own, and look at what ended up on disk.
//

const std = @import("std");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const virtual_time_io = @import("../../../utils-zig/src/test/virtual-time-io.zig");
const test_files = @import("test-files.zig");
const DatabaseFixture = @import("database-fixture.zig").DatabaseFixture;
const asset_server_core = node_api.asset_server_core;
const media_file_database = node_api.media_file_database;
const IStorage = storage_zig.storage.IStorage;

//
// The session id the core is made with.
//
const SESSION_ID = "test-session";

//
// A virtual-time io and a database to serve, with a core over them.
//
const CoreFixture = struct {
    // A virtual-time io, so that the retries of a failing step do not wait for real.
    virtual_time: virtual_time_io.VirtualTimeIo,

    // The database the core serves.
    database: DatabaseFixture,

    // The core.
    core: *asset_server_core.AssetServerCore,

    //
    // Starts the io, makes the database and the core.
    //
    fn init(fixture: *CoreFixture, allocator: std.mem.Allocator, name: []const u8) !void {
        fixture.virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
        const io = fixture.virtual_time.io();
        try fixture.database.init(allocator, io, name);
        fixture.core = try asset_server_core.createAssetServerCore(std.testing.allocator, .{
            .uuidGenerator = fixture.database.uuidGenerator.uuidGenerator(),
            .timestampProvider = fixture.database.timestampProvider.timestampProvider(),
            .sessionId = SESSION_ID,
            .nativeCaller = null,
        });
    }

    //
    // Frees the core, the database and the io.
    //
    fn deinit(fixture: *CoreFixture) void {
        const io = fixture.virtual_time.io();
        fixture.core.deinit(std.testing.allocator);
        fixture.database.deinit(io);
        fixture.virtual_time.deinit();
    }

    //
    // Writes four bytes into the database as an asset of the type.
    //
    fn putAsset(fixture: *CoreFixture, allocator: std.mem.Allocator, assetId: []const u8, assetType: []const u8) !void {
        var stream = std.Io.Reader.fixed("abcd");
        const io = fixture.virtual_time.io();
        try media_file_database.writeAssetStream(allocator, io, fixture.database.database.assetStorage, fixture.database.rawStorage, "putter", assetId, assetType, "image/jpeg", &stream, 4);
    }

    //
    // Reads what the core serves for an asset. The allocator, the test's, is also what the core keeps its cache in, as a connection
    // thread's arena is.
    //
    fn served(fixture: *CoreFixture, allocator: std.mem.Allocator, assetId: []const u8, assetType: []const u8, databasePath: []const u8) ![]u8 {
        const io = fixture.virtual_time.io();
        const stream = try fixture.core.assetServerCore().serveAsset(allocator, allocator, io, assetId, assetType, databasePath);
        defer stream.destroy(io);
        return stream.reader().allocRemaining(allocator, .unlimited);
    }
};

test "serveAsset streams the asset bytes for the given id/type/db" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture: CoreFixture = undefined;
    try fixture.init(allocator, "core-serve");
    defer fixture.deinit();
    try fixture.putAsset(allocator, "asset-1", "thumb");

    const bytes = try fixture.served(allocator, "asset-1", "thumb", fixture.database.dir);

    try std.testing.expectEqualStrings("abcd", bytes);
}

test "serveAsset serves each asset type from the same storage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture: CoreFixture = undefined;
    try fixture.init(allocator, "core-types");
    defer fixture.deinit();
    for ([_][]const u8{ "thumb", "display", "asset" }) |assetType| {
        try fixture.putAsset(allocator, "asset-1", assetType);
    }

    for ([_][]const u8{ "thumb", "display", "asset" }) |assetType| {
        const bytes = try fixture.served(allocator, "asset-1", assetType, fixture.database.dir);
        try std.testing.expectEqualStrings("abcd", bytes);
    }
    try std.testing.expectEqual(@as(u32, 1), fixture.core.storageCache.count());
}

test "serveAsset caches storage per database path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture: CoreFixture = undefined;
    try fixture.init(allocator, "core-cache");
    defer fixture.deinit();
    try fixture.putAsset(allocator, "asset-1", "thumb");
    try fixture.putAsset(allocator, "asset-2", "thumb");

    _ = try fixture.served(allocator, "asset-1", "thumb", fixture.database.dir);
    const first = fixture.core.storageCache.get(fixture.database.dir).?;
    _ = try fixture.served(allocator, "asset-2", "thumb", fixture.database.dir);
    const second = fixture.core.storageCache.get(fixture.database.dir).?;

    // Storage is only created once for the same database path.
    try std.testing.expectEqual(@as(u32, 1), fixture.core.storageCache.count());
    try std.testing.expectEqual(first.ptr, second.ptr);
}

test "serveAsset creates separate storage for different database paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture: CoreFixture = undefined;
    try fixture.init(allocator, "core-paths-one");
    defer fixture.deinit();
    var other: DatabaseFixture = undefined;
    try other.init(allocator, fixture.virtual_time.io(), "core-paths-two");
    defer other.deinit(fixture.virtual_time.io());
    try fixture.putAsset(allocator, "asset-1", "thumb");
    var stream = std.Io.Reader.fixed("wxyz");
    try media_file_database.writeAssetStream(allocator, fixture.virtual_time.io(), other.database.assetStorage, other.rawStorage, "putter", "asset-1", "thumb", "image/jpeg", &stream, 4);

    const one = try fixture.served(allocator, "asset-1", "thumb", fixture.database.dir);
    const two = try fixture.served(allocator, "asset-1", "thumb", other.dir);

    try std.testing.expectEqual(@as(u32, 2), fixture.core.storageCache.count());
    try std.testing.expectEqualStrings("abcd", one);
    try std.testing.expectEqualStrings("wxyz", two);
}

test "serveAsset propagates a missing-asset error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture: CoreFixture = undefined;
    try fixture.init(allocator, "core-missing");
    defer fixture.deinit();

    try std.testing.expect(std.meta.isError(fixture.served(allocator, "missing", "thumb", fixture.database.dir)));
}

//
// A stream of four bytes that, when it is first read, looks at who holds the write lock of the database.
//
const LockSpyStream = struct {
    // The reader.
    interface: std.Io.Reader,

    // The storage holding the lock.
    rawStorage: IStorage,

    // The Io to ask the storage with.
    io: std.Io,

    // Allocates the owner copy.
    allocator: std.mem.Allocator,

    // The owner of the lock when the stream was read, or null if there was none.
    ownerSeen: ?[]const u8,

    // Whether the bytes have been given.
    sent: bool,

    //
    // Looks at the write lock the first time it is read, then gives the four bytes.
    //
    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        _ = limit;
        const self: *LockSpyStream = @fieldParentPtr("interface", reader);
        if (self.sent) {
            return error.EndOfStream;
        }
        self.sent = true;
        const lock = self.rawStorage.checkWriteLock(self.allocator, self.io, ".db/write.lock") catch return error.ReadFailed;
        if (lock) |held| {
            self.ownerSeen = self.allocator.dupe(u8, held.owner) catch return error.ReadFailed;
        }
        try writer.writeAll("abcd");
        return 4;
    }

    //
    // Makes a stream over the storage that holds the lock.
    //
    fn init(rawStorage: IStorage, io: std.Io, allocator: std.mem.Allocator) LockSpyStream {
        return .{
            .interface = .{
                .vtable = &.{
                    .stream = stream,
                },
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
            .rawStorage = rawStorage,
            .io = io,
            .allocator = allocator,
            .ownerSeen = null,
            .sent = false,
        };
    }
};

test "writeAsset writes the stream via writeAssetStream with the session id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture: CoreFixture = undefined;
    try fixture.init(allocator, "core-write");
    defer fixture.deinit();
    const io = fixture.virtual_time.io();
    var spy = LockSpyStream.init(fixture.database.rawStorage, io, allocator);

    try fixture.core.assetServerCore().writeAsset(allocator, io, "asset-1", "display", fixture.database.dir, "image/jpeg", &spy.interface, 4);

    // The bytes are in the database at the asset's path, and the core held the write lock under its session id while it wrote.
    const written = try test_files.readFile(allocator, io, try std.fs.path.join(allocator, &.{ fixture.database.dir, "display", "asset-1" }));
    try std.testing.expectEqualStrings("abcd", written);
    try std.testing.expectEqualStrings(SESSION_ID, spy.ownerSeen.?);
    try std.testing.expect((try fixture.database.rawStorage.checkWriteLock(allocator, io, ".db/write.lock")) == null);
}

test "applyDatabaseOps delegates to the apply-database-ops library with context identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var fixture: CoreFixture = undefined;
    try fixture.init(allocator, "core-apply");
    defer fixture.deinit();
    const io = fixture.virtual_time.io();
    const databasePathJson = try utils.json.stringify(allocator, fixture.database.dir);
    const opText = try std.fmt.allocPrint(allocator, "{{\"databaseId\":{s},\"collectionName\":\"metadata\",\"recordId\":\"a1b2c3d4-e5f6-7890-abcd-ef1234567890\",\"op\":{{\"type\":\"set\",\"fields\":{{\"origFileName\":\"x.jpg\"}}}}}}", .{databasePathJson});
    const op = try api.database_op.databaseOpFromJson(try std.json.parseFromSliceLeaky(std.json.Value, allocator, opText, .{}));

    try fixture.core.assetServerCore().applyDatabaseOps(allocator, io, &.{op});

    const reopened = try node_api.open_storage.openStorage(allocator, io, fixture.database.dir, null, null, null);
    const database = try media_file_database.createMediaFileDatabase(allocator, reopened.storage, fixture.database.uuidGenerator.uuidGenerator(), fixture.database.timestampProvider.timestampProvider());
    const loaded = (try database.metadataCollection.getOne(io, "a1b2c3d4-e5f6-7890-abcd-ef1234567890")).?;
    try std.testing.expectEqualStrings("x.jpg", loaded.get("origFileName").?.string);
    try std.testing.expect((try fixture.database.rawStorage.checkWriteLock(allocator, io, ".db/write.lock")) == null);
}
