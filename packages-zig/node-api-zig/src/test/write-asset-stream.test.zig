//
// Tests for writeAssetStream, writeAsset and streamAsset of media-file-database.zig.
//
// These run the real write lock, merkle tree functions and hash against a new database in
// a directory of its own, and look at the database afterwards.
//

const std = @import("std");
const utils = @import("utils-zig");
const merkle_tree_zig = @import("merkle-tree-zig");
const node_api = @import("node-api-zig");
const virtual_time_io = @import("../../../utils-zig/src/test/virtual-time-io.zig");
const test_files = @import("test-files.zig");
const sync_test_helpers = @import("sync-test-helpers.zig");
const DatabaseFixture = @import("database-fixture.zig").DatabaseFixture;
const media_file_database = node_api.media_file_database;

//
// A virtual-time io, so that the retries of a failing write do not wait for real.
//
const Retrying = struct {
    // The io.
    virtual_time: virtual_time_io.VirtualTimeIo,

    //
    // Starts the io.
    //
    fn init(retrying: *Retrying) void {
        retrying.virtual_time.initWith(std.testing.allocator, virtual_time_io.VirtualTimeIo.Options.retry);
    }

    //
    // Stops the io.
    //
    fn deinit(retrying: *Retrying) void {
        retrying.virtual_time.deinit();
    }
};

//
// Writes four bytes as an asset of the type, from a stream that knows its length.
//
fn writeFourBytes(allocator: std.mem.Allocator, io: std.Io, fixture: *DatabaseFixture, assetId: []const u8, assetType: []const u8) !void {
    var stream = std.Io.Reader.fixed("abcd");
    const storage = fixture.database.assetStorage;
    try media_file_database.writeAssetStream(allocator, io, storage, fixture.rawStorage, "session-1", assetId, assetType, "image/jpeg", &stream, 4);
}

test "writeAssetStream writes the stream to the correct asset path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var retrying: Retrying = undefined;
    retrying.init();
    defer retrying.deinit();
    const io = retrying.virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "write-asset-stream-path");
    defer fixture.deinit(io);

    var spy: sync_test_helpers.SpyStorage = .{
        .allocator = allocator,
        .inner = fixture.database.assetStorage,
    };
    var stream = std.Io.Reader.fixed("abcd");
    try media_file_database.writeAssetStream(allocator, io, spy.storage(), fixture.rawStorage, "session-1", "t1", "thumb", "image/jpeg", &stream, 4);

    try std.testing.expectEqual(@as(usize, 1), spy.writeStreamCalls.items.len);
    try std.testing.expectEqualStrings("thumb/t1", spy.writeStreamCalls.items[0].filePath);
    try std.testing.expectEqualStrings("image/jpeg", spy.writeStreamCalls.items[0].contentType.?);
    try std.testing.expectEqual(@as(?u64, 4), spy.writeStreamCalls.items[0].contentLength);

    const written = try test_files.readFile(allocator, io, try std.fs.path.join(allocator, &.{ fixture.dir, "thumb", "t1" }));
    try std.testing.expectEqualStrings("abcd", written);
}

test "writeAssetStream adds the written file to the merkle tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var retrying: Retrying = undefined;
    retrying.init();
    defer retrying.deinit();
    const io = retrying.virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "write-asset-stream-tree");
    defer fixture.deinit(io);

    try writeFourBytes(allocator, io, &fixture, "t1", "thumb");

    // The README and the new file, with the hash and the length of what was written.
    const filesTree = (try node_api.tree.loadMerkleTree(allocator, io, fixture.database.assetStorage)).?;
    try std.testing.expectEqual(@as(u32, 2), filesTree.sort.?.leafCount);
    const item = (try merkle_tree_zig.merkle_tree.getItemInfo(&filesTree, "thumb/t1")).?;
    var expectedHash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("abcd", &expectedHash, .{});
    try std.testing.expectEqualSlices(u8, &expectedHash, item.hash);
    try std.testing.expectEqual(@as(u64, 4), item.length);
}

//
// The number of files the database says it has imported.
//
fn filesImported(allocator: std.mem.Allocator, io: std.Io, fixture: *DatabaseFixture) !u64 {
    const filesTree = (try node_api.tree.loadMerkleTree(allocator, io, fixture.database.assetStorage)).?;
    return media_file_database.getFilesImported(filesTree.databaseMetadata);
}

test "writeAssetStream increments filesImported when assetType is asset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var retrying: Retrying = undefined;
    retrying.init();
    defer retrying.deinit();
    const io = retrying.virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "write-asset-stream-asset");
    defer fixture.deinit(io);

    try writeFourBytes(allocator, io, &fixture, "a1", "asset");

    try std.testing.expectEqual(@as(u64, 1), try filesImported(allocator, io, &fixture));
}

test "writeAssetStream does not increment filesImported when assetType is thumb" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var retrying: Retrying = undefined;
    retrying.init();
    defer retrying.deinit();
    const io = retrying.virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "write-asset-stream-thumb");
    defer fixture.deinit(io);

    try writeFourBytes(allocator, io, &fixture, "t1", "thumb");

    try std.testing.expectEqual(@as(u64, 0), try filesImported(allocator, io, &fixture));
}

test "writeAssetStream does not increment filesImported when assetType is display" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var retrying: Retrying = undefined;
    retrying.init();
    defer retrying.deinit();
    const io = retrying.virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "write-asset-stream-display");
    defer fixture.deinit(io);

    try writeFourBytes(allocator, io, &fixture, "d1", "display");

    try std.testing.expectEqual(@as(u64, 0), try filesImported(allocator, io, &fixture));
}

test "writeAssetStream stamps the database as modified after writing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var retrying: Retrying = undefined;
    retrying.init();
    defer retrying.deinit();
    const io = retrying.virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "write-asset-stream-stamp");
    defer fixture.deinit(io);

    try writeFourBytes(allocator, io, &fixture, "t1", "thumb");

    const state = (try @import("api-zig").database_state.loadDatabaseState(allocator, io, fixture.rawStorage)).?;
    try std.testing.expect(state.lastModifiedAt != null);
}

test "writeAssetStream throws when the write lock cannot be acquired" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var retrying: Retrying = undefined;
    retrying.init();
    defer retrying.deinit();
    const io = retrying.virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "write-asset-stream-locked");
    defer fixture.deinit(io);
    try std.testing.expect(try fixture.rawStorage.acquireWriteLock(allocator, io, ".db/write.lock", "another-session"));
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(null, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    try std.testing.expectError(error.Thrown, writeFourBytes(allocator, io, &fixture, "t1", "thumb"));
    try std.testing.expectEqualStrings("Failed to acquire write lock.", utils.errors.errorMessage(error.Thrown));
    try std.testing.expect(!test_files.fileExists(io, try std.fs.path.join(allocator, &.{ fixture.dir, "thumb", "t1" })));
}

test "writeAssetStream releases the write lock after writing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var retrying: Retrying = undefined;
    retrying.init();
    defer retrying.deinit();
    const io = retrying.virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "write-asset-stream-release");
    defer fixture.deinit(io);

    try writeFourBytes(allocator, io, &fixture, "t1", "thumb");

    try std.testing.expect((try fixture.rawStorage.checkWriteLock(allocator, io, ".db/write.lock")) == null);
}

//
// Writes an empty stream as an asset of the type with the announced length, capturing what the log says, and returns the error.
//
fn writeEmptyStream(allocator: std.mem.Allocator, io: std.Io, fixture: *DatabaseFixture, contentLength: ?u64) !void {
    var stream = std.Io.Reader.fixed("");
    const storage = fixture.database.assetStorage;
    try media_file_database.writeAssetStream(allocator, io, storage, fixture.rawStorage, "session-1", "t1", "thumb", null, &stream, contentLength);
}

test "writeAssetStream releases the write lock even when the write fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var retrying: Retrying = undefined;
    retrying.init();
    defer retrying.deinit();
    const io = retrying.virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "write-asset-stream-fail-release");
    defer fixture.deinit(io);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(null, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    try std.testing.expectError(error.Thrown, writeEmptyStream(allocator, io, &fixture, 1));
    try std.testing.expectEqualStrings("Asset data is empty", utils.errors.errorMessage(error.Thrown));

    try std.testing.expect((try fixture.rawStorage.checkWriteLock(allocator, io, ".db/write.lock")) == null);
}

test "writeAssetStream deletes the partially-written file when the write fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var retrying: Retrying = undefined;
    retrying.init();
    defer retrying.deinit();
    const io = retrying.virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "write-asset-stream-fail-delete");
    defer fixture.deinit(io);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(null, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    try std.testing.expectError(error.Thrown, writeEmptyStream(allocator, io, &fixture, 1));

    try std.testing.expect(!test_files.fileExists(io, try std.fs.path.join(allocator, &.{ fixture.dir, "thumb", "t1" })));
}

test "writeAssetStream rejects when announced content length is zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var retrying: Retrying = undefined;
    retrying.init();
    defer retrying.deinit();
    const io = retrying.virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "write-asset-stream-zero-announced");
    defer fixture.deinit(io);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(null, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    try std.testing.expectError(error.Thrown, writeEmptyStream(allocator, io, &fixture, 0));
    try std.testing.expectEqualStrings("Asset data is empty", utils.errors.errorMessage(error.Thrown));
}

test "writeAssetStream rejects when written file has zero length and no length was announced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var retrying: Retrying = undefined;
    retrying.init();
    defer retrying.deinit();
    const io = retrying.virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "write-asset-stream-zero-unannounced");
    defer fixture.deinit(io);
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(null, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    try std.testing.expectError(error.Thrown, writeEmptyStream(allocator, io, &fixture, null));
    try std.testing.expectEqualStrings("Asset data is empty", utils.errors.errorMessage(error.Thrown));
}

// The tests below cover writeAsset and streamAsset.

test "writeAsset writes the buffer, adds it to the merkle tree and counts an asset as imported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var retrying: Retrying = undefined;
    retrying.init();
    defer retrying.deinit();
    const io = retrying.virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "write-asset-buffer");
    defer fixture.deinit(io);

    try media_file_database.writeAsset(allocator, io, fixture.database.assetStorage, fixture.rawStorage, "session-1", "a1", "asset", "image/jpeg", "abcd");

    const written = try test_files.readFile(allocator, io, try std.fs.path.join(allocator, &.{ fixture.dir, "asset", "a1" }));
    try std.testing.expectEqualStrings("abcd", written);
    const filesTree = (try node_api.tree.loadMerkleTree(allocator, io, fixture.database.assetStorage)).?;
    try std.testing.expect((try merkle_tree_zig.merkle_tree.getItemInfo(&filesTree, "asset/a1")) != null);
    try std.testing.expectEqual(@as(u64, 1), media_file_database.getFilesImported(filesTree.databaseMetadata));
    try std.testing.expect((try fixture.rawStorage.checkWriteLock(allocator, io, ".db/write.lock")) == null);
}

test "writeAsset throws and releases the lock when the lock is held by another session" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var retrying: Retrying = undefined;
    retrying.init();
    defer retrying.deinit();
    const io = retrying.virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "write-asset-buffer-locked");
    defer fixture.deinit(io);
    try std.testing.expect(try fixture.rawStorage.acquireWriteLock(allocator, io, ".db/write.lock", "another-session"));
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(null, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    try std.testing.expectError(error.Thrown, media_file_database.writeAsset(allocator, io, fixture.database.assetStorage, fixture.rawStorage, "session-1", "a1", "asset", null, "abcd"));
    try std.testing.expectEqualStrings("Failed to acquire write lock.", utils.errors.errorMessage(error.Thrown));
}

test "streamAsset reads back the bytes of an asset by type and id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var retrying: Retrying = undefined;
    retrying.init();
    defer retrying.deinit();
    const io = retrying.virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "stream-asset");
    defer fixture.deinit(io);
    try writeFourBytes(allocator, io, &fixture, "t1", "thumb");

    const stream = try media_file_database.streamAsset(allocator, io, fixture.database.assetStorage, "t1", "thumb");
    defer stream.destroy(io);

    const bytes = try stream.reader().allocRemaining(allocator, .unlimited);
    try std.testing.expectEqualStrings("abcd", bytes);
}

test "streamAsset fails for an asset that is not there" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var retrying: Retrying = undefined;
    retrying.init();
    defer retrying.deinit();
    const io = retrying.virtual_time.io();
    var fixture: DatabaseFixture = undefined;
    try fixture.init(allocator, io, "stream-asset-missing");
    defer fixture.deinit(io);

    try std.testing.expect(std.meta.isError(media_file_database.streamAsset(allocator, io, fixture.database.assetStorage, "missing", "thumb")));
}
