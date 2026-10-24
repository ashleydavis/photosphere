//
// Tests for the write locks of FileStorage.
//

const test_files = @import("test-files.zig");
const std = @import("std");
const builtin = @import("builtin");
const storage_zig = @import("storage-zig");
const node_utils = @import("node-utils-zig");
const utils = @import("utils-zig");

const FileStorage = storage_zig.file_storage.FileStorage;
const LockFileContent = storage_zig.storage.LockFileContent;
const parseISOString = storage_zig.storage.parseISOString;
const pathExists = node_utils.fs.pathExists;
const thread_messages = @import("../../../utils-zig/src/test/thread-messages.zig");
const MessageQueue = thread_messages.MessageQueue;
const ThreadAllocator = thread_messages.ThreadAllocator;

//
// The fixture every test works on: a file storage and a directory of the test's own.
//
const Fixture = struct {
    // The arena for the test.
    arena: std.heap.ArenaAllocator,

    // The storage under test.
    storage: FileStorage,

    // The temporary directory.
    tempDir: []const u8,

    //
    // Creates the fixture.
    //
    fn init(fixture: *Fixture) !void {
        fixture.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        fixture.tempDir = try test_files.makeTempDir(fixture.arena.allocator(), std.testing.io, "temp-test-locks");
        fixture.storage = FileStorage.init(fixture.tempDir);
    }

    //
    // Deletes the temporary directory and frees the arena.
    //
    fn deinit(fixture: *Fixture) void {
        test_files.removeTempDir(std.testing.io, fixture.tempDir);
        fixture.arena.deinit();
    }

    //
    // Gets a path inside the temporary directory.
    //
    fn path(fixture: *Fixture, relativePath: []const u8) ![]const u8 {
        return std.fs.path.join(fixture.arena.allocator(), &.{ fixture.tempDir, relativePath });
    }

    //
    // Reads and parses a lock file.
    //
    fn readLockFile(fixture: *Fixture, lockFilePath: []const u8) !LockFileContent {
        const allocator = fixture.arena.allocator();
        const lockContent = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, lockFilePath, allocator, .unlimited);
        return std.json.parseFromSliceLeaky(LockFileContent, allocator, lockContent, .{ .allocate = .alloc_always });
    }
};

test "should return undefined for non-existent lock" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const filePath = try fixture.path("test-file-1.txt");
    const lockInfo = try fixture.storage.checkWriteLock(fixture.arena.allocator(), std.testing.io, filePath);
    try std.testing.expect(lockInfo == null);
}

test "should return lock info for existing lock" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const owner = "user123";
    const filePath = try fixture.path("test-file-2.txt");

    _ = try fixture.storage.acquireWriteLock(allocator, std.testing.io, filePath, owner);

    const lockInfo = try fixture.storage.checkWriteLock(allocator, std.testing.io, filePath);
    try std.testing.expect(lockInfo != null);
    try std.testing.expectEqualStrings(owner, lockInfo.?.owner);
    try std.testing.expect(lockInfo.?.acquiredAt.epochMilliseconds > 0);
}

test "should handle corrupted lock files gracefully" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const filePath = try fixture.path("test-file-3.txt");

    // Create an invalid JSON lock file (at the path that is checked)
    try test_files.writeFile(std.testing.io, filePath, "invalid json");

    const lockInfo = try fixture.storage.checkWriteLock(fixture.arena.allocator(), std.testing.io, filePath);
    try std.testing.expect(lockInfo == null);
}

test "should handle missing lock files gracefully" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const filePath = try fixture.path("non/existent/file-4.txt");

    const lockInfo = try fixture.storage.checkWriteLock(fixture.arena.allocator(), std.testing.io, filePath);
    try std.testing.expect(lockInfo == null);
}

test "should successfully acquire a lock for new file" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const owner = "user123";
    const lockFilePath = try fixture.path("test-file-5.txt.lock");

    const result = try fixture.storage.acquireWriteLock(fixture.arena.allocator(), std.testing.io, lockFilePath, owner);
    try std.testing.expect(result);

    // Verify lock file was created
    try std.testing.expect(pathExists(std.testing.io, lockFilePath));

    // Verify lock content
    const lockData = try fixture.readLockFile(lockFilePath);
    try std.testing.expectEqualStrings(owner, lockData.owner);
    try std.testing.expect(lockData.acquiredAt.len > 0);
}

test "should fail to acquire lock if one already exists" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const lockFilePath = try fixture.path("test-file-6.txt.lock");

    const firstResult = try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockFilePath, "user1");
    try std.testing.expect(firstResult);

    const secondResult = try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockFilePath, "user2");
    try std.testing.expect(!secondResult);
}

test "should create lock file in nested directories" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const lockFilePath = try fixture.path("nested/dir/test-file-7.txt.lock");
    const owner = "user123";

    const result = try fixture.storage.acquireWriteLock(fixture.arena.allocator(), std.testing.io, lockFilePath, owner);
    try std.testing.expect(result);

    try std.testing.expect(pathExists(std.testing.io, lockFilePath));
}

//
// One attempt of a race, as the test keeps it: the attempt runs on a thread of its own with its own storage instance (see
// runAttempts), and the test records here whether it won.
//
const LockAttempt = struct {
    // The lock owner of this attempt.
    owner: []const u8,

    // Whether the attempt acquired the lock.
    success: bool = false,

    // How long the attempt waits before it starts, in microseconds.
    delayMicroseconds: u64 = 0,

    //
    // What an attempt's thread is given.
    //
    const Order = struct {
        // The attempt's place in the test's list.
        index: usize,

        // The directory of the storage.
        root: []const u8,

        // The lock file.
        lockFilePath: []const u8,

        // The lock owner.
        owner: []const u8,

        // How long the attempt waits before it starts, in microseconds.
        delayMicroseconds: u64,
    };

    //
    // What an attempt's thread tells the test.
    //
    const Outcome = struct {
        // The attempt's place in the test's list.
        index: usize,

        // Whether the attempt acquired the lock.
        success: bool,
    };

    //
    // An attempt's thread: makes its own allocator, Io and storage instance, takes its order, acquires the lock and tells the test
    // whether it won.
    //
    fn run(orders: *MessageQueue, outcomes: *MessageQueue) void {
        var thread_allocator: ThreadAllocator = .init;
        defer thread_allocator.deinit();
        var arena_state = std.heap.ArenaAllocator.init(thread_allocator.allocator());
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var threaded: std.Io.Threaded = .init_single_threaded;
        threaded.allocator = thread_allocator.allocator();
        defer threaded.deinit();
        const io = threaded.io();
        const order = thread_messages.take(Order, orders, io, arena) catch |err| @panic(@errorName(err));
        if (order.delayMicroseconds > 0) {
            io.sleep(.fromNanoseconds(@intCast(order.delayMicroseconds * std.time.ns_per_us)), .awake) catch |err| @panic(@errorName(err));
        }
        var storage = FileStorage.init(order.root);
        const success = storage.acquireWriteLock(arena, io, order.lockFilePath, order.owner) catch false;
        thread_messages.post(outcomes, io, arena, Outcome{
            .index = order.index,
            .success = success,
        }) catch |err| @panic(@errorName(err));
    }
};

//
// Runs every attempt at once, each on a thread of its own with its own storage instance of the directory, and records whether each
// won.
//
fn runAttempts(allocator: std.mem.Allocator, root: []const u8, lockFilePath: []const u8, attempts: []LockAttempt) !void {
    const io = std.testing.io;
    const orders = try allocator.alloc(MessageQueue, attempts.len);
    for (orders) |*queue| {
        queue.* = MessageQueue.init();
    }
    defer {
        for (orders) |*queue| {
            queue.deinit();
        }
    }
    var outcomes = MessageQueue.init();
    defer outcomes.deinit();
    const threads = try allocator.alloc(std.Thread, attempts.len);
    for (attempts, orders, threads, 0..) |attempt, *queue, *thread, index| {
        try thread_messages.post(queue, io, allocator, LockAttempt.Order{
            .index = index,
            .root = root,
            .lockFilePath = lockFilePath,
            .owner = attempt.owner,
            .delayMicroseconds = attempt.delayMicroseconds,
        });
        thread.* = try std.Thread.spawn(.{}, LockAttempt.run, .{ queue, &outcomes });
    }
    for (threads) |thread| {
        thread.join();
    }
    for (attempts) |_| {
        const outcome = try thread_messages.take(LockAttempt.Outcome, &outcomes, io, allocator);
        attempts[outcome.index].success = outcome.success;
    }
}

test "should handle race conditions properly" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const lockFilePath = try fixture.path("test-file-8.txt.lock");

    // Create multiple storage instances to simulate different processes
    var attempts = [_]LockAttempt{
        .{
            .owner = "user1",
        },
        .{
            .owner = "user2",
        },
        .{
            .owner = "user3",
        },
    };

    try runAttempts(allocator, fixture.tempDir, lockFilePath, &attempts);

    // Only one should succeed
    var successCount: u32 = 0;
    for (attempts) |attempt| {
        if (attempt.success) {
            successCount += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 1), successCount);

    // Verify only one lock file exists
    try std.testing.expect(pathExists(std.testing.io, lockFilePath));

    // Verify the lock has one of the expected owners
    const lockInfo = try fixture.storage.checkWriteLock(allocator, std.testing.io, lockFilePath);
    try std.testing.expect(lockInfo != null);
    var ownerFound = false;
    for (attempts) |attempt| {
        if (attempt.success and std.mem.eql(u8, attempt.owner, lockInfo.?.owner)) {
            ownerFound = true;
        }
    }
    try std.testing.expect(ownerFound);
}

test "should handle aggressive race conditions with many concurrent attempts" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const lockFilePath = try fixture.path("race-test-file.txt.lock");
    const numAttempts = 50;

    // Create many storage instances
    const attempts = try allocator.alloc(LockAttempt, numAttempts);
    for (attempts, 0..) |*attempt, index| {
        attempt.* = .{
            .owner = try std.fmt.allocPrint(allocator, "user-{d}", .{index}),
        };
    }

    try runAttempts(allocator, fixture.tempDir, lockFilePath, attempts);

    // Exactly one should succeed
    var successCount: usize = 0;
    var winner: []const u8 = "";
    for (attempts) |attempt| {
        if (attempt.success) {
            successCount += 1;
            winner = attempt.owner;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), successCount);

    // All others should fail
    try std.testing.expectEqual(@as(usize, numAttempts - 1), attempts.len - successCount);

    // Verify the lock exists and belongs to the successful user
    const lockInfo = try fixture.storage.checkWriteLock(allocator, std.testing.io, lockFilePath);
    try std.testing.expect(lockInfo != null);
    try std.testing.expectEqualStrings(winner, lockInfo.?.owner);

    // Verify only one lock file exists
    try std.testing.expect(pathExists(std.testing.io, lockFilePath));
}

test "should handle race conditions with realistic timing delays" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();

    // This test repeats the race condition multiple times to increase the chance of catching timing-related bugs
    const numTests = 10;
    var testRun: usize = 0;
    while (testRun < numTests) : (testRun += 1) {
        const lockFilePath = try fixture.path(try std.fmt.allocPrint(allocator, "race-timing-test-{d}.txt.lock", .{testRun}));
        const numAttempts = 20;

        const attempts = try allocator.alloc(LockAttempt, numAttempts);
        for (attempts, 0..) |*attempt, index| {
            // Add small random delays to create more realistic race conditions (0 to 2ms)
            var randomBytes: [2]u8 = undefined;
            std.testing.io.random(&randomBytes);
            attempt.* = .{
                .owner = try std.fmt.allocPrint(allocator, "test{d}-user{d}", .{ testRun, index }),
                .delayMicroseconds = @as(u64, std.mem.readInt(u16, &randomBytes, .little)) % 2000,
            };
        }

        try runAttempts(allocator, fixture.tempDir, lockFilePath, attempts);

        // Exactly one should succeed in each test run
        var successCount: usize = 0;
        var winner: []const u8 = "";
        for (attempts) |attempt| {
            if (attempt.success) {
                successCount += 1;
                winner = attempt.owner;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), successCount);

        // Verify the winner has a valid lock
        const lockInfo = try fixture.storage.checkWriteLock(allocator, std.testing.io, lockFilePath);
        try std.testing.expect(lockInfo != null);
        try std.testing.expectEqualStrings(winner, lockInfo.?.owner);

        // Clean up for next iteration
        try fixture.storage.releaseWriteLock(allocator, std.testing.io, lockFilePath);
    }
}

test "should demonstrate atomic lock file creation prevents race conditions" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const lockFilePath = try fixture.path("atomic-test-file.txt.lock");

    // First process acquires lock normally
    const firstResult = try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockFilePath, "first-user");
    try std.testing.expect(firstResult);

    // Second process tries to acquire - should fail due to existing lock
    const secondResult = try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockFilePath, "second-user");
    try std.testing.expect(!secondResult);

    // Verify the first user still owns the lock
    const lockInfo = try fixture.storage.checkWriteLock(allocator, std.testing.io, lockFilePath);
    try std.testing.expectEqualStrings("first-user", lockInfo.?.owner);

    // Verify only one lock file exists (no corruption from failed attempts)
    const lockData = try fixture.readLockFile(lockFilePath);
    try std.testing.expectEqualStrings("first-user", lockData.owner);
}

test "should store timestamp accurately" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const lockFilePath = try fixture.path("test-file-10.txt.lock");
    const owner = "user123";
    const beforeTime = std.Io.Clock.real.now(std.testing.io).toMilliseconds();

    // Wait a small amount to ensure timestamp precision
    try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    _ = try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockFilePath, owner);
    try std.testing.io.sleep(.fromMilliseconds(1), .awake);

    const afterTime = std.Io.Clock.real.now(std.testing.io).toMilliseconds();
    const lockInfo = try fixture.storage.checkWriteLock(allocator, std.testing.io, lockFilePath);

    try std.testing.expect(lockInfo != null);
    try std.testing.expect(lockInfo.?.acquiredAt.epochMilliseconds >= beforeTime);
    try std.testing.expect(lockInfo.?.acquiredAt.epochMilliseconds <= afterTime);
}

test "should successfully release an existing lock" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const lockFilePath = try fixture.path("test-file-11.txt.lock");
    const owner = "user123";

    _ = try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockFilePath, owner);
    try std.testing.expect((try fixture.storage.checkWriteLock(allocator, std.testing.io, lockFilePath)) != null);

    try fixture.storage.releaseWriteLock(allocator, std.testing.io, lockFilePath);
    try std.testing.expect((try fixture.storage.checkWriteLock(allocator, std.testing.io, lockFilePath)) == null);

    // Verify lock file was deleted
    try std.testing.expect(!pathExists(std.testing.io, lockFilePath));
}

test "should handle releasing non-existent lock gracefully" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const lockFilePath = try fixture.path("non-existent-file-12.txt.lock");

    // Should not throw error
    try fixture.storage.releaseWriteLock(fixture.arena.allocator(), std.testing.io, lockFilePath);
}

test "should allow reacquisition after release" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const lockFilePath = try fixture.path("test-file-14.txt.lock");

    // Acquire, release, then acquire again
    try std.testing.expect(try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockFilePath, "user1"));
    try fixture.storage.releaseWriteLock(allocator, std.testing.io, lockFilePath);
    try std.testing.expect(try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockFilePath, "user2"));

    // Verify new owner
    const lockInfo = try fixture.storage.checkWriteLock(allocator, std.testing.io, lockFilePath);
    try std.testing.expectEqualStrings("user2", lockInfo.?.owner);
}

test "should create valid JSON lock files" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const lockFilePath = try fixture.path("test-file-15.txt.lock");
    const owner = "user123";

    _ = try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockFilePath, owner);

    // Should be valid JSON
    const lockData = try fixture.readLockFile(lockFilePath);
    try std.testing.expectEqualStrings(owner, lockData.owner);

    // acquiredAt should be a valid ISO date string
    const acquiredAt = parseISOString(lockData.acquiredAt).?;
    try std.testing.expectEqualStrings(lockData.acquiredAt, try acquiredAt.toISOString(allocator));

    // The keys are in the order JSON.stringify writes them.
    const lockContent = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, lockFilePath, allocator, .unlimited);
    const expected = try utils.json.stringify(allocator, .{
        .owner = "user123",
        .acquiredAt = lockData.acquiredAt,
        .timestamp = lockData.timestamp,
    });
    try std.testing.expectEqualStrings(expected, lockContent);
}

test "should handle special characters in owner names" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const lockFilePath = try fixture.path("test-file-16.txt.lock");
    const specialOwner = "user@domain.com with spaces & symbols!";

    _ = try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockFilePath, specialOwner);

    const lockInfo = try fixture.storage.checkWriteLock(allocator, std.testing.io, lockFilePath);
    try std.testing.expectEqualStrings(specialOwner, lockInfo.?.owner);
}

test "should handle full lock lifecycle" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const lockFilePath = try fixture.path("important-file-17.txt.lock");
    const owner = "critical-process";

    // 1. No lock initially
    try std.testing.expect((try fixture.storage.checkWriteLock(allocator, std.testing.io, lockFilePath)) == null);

    // 2. Acquire lock
    try std.testing.expect(try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockFilePath, owner));

    // 3. Verify lock exists and has correct details
    const lockInfo = try fixture.storage.checkWriteLock(allocator, std.testing.io, lockFilePath);
    try std.testing.expectEqualStrings(owner, lockInfo.?.owner);

    // 4. Other processes cannot acquire lock
    try std.testing.expect(!try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockFilePath, "other-process"));

    // 5. Release lock
    try fixture.storage.releaseWriteLock(allocator, std.testing.io, lockFilePath);

    // 6. Lock is gone
    try std.testing.expect((try fixture.storage.checkWriteLock(allocator, std.testing.io, lockFilePath)) == null);

    // 7. Other processes can now acquire lock
    try std.testing.expect(try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockFilePath, "other-process"));
}

test "should work with complex file paths" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const complexPaths = [_][]const u8{
        "simple-18.txt.lock",
        "path/with/slashes-19.txt.lock",
        "path/with spaces/file-20.txt.lock",
        "path/with-special_chars@123-21.txt.lock",
        "very/deep/nested/path/structure/file-22.txt.lock",
    };

    for (complexPaths) |relativePath| {
        const lockFilePath = try fixture.path(relativePath);
        const owner = try std.mem.concat(allocator, u8, &.{ "owner-", relativePath });

        try std.testing.expect(try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockFilePath, owner));

        const lockInfo = try fixture.storage.checkWriteLock(allocator, std.testing.io, lockFilePath);
        try std.testing.expectEqualStrings(owner, lockInfo.?.owner);

        try fixture.storage.releaseWriteLock(allocator, std.testing.io, lockFilePath);
        try std.testing.expect((try fixture.storage.checkWriteLock(allocator, std.testing.io, lockFilePath)) == null);
    }
}

test "a lock older than the timeout is broken and taken" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const lockFilePath = try fixture.path("stale.lock");
    const staleTimestamp = std.Io.Clock.real.now(std.testing.io).toMilliseconds() - 60_000;
    try test_files.writeFile(std.testing.io, lockFilePath, try utils.json.stringify(allocator, .{
        .owner = "old-owner",
        .acquiredAt = "2020-01-01T00:00:00.000Z",
        .timestamp = staleTimestamp,
    }));

    try std.testing.expect(try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockFilePath, "new-owner"));

    const lockInfo = try fixture.storage.checkWriteLock(allocator, std.testing.io, lockFilePath);
    try std.testing.expectEqualStrings("new-owner", lockInfo.?.owner);
}

test "a corrupted lock file is broken and the lock taken" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const lockFilePath = try fixture.path("corrupt.lock");
    try test_files.writeFile(std.testing.io, lockFilePath, "invalid json");

    try std.testing.expect(try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockFilePath, "new-owner"));

    const lockInfo = try fixture.storage.checkWriteLock(allocator, std.testing.io, lockFilePath);
    try std.testing.expectEqualStrings("new-owner", lockInfo.?.owner);
}

//
// An empty lock file is what another owner's exclusive create leaves before it writes the lock.
// Breaking it as corrupt put two owners in the critical section at once.
//
test "an empty lock file that was just created is held, not broken" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const lockFilePath = try fixture.path("being-written.lock");
    try test_files.writeFile(std.testing.io, lockFilePath, "");

    try std.testing.expect(!try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockFilePath, "new-owner"));

    const lockContent = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, lockFilePath, allocator, .unlimited);
    try std.testing.expectEqualStrings("", lockContent);
}

//
// An empty lock file older than the lock timeout was left by an owner that died before writing
// it, so it is broken like any other corrupt lock.
//
test "an empty lock file older than the lock timeout is broken and the lock taken" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const lockFilePath = try fixture.path("abandoned.lock");
    try test_files.writeFile(std.testing.io, lockFilePath, "");
    const lockFile = try std.Io.Dir.cwd().openFile(std.testing.io, lockFilePath, .{ .mode = .read_write });
    defer lockFile.close(std.testing.io);
    const staleTime = std.Io.Clock.real.now(std.testing.io).toMilliseconds() - 60_000;
    try lockFile.setTimestamps(std.testing.io, .{
        .modify_timestamp = .{ .new = std.Io.Timestamp.fromNanoseconds(@as(i96, staleTime) * std.time.ns_per_ms) },
    });

    try std.testing.expect(try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockFilePath, "new-owner"));

    const lockInfo = try fixture.storage.checkWriteLock(allocator, std.testing.io, lockFilePath);
    try std.testing.expectEqualStrings("new-owner", lockInfo.?.owner);
}

test "parseISOString reads what toISOString writes and rejects anything else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The milliseconds since the epoch that each text stands for.
    try std.testing.expectEqual(@as(i64, 0), parseISOString("1970-01-01T00:00:00.000Z").?.epochMilliseconds);
    try std.testing.expectEqual(@as(i64, 1709251199999), parseISOString("2024-02-29T23:59:59.999Z").?.epochMilliseconds);
    try std.testing.expectEqual(@as(i64, 1000000000123), parseISOString("2001-09-09T01:46:40.123Z").?.epochMilliseconds);
    try std.testing.expectEqual(@as(i64, -1), parseISOString("1969-12-31T23:59:59.999Z").?.epochMilliseconds);
    try std.testing.expectEqualStrings("2026-09-25T01:02:03.456Z", try parseISOString("2026-09-25T01:02:03.456Z").?.toISOString(allocator));
    try std.testing.expect(parseISOString("invalid") == null);
    try std.testing.expect(parseISOString("2026-13-25T01:02:03.456Z") == null);
    try std.testing.expect(parseISOString("2026-09-25 01:02:03.456Z") == null);
}

//
// The lock is read with its content trimmed, and the trim removes a byte order mark
// and the Unicode spaces as well as ASCII whitespace, so such a lock is read and held rather than broken as corrupt.
//
test "a lock file surrounded by Unicode whitespace is read and held, not broken" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const lockFilePath = try fixture.path("bom.lock");
    const timestamp = std.Io.Clock.real.now(std.testing.io).toMilliseconds();
    try test_files.writeFile(std.testing.io, lockFilePath, try std.fmt.allocPrint(allocator, "\u{FEFF}{{\"owner\":\"first-owner\",\"acquiredAt\":\"2020-01-01T00:00:00.000Z\",\"timestamp\":{d}}}\u{3000}", .{timestamp}));

    try std.testing.expect(!try fixture.storage.acquireWriteLock(allocator, std.testing.io, lockFilePath, "second-owner"));

    const lockInfo = try fixture.storage.checkWriteLock(allocator, std.testing.io, lockFilePath);
    try std.testing.expectEqualStrings("first-owner", lockInfo.?.owner);
}

test "every step of taking a lock is written to the verbose log, and a lock that cannot be written is an error" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;

    // A log that asks for the [LOCK] lines and writes nothing.
    var verboseLog: utils.log.ConsoleLog = .{ .verbose_enabled = true };
    const previousLog = utils.log.currentLog();
    utils.log.setLog(verboseLog.ilog());
    defer utils.log.setLog(previousLog);

    // Taken, then refused while held.
    const lockFilePath = try fixture.path("verbose.lock");
    try std.testing.expect(try fixture.storage.acquireWriteLock(allocator, io, lockFilePath, "first"));
    try std.testing.expect(!try fixture.storage.acquireWriteLock(allocator, io, lockFilePath, "second"));

    // A stale lock and a corrupt one are broken; an empty one being written is left alone.
    const staleTimestamp = std.Io.Clock.real.now(io).toMilliseconds() - 60_000;
    const stalePath = try fixture.path("verbose-stale.lock");
    try test_files.writeFile(io, stalePath, try utils.json.stringify(allocator, .{
        .owner = "old",
        .acquiredAt = "2020-01-01T00:00:00.000Z",
        .timestamp = staleTimestamp,
    }));
    try std.testing.expect(try fixture.storage.acquireWriteLock(allocator, io, stalePath, "new"));
    const corruptPath = try fixture.path("verbose-corrupt.lock");
    try test_files.writeFile(io, corruptPath, "invalid json");
    try std.testing.expect(try fixture.storage.acquireWriteLock(allocator, io, corruptPath, "new"));
    const emptyPath = try fixture.path("verbose-empty.lock");
    try test_files.writeFile(io, emptyPath, "");
    try std.testing.expect(!try fixture.storage.acquireWriteLock(allocator, io, emptyPath, "new"));

    // A lock under a file cannot be created, and the error is passed on.
    try test_files.writeFile(io, try fixture.path("a-file"), "not a directory");
    try std.testing.expect(std.meta.isError(fixture.storage.acquireWriteLock(allocator, io, try fixture.path("a-file/under.lock"), "new")));
}

//
// A log that keeps every verbose message, so a test can read what the lock code said.
//
const RecordingLog = struct {
    // The verbose messages written.
    messages: std.Io.Writer.Allocating,

    // Whether verbose logging is on.
    verbose_enabled: bool,

    //
    // Gets the ILog interface for this log.
    //
    fn ilog(self: *RecordingLog) utils.log.ILog {
        return .{ .ptr = self, .vtable = &vtable };
    }

    //
    // Keeps a verbose message.
    //
    fn verbose(ptr: *anyopaque, message: []const u8) void {
        const self: *RecordingLog = @ptrCast(@alignCast(ptr));
        self.messages.writer.writeAll(message) catch {};
        self.messages.writer.writeByte('\n') catch {};
    }

    //
    // Ignores a message.
    //
    fn ignoreMessage(ptr: *anyopaque, message: []const u8) void {
        _ = ptr;
        _ = message;
    }

    //
    // Ignores an exception.
    //
    fn ignoreException(ptr: *anyopaque, message: []const u8, err: anyerror) void {
        _ = ptr;
        _ = message;
        _ = @errorName(err);
    }

    //
    // Ignores tool output.
    //
    fn ignoreTool(ptr: *anyopaque, toolName: []const u8, data: utils.log.IToolOutput) void {
        _ = ptr;
        _ = toolName;
        _ = data;
    }

    //
    // Returns whether verbose logging is enabled.
    //
    fn verboseEnabled(ptr: *anyopaque) bool {
        const self: *RecordingLog = @ptrCast(@alignCast(ptr));
        return self.verbose_enabled;
    }

    //
    // Returns no log details.
    //
    fn getLogDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!utils.log.ILogDetails {
        _ = ptr;
        _ = allocator;
        _ = io;
        return utils.log.noLogDetails;
    }

    //
    // The vtable that forwards to this log.
    //
    const vtable: utils.log.ILog.VTable = .{
        .info = ignoreMessage,
        .verbose = verbose,
        .@"error" = ignoreMessage,
        .exception = ignoreException,
        .warn = ignoreMessage,
        .debug = ignoreMessage,
        .tool = ignoreTool,
        .event = ignoreMessage,
        .verboseEnabled = verboseEnabled,
        .getLogDetails = getLogDetails,
    };
};

//
// The verbose log of a refused lock names the age of the lock and the owner holding it, so a caller can see who
// is in the way and for how long.
//
test "a refused lock is logged with the age and the owner of the lock in the way" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tempDir = try test_files.makeTempDir(allocator, io, "temp-test-lock-log");
    defer test_files.removeTempDir(io, tempDir);
    var storage = FileStorage.init(tempDir);

    var recordingLog: RecordingLog = .{
        .messages = std.Io.Writer.Allocating.init(allocator),
        .verbose_enabled = true,
    };
    const previousLog = utils.log.currentLog();
    utils.log.setLog(recordingLog.ilog());
    defer utils.log.setLog(previousLog);

    const lockFilePath = try std.fs.path.join(allocator, &.{ tempDir, "logged.lock" });
    try std.testing.expect(try storage.acquireWriteLock(allocator, io, lockFilePath, "first-owner"));
    try std.testing.expect(!try storage.acquireWriteLock(allocator, io, lockFilePath, "second-owner"));

    const messages = recordingLog.messages.written();
    try std.testing.expect(std.mem.indexOf(u8, messages, "ACQUIRE_ATTEMPT") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages, "ACQUIRE_FAILED_EXISTS") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages, "owner:first-owner") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages, "age:") != null);
}

//
// A lock file that is valid JSON but whose acquiredAt is not a date. parseLockContent refuses to read it,
// so the file reads as corrupt and the lock is broken.
//
test "a lock whose acquiredAt is not a date reads as corrupt and the lock is taken" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tempDir = try test_files.makeTempDir(allocator, io, "temp-test-lock-bad-date");
    defer test_files.removeTempDir(io, tempDir);
    var storage = FileStorage.init(tempDir);

    const lockFilePath = try std.fs.path.join(allocator, &.{ tempDir, "bad-date.lock" });
    try test_files.writeFile(io, lockFilePath, "{\"owner\":\"old-owner\",\"acquiredAt\":\"not a date\",\"timestamp\":1}");

    // The lock cannot be read as one.
    try std.testing.expect((try storage.checkWriteLock(allocator, io, lockFilePath)) == null);

    // So it is broken as corrupt and the lock is taken.
    try std.testing.expect(try storage.acquireWriteLock(allocator, io, lockFilePath, "new-owner"));
    const lockInfo = (try storage.checkWriteLock(allocator, io, lockFilePath)).?;
    try std.testing.expectEqualStrings("new-owner", lockInfo.owner);
}

test "refreshWriteLock updates the timestamp of a lock the owner holds and keeps the owner" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const lockFilePath = try fixture.path("refresh.lock");
    try std.testing.expect(try fixture.storage.acquireWriteLock(allocator, io, lockFilePath, "owner-1"));
    const before = try fixture.readLockFile(lockFilePath);

    try io.sleep(.fromMilliseconds(20), .awake);
    try fixture.storage.refreshWriteLock(allocator, io, lockFilePath, "owner-1");

    const after = try fixture.readLockFile(lockFilePath);
    try std.testing.expectEqualStrings("owner-1", after.owner);
    try std.testing.expect(after.timestamp > before.timestamp);
    const lockInfo = (try fixture.storage.checkWriteLock(allocator, io, lockFilePath)).?;
    try std.testing.expectEqualStrings("owner-1", lockInfo.owner);
}

test "refreshWriteLock fails when there is no lock" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const lockFilePath = try fixture.path("none.lock");

    try std.testing.expectError(error.Thrown, fixture.storage.refreshWriteLock(allocator, std.testing.io, lockFilePath, "owner-1"));
    const message = try std.fmt.allocPrint(allocator, "Cannot refresh write lock: lock does not exist for {s}", .{lockFilePath});
    try std.testing.expectEqualStrings(message, utils.errors.errorMessage(error.Thrown));
    try std.testing.expect(!pathExists(std.testing.io, lockFilePath));
}

test "refreshWriteLock fails when another owner holds the lock, and leaves the lock as it was" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const io = std.testing.io;
    const lockFilePath = try fixture.path("other.lock");
    try std.testing.expect(try fixture.storage.acquireWriteLock(allocator, io, lockFilePath, "owner-1"));
    const before = try fixture.readLockFile(lockFilePath);

    try std.testing.expectError(error.Thrown, fixture.storage.refreshWriteLock(allocator, io, lockFilePath, "owner-2"));
    const message = try std.fmt.allocPrint(allocator, "Cannot refresh write lock: lock is owned by owner-1, not owner-2 for {s}", .{lockFilePath});
    try std.testing.expectEqualStrings(message, utils.errors.errorMessage(error.Thrown));

    const after = try fixture.readLockFile(lockFilePath);
    try std.testing.expectEqualStrings("owner-1", after.owner);
    try std.testing.expectEqual(before.timestamp, after.timestamp);
}

test "refreshWriteLock logs the attempt, the success and the failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tempDir = try test_files.makeTempDir(allocator, io, "temp-test-refresh-log");
    defer test_files.removeTempDir(io, tempDir);
    var storage = FileStorage.init(tempDir);

    var recordingLog: RecordingLog = .{
        .messages = std.Io.Writer.Allocating.init(allocator),
        .verbose_enabled = true,
    };
    const previousLog = utils.log.currentLog();
    utils.log.setLog(recordingLog.ilog());
    defer utils.log.setLog(previousLog);

    const lockFilePath = try std.fs.path.join(allocator, &.{ tempDir, "logged-refresh.lock" });
    try std.testing.expect(try storage.acquireWriteLock(allocator, io, lockFilePath, "owner-1"));
    try storage.refreshWriteLock(allocator, io, lockFilePath, "owner-1");
    try std.testing.expectError(error.Thrown, storage.refreshWriteLock(allocator, io, lockFilePath, "owner-2"));

    const messages = recordingLog.messages.written();
    try std.testing.expect(std.mem.indexOf(u8, messages, "REFRESH_ATTEMPT") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages, "REFRESH_SUCCESS") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages, "REFRESH_FAILED") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages, "error:Cannot refresh write lock: lock is owned by owner-1, not owner-2") != null);
}

//
// Refuses its first allocation and serves every later one from the parent. (std.testing.FailingAllocator refuses
// every allocation from its fail index on, so it cannot make one read fail and the next succeed.)
//
const FailFirstAllocator = struct {
    // Serves the allocations after the first.
    parent: std.mem.Allocator,

    // True once the first allocation has been refused.
    refused: bool,

    fn allocator(self: *FailFirstAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *FailFirstAllocator = @ptrCast(@alignCast(context));
        if (!self.refused) {
            self.refused = true;
            return null;
        }
        return self.parent.rawAlloc(length, alignment, return_address);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_length: usize, return_address: usize) bool {
        const self: *FailFirstAllocator = @ptrCast(@alignCast(context));
        return self.parent.rawResize(memory, alignment, new_length, return_address);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_length: usize, return_address: usize) ?[*]u8 {
        const self: *FailFirstAllocator = @ptrCast(@alignCast(context));
        return self.parent.rawRemap(memory, alignment, new_length, return_address);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *FailFirstAllocator = @ptrCast(@alignCast(context));
        self.parent.rawFree(memory, alignment, return_address);
    }
};

//
// A lock that cannot be read the first time but can the second is a lock somebody holds, not a corrupt one,
// and must be left alone. Running out of memory while reading the lock is how a test makes the first read fail
// with nothing wrong with the file, and it is a real way for that read to fail.
//
test "a lock that is refused to be read once, and then reads fine, is held and not broken as corrupt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tempDir = try test_files.makeTempDir(allocator, io, "temp-test-lock-read-twice");
    defer test_files.removeTempDir(io, tempDir);
    var storage = FileStorage.init(tempDir);

    const lockFilePath = try std.fmt.allocPrint(allocator, "{s}/held.lock", .{tempDir});
    try std.testing.expect(try storage.acquireWriteLock(allocator, io, lockFilePath, "first-owner"));

    // The first allocation acquireWriteLock makes is the room to read the lock file into, and it is refused.
    var failFirstAllocator: FailFirstAllocator = .{
        .parent = allocator,
        .refused = false,
    };
    try std.testing.expect(!try storage.acquireWriteLock(failFirstAllocator.allocator(), io, lockFilePath, "second-owner"));
    try std.testing.expect(failFirstAllocator.refused);

    const lockInfo = (try storage.checkWriteLock(allocator, io, lockFilePath)).?;
    try std.testing.expectEqualStrings("first-owner", lockInfo.owner);
}

//
// createFile with the exclusive flag refuses a path that is a symbolic link, even one that points at nothing, so
// a lock path holding a dangling link looks absent to the check for an existing lock and is then refused by the
// exclusive create, which is the same refusal two processes racing to create the lock file get.
//
test "a lock path that is a dangling symbolic link is refused as taken, and the link is left alone" {
    if (builtin.os.tag == .windows) {
        // Creating a symbolic link on Windows needs a privilege a test run does not have.
        return error.SkipZigTest;
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tempDir = try test_files.makeTempDir(allocator, io, "temp-test-lock-dangling-link");
    defer test_files.removeTempDir(io, tempDir);
    var storage = FileStorage.init(tempDir);

    const lockFilePath = try std.fmt.allocPrint(allocator, "{s}/linked.lock", .{tempDir});
    try std.Io.Dir.cwd().symLink(io, "nothing-is-here", lockFilePath, .{});

    try std.testing.expect(!try storage.acquireWriteLock(allocator, io, lockFilePath, "new-owner"));

    var linkTarget: [64]u8 = undefined;
    const targetLength = try std.Io.Dir.cwd().readLink(io, lockFilePath, &linkTarget);
    try std.testing.expectEqualStrings("nothing-is-here", linkTarget[0..targetLength]);
}
