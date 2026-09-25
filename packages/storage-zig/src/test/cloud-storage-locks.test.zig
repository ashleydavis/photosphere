//
// Tests for the write locks of CloudStorage (port of src/tests/cloud-storage-locks.test.ts).
// (Zig: the TypeScript tests replace the S3 client with a stub; here the storage talks to the mock S3 server.)
//

const std = @import("std");
const storage_zig = @import("storage-zig");
const utils = @import("utils-zig");
const mock = @import("mock-s3-server.zig");
const MockS3Server = mock.MockS3Server;

const CloudStorage = storage_zig.cloud_storage.CloudStorage;
const Date = utils.timestamp_provider.Date;

//
// The lock the tests acquire.
//
const lockPath = "test-bucket/db/.db/write.lock";

//
// A mock server and a storage connected to it.
//
const Fixture = struct {
    // The arena for the test.
    arena: std.heap.ArenaAllocator,

    // The mock server.
    server: *MockS3Server,

    // The storage under test.
    storage: CloudStorage,

    //
    // Starts the server and creates the storage.
    //
    fn init(fixture: *Fixture) !void {
        fixture.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        fixture.server = try MockS3Server.start(std.testing.io);
        fixture.storage = CloudStorage.init(std.testing.io, "s3:", .{
            .accessKeyId = mock.ACCESS_KEY_ID,
            .secretAccessKey = mock.SECRET_ACCESS_KEY,
            .region = mock.REGION,
            .endpoint = try fixture.server.endpoint(fixture.arena.allocator()),
        });
    }

    //
    // Stops everything.
    //
    fn deinit(fixture: *Fixture) void {
        fixture.storage.s3.deinit();
        fixture.server.stop();
        fixture.arena.deinit();
    }

    //
    // Stores a lock object naming its owner and when it was taken.
    //
    fn putLock(fixture: *Fixture, owner: []const u8, timestamp: i64) !void {
        const allocator = fixture.arena.allocator();
        const acquiredAt = try (Date{ .epochMilliseconds = timestamp }).toISOString(allocator);
        const lockBody = try std.fmt.allocPrint(allocator, "{{\"owner\":\"{s}\",\"acquiredAt\":\"{s}\",\"timestamp\":{d}}}", .{ owner, acquiredAt, timestamp });
        try fixture.server.putObject(lockPath, lockBody);
    }
};

// describe('CloudStorage write lock')

test "refuses the lock while another owner holds a live one" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.putLock("owner-a", std.Io.Clock.real.now(std.testing.io).toMilliseconds());

    try std.testing.expect(!try fixture.storage.acquireWriteLock(fixture.arena.allocator(), std.testing.io, lockPath, "owner-b"));
    try std.testing.expectEqual(@as(usize, 0), fixture.server.countRequests("DELETE"));
}

//
// The failure this pins: the lock is there, because the conditional write was refused, but
// reading it back returns nothing because the read raced its owner. Treating that as a corrupt
// lock and breaking it put three processes in the critical section at once.
//
test "refuses the lock when it is there but reads back as absent" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.putLock("owner-a", std.Io.Clock.real.now(std.testing.io).toMilliseconds());
    fixture.server.getObjectNoSuchKey = true;

    try std.testing.expect(!try fixture.storage.acquireWriteLock(fixture.arena.allocator(), std.testing.io, lockPath, "owner-b"));
    try std.testing.expectEqual(@as(usize, 0), fixture.server.countRequests("DELETE"));
}

test "still breaks a lock that has aged past the timeout and takes it" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    try fixture.putLock("owner-a", std.Io.Clock.real.now(std.testing.io).toMilliseconds() - 60_000);

    try std.testing.expect(try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockPath, "owner-b"));
    try std.testing.expectEqual(@as(usize, 1), fixture.server.countRequests("DELETE"));
    const lockInfo = try fixture.storage.checkWriteLock(allocator, std.testing.io, lockPath);
    try std.testing.expectEqualStrings("owner-b", lockInfo.?.owner);
}

test "acquires a free lock, reads it back and releases it" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();

    try std.testing.expect((try fixture.storage.checkWriteLock(allocator, std.testing.io, lockPath)) == null);
    try std.testing.expect(try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockPath, "owner-a"));
    const lockInfo = try fixture.storage.checkWriteLock(allocator, std.testing.io, lockPath);
    try std.testing.expectEqualStrings("owner-a", lockInfo.?.owner);
    try std.testing.expectEqualStrings("application/json", fixture.server.getContentType(lockPath).?);

    try fixture.storage.releaseWriteLock(allocator, std.testing.io, lockPath);
    try std.testing.expect((try fixture.storage.checkWriteLock(allocator, std.testing.io, lockPath)) == null);
    try std.testing.expect(try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockPath, "owner-b"));
    try std.testing.expectEqual(@as(u32, 0), fixture.server.signatureFailures);
}

test "checkWriteLock wraps a lock that is not valid JSON" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.server.putObject(lockPath, "invalid json");

    try std.testing.expectError(error.Thrown, fixture.storage.checkWriteLock(fixture.arena.allocator(), std.testing.io, lockPath));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Failed to check write lock for test-bucket/db/.db/write.lock: JSON Parse error"));
}
