//
// Tests for writeAssetStreamVerified of media-file-database.zig.
//
// These write to a new database in a directory of its own, read the source
// from another, and compare the real hashes of the two.
//

const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const node_api = @import("node-api-zig");
const virtual_time_io = @import("../../../utils-zig/src/test/virtual-time-io.zig");
const test_files = @import("test-files.zig");
const sync_test_helpers = @import("sync-test-helpers.zig");
const DatabaseFixture = @import("database-fixture.zig").DatabaseFixture;
const media_file_database = node_api.media_file_database;

//
// Two new databases, the first holding a thumb called src-id with four bytes in it.
//
const Fixtures = struct {
    // The source database.
    source: DatabaseFixture,

    // The destination database.
    dest: DatabaseFixture,

    //
    // Makes both databases.
    //
    fn init(fixtures: *Fixtures, allocator: std.mem.Allocator, io: std.Io, log: ILog, name: []const u8) !void {
        try fixtures.source.init(allocator, io, log, try std.fmt.allocPrint(allocator, "{s}-source", .{name}));
        try fixtures.dest.init(allocator, io, log, try std.fmt.allocPrint(allocator, "{s}-dest", .{name}));
        try test_files.writeFile(io, try std.fs.path.join(allocator, &.{ fixtures.source.dir, "thumb", "src-id" }), "abcd");
    }

    //
    // Deletes both databases.
    //
    fn deinit(fixtures: *Fixtures, io: std.Io, log: ILog) void {
        fixtures.source.deinit(io, log);
        fixtures.dest.deinit(io, log);
    }
};

//
// Starts a virtual-time io, so that the retries of a failing step do not wait for real.
//
fn startIo(virtual_time: *virtual_time_io.VirtualTimeIo) void {
    virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
}

test "writeAssetStreamVerified calls writeAssetStream with dest storage and correct arguments" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    startIo(&virtual_time);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var fixtures: Fixtures = undefined;
    try fixtures.init(allocator, io, log, "verified-writes");
    defer fixtures.deinit(io, log);
    var spy: sync_test_helpers.SpyStorage = .{
        .allocator = allocator,
        .inner = fixtures.dest.database.assetStorage,
    };
    var stream = std.Io.Reader.fixed("abcd");

    try media_file_database.writeAssetStreamVerified(allocator, io, log, fixtures.source.database.assetStorage, spy.storage(), fixtures.dest.rawStorage, "session-1", "src-id", "dst-id", "thumb", "image/jpeg", &stream, 4);

    try std.testing.expectEqual(@as(usize, 1), spy.writeStreamCalls.items.len);
    try std.testing.expectEqualStrings("thumb/dst-id", spy.writeStreamCalls.items[0].filePath);
    try std.testing.expectEqualStrings("image/jpeg", spy.writeStreamCalls.items[0].contentType.?);
    try std.testing.expectEqual(@as(?u64, 4), spy.writeStreamCalls.items[0].contentLength);

    const written = try test_files.readFile(allocator, io, try std.fs.path.join(allocator, &.{ fixtures.dest.dir, "thumb", "dst-id" }));
    try std.testing.expectEqualStrings("abcd", written);
}

test "writeAssetStreamVerified throws when source file is not accessible after write" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    startIo(&virtual_time);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var fixtures: Fixtures = undefined;
    try fixtures.init(allocator, io, log, "verified-no-source");
    defer fixtures.deinit(io, log);
    var stream = std.Io.Reader.fixed("abcd");

    try std.testing.expectError(error.Thrown, media_file_database.writeAssetStreamVerified(allocator, io, log, fixtures.source.database.assetStorage, fixtures.dest.database.assetStorage, fixtures.dest.rawStorage, "session-1", "no-such-id", "dst-id", "thumb", "image/jpeg", &stream, 4));
    try std.testing.expectEqualStrings("Verification failed: source file \"thumb/no-such-id\" is no longer accessible after write.", utils.errors.errorMessage(error.Thrown));
}

test "writeAssetStreamVerified throws when destination file is not found after write" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    startIo(&virtual_time);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var fixtures: Fixtures = undefined;
    try fixtures.init(allocator, io, log, "verified-no-dest");
    defer fixtures.deinit(io, log);
    var stream = std.Io.Reader.fixed("abcd");

    // writeAssetStream asks the destination for info() once to verify the write succeeded. writeAssetStreamVerified then asks again
    // for its own verification check. The destination answers the first and says the file is not there to the second.
    var spy: sync_test_helpers.SpyStorage = .{
        .allocator = allocator,
        .inner = fixtures.dest.database.assetStorage,
        .infoHiddenAfter = 1,
    };

    try std.testing.expectError(error.Thrown, media_file_database.writeAssetStreamVerified(allocator, io, log, fixtures.source.database.assetStorage, spy.storage(), fixtures.dest.rawStorage, "session-1", "src-id", "dst-id", "thumb", "image/jpeg", &stream, 4));
    try std.testing.expectEqualStrings("Verification failed: destination file \"thumb/dst-id\" not found after write.", utils.errors.errorMessage(error.Thrown));
}

test "writeAssetStreamVerified throws when source and dest hashes do not match" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    startIo(&virtual_time);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var fixtures: Fixtures = undefined;
    try fixtures.init(allocator, io, log, "verified-mismatch");
    defer fixtures.deinit(io, log);
    var stream = std.Io.Reader.fixed("wxyz");

    try std.testing.expectError(error.Thrown, media_file_database.writeAssetStreamVerified(allocator, io, log, fixtures.source.database.assetStorage, fixtures.dest.database.assetStorage, fixtures.dest.rawStorage, "session-1", "src-id", "dst-id", "thumb", "image/jpeg", &stream, 4));
    try std.testing.expectEqualStrings("Verification failed: hash mismatch for \"thumb\" of asset \"src-id\" -- destination copy is corrupt.", utils.errors.errorMessage(error.Thrown));
}

test "writeAssetStreamVerified resolves when source and dest hashes match" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var virtual_time: virtual_time_io.VirtualTimeIo = undefined;
    startIo(&virtual_time);
    defer virtual_time.deinit();
    const io = virtual_time.io();
    var fixtures: Fixtures = undefined;
    try fixtures.init(allocator, io, log, "verified-match");
    defer fixtures.deinit(io, log);
    var stream = std.Io.Reader.fixed("abcd");

    try media_file_database.writeAssetStreamVerified(allocator, io, log, fixtures.source.database.assetStorage, fixtures.dest.database.assetStorage, fixtures.dest.rawStorage, "session-1", "src-id", "dst-id", "thumb", "image/jpeg", &stream, 4);
}
