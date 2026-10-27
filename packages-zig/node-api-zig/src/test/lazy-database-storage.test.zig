//
// Tests for isDatabasePartial and createLazyDatabaseStorage of media-file-database.zig. These run them on real databases in directories of their own.
//

const std = @import("std");
const MuteLog = @import("utils-zig").mute_log.MuteLog;
const ILog = @import("utils-zig").log.ILog;
const storage_zig = @import("storage-zig");
const api = @import("api-zig");
const serialization_zig = @import("serialization-zig");
const node_api = @import("node-api-zig");
const virtual_time_io = @import("../../../utils-zig/src/test/virtual-time-io.zig");
const test_files = @import("test-files.zig");
const DatabaseFixture = @import("database-fixture.zig").DatabaseFixture;
const media_file_database = node_api.media_file_database;

//
// Marks the database as a partial copy of the origin: its files tree says so and its config names the origin.
//
fn makePartialCopy(allocator: std.mem.Allocator, io: std.Io, log: ILog, fixture: *DatabaseFixture, origin: ?[]const u8) !void {
    var filesTree = (try node_api.tree.loadMerkleTree(allocator, io, log, fixture.database.assetStorage)).?;
    var metadata = filesTree.databaseMetadata orelse try media_file_database.emptyDatabaseMetadata(allocator);
    try metadata.put(allocator, "isPartial", .{ .boolean = true });
    filesTree.databaseMetadata = metadata;
    try node_api.tree.saveMerkleTree(allocator, io, log, &filesTree, fixture.database.assetStorage);
    if (origin) |originPath| {
        try api.database_config.saveDatabaseConfig(allocator, io, log, fixture.rawStorage, .{
            .origin = originPath,
        });
    }
}

test "isDatabasePartial is false for a full database" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, log, "partial-false");
    defer fixture.deinit(io, log);

    try std.testing.expect(!try media_file_database.isDatabasePartial(allocator, io, log, fixture.dir, null, null));
}

test "isDatabasePartial is true when the files tree says the database is a partial copy" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, log, "partial-true");
    defer fixture.deinit(io, log);
    try makePartialCopy(allocator, io, log, &fixture, null);

    try std.testing.expect(try media_file_database.isDatabasePartial(allocator, io, log, fixture.dir, null, null));
}

test "isDatabasePartial is false where there is no database" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, log, "partial-none");
    defer fixture.deinit(io, log);

    const nowhere = try std.fs.path.join(allocator, &.{ fixture.dir, "not-a-database" });
    try std.testing.expect(!try media_file_database.isDatabasePartial(allocator, io, log, nowhere, null, null));
}

test "createLazyDatabaseStorage returns the plain storage of a database with no origin" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, log, "lazy-no-origin");
    defer fixture.deinit(io, log);
    try makePartialCopy(allocator, io, log, &fixture, null);

    const lazy = try media_file_database.createLazyDatabaseStorage(allocator, io, log, fixture.dir, null, null, null);

    // It reads the database, and a file that is not there is not there.
    try std.testing.expect((try node_api.tree.loadMerkleTree(allocator, io, log, lazy)) != null);
    try std.testing.expect(try lazy.read(allocator, io, log, "thumb/only-at-origin") == null);
}

test "createLazyDatabaseStorage returns the plain storage of a full database that names an origin" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var origin: DatabaseFixture = undefined;
    try origin.init(allocator, io, log, "lazy-full-origin");
    defer origin.deinit(io, log);
    try test_files.writeFile(io, try std.fs.path.join(allocator, &.{ origin.dir, "thumb", "only-at-origin" }), "from the origin");
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, log, "lazy-full");
    defer fixture.deinit(io, log);
    try api.database_config.saveDatabaseConfig(allocator, io, log, fixture.rawStorage, .{
        .origin = origin.dir,
    });

    const lazy = try media_file_database.createLazyDatabaseStorage(allocator, io, log, fixture.dir, null, null, null);

    try std.testing.expect(try lazy.read(allocator, io, log, "thumb/only-at-origin") == null);
}

test "createLazyDatabaseStorage fetches a file a partial copy does not hold from its origin" {
    const log = MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var origin: DatabaseFixture = undefined;
    try origin.init(allocator, io, log, "lazy-partial-origin");
    defer origin.deinit(io, log);
    try test_files.writeFile(io, try std.fs.path.join(allocator, &.{ origin.dir, "thumb", "only-at-origin" }), "from the origin");
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, log, "lazy-partial");
    defer fixture.deinit(io, log);
    try makePartialCopy(allocator, io, log, &fixture, origin.dir);

    const lazy = try media_file_database.createLazyDatabaseStorage(allocator, io, log, fixture.dir, null, null, null);

    const fetched = (try lazy.read(allocator, io, log, "thumb/only-at-origin")).?;
    try std.testing.expectEqualStrings("from the origin", fetched);
}
