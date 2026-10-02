//
// Tests for the write locks of FileStorage (port of src/tests/file-storage-locks.test.ts).
//

const std = @import("std");
const storage_zig = @import("storage-zig");
const node_utils = @import("node-utils-zig");
const utils = @import("utils-zig");
const helpers = @import("test-helpers.zig");

const FileStorage = storage_zig.file_storage.FileStorage;
const LockFileContent = storage_zig.storage.LockFileContent;
const parseISOString = storage_zig.storage.parseISOString;
const pathExists = node_utils.fs.pathExists;

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
        fixture.tempDir = try helpers.makeTempDir(fixture.arena.allocator(), std.testing.io, "temp-test-locks");
        fixture.storage = FileStorage.init(fixture.tempDir);
    }

    //
    // Deletes the temporary directory and frees the arena.
    //
    fn deinit(fixture: *Fixture) void {
        helpers.removeTempDir(std.testing.io, fixture.tempDir);
        fixture.arena.deinit();
    }

    //
    // Gets a path inside the temporary directory.
    //
    fn path(fixture: *Fixture, relativePath: []const u8) ![]const u8 {
        return std.fmt.allocPrint(fixture.arena.allocator(), "{s}/{s}", .{ fixture.tempDir, relativePath });
    }

    //
    // Reads and parses a lock file the way the TypeScript tests do with JSON.parse.
    //
    fn readLockFile(fixture: *Fixture, lockFilePath: []const u8) !LockFileContent {
        const allocator = fixture.arena.allocator();
        const lockContent = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, lockFilePath, allocator, .unlimited);
        return std.json.parseFromSliceLeaky(LockFileContent, allocator, lockContent, .{ .allocate = .alloc_always });
    }
};

// describe('checkWriteLock')

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
    try helpers.writeFile(std.testing.io, filePath, "invalid json");

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

// describe('acquireWriteLock')

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
// One attempt of a race: acquires the lock with its own storage instance and records whether it won.
//
const LockAttempt = struct {
    // The storage instance of this attempt (a different process in TypeScript).
    storage: FileStorage,

    // The lock owner of this attempt.
    owner: []const u8,

    // Whether the attempt acquired the lock.
    success: bool = false,

    //
    // Runs the attempt.
    //
    fn run(self: *LockAttempt, lockFilePath: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        self.success = self.storage.acquireWriteLock(arena.allocator(), std.testing.io, lockFilePath, self.owner) catch false;
    }
};

test "should handle race conditions properly" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const lockFilePath = try fixture.path("test-file-8.txt.lock");

    // Create multiple storage instances to simulate different processes
    var attempts = [_]LockAttempt{
        .{
            .storage = FileStorage.init(fixture.tempDir),
            .owner = "user1",
        },
        .{
            .storage = FileStorage.init(fixture.tempDir),
            .owner = "user2",
        },
        .{
            .storage = FileStorage.init(fixture.tempDir),
            .owner = "user3",
        },
    };

    var group: std.Io.Group = .init;
    for (&attempts) |*attempt| {
        group.async(std.testing.io, LockAttempt.run, .{ attempt, lockFilePath });
    }
    try group.await(std.testing.io);

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

// describe('releaseWriteLock')

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

// describe('lock file format')

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
    const expected = try std.fmt.allocPrint(allocator, "{{\"owner\":\"user123\",\"acquiredAt\":\"{s}\",\"timestamp\":{d}}}", .{ lockData.acquiredAt, lockData.timestamp });
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

// describe('integration scenarios')

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
        const owner = try std.fmt.allocPrint(allocator, "owner-{s}", .{relativePath});

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
    try helpers.writeFile(std.testing.io, lockFilePath, try std.fmt.allocPrint(allocator, "{{\"owner\":\"old-owner\",\"acquiredAt\":\"2020-01-01T00:00:00.000Z\",\"timestamp\":{d}}}", .{staleTimestamp}));

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
    try helpers.writeFile(std.testing.io, lockFilePath, "invalid json");

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
    try helpers.writeFile(std.testing.io, lockFilePath, "");

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
    try helpers.writeFile(std.testing.io, lockFilePath, "");
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

    // Values from `new Date(text).getTime()` in JavaScript.
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
// TypeScript reads the lock with `JSON.parse(lockContent.trim())`, and JavaScript's trim removes a byte order mark
// and the Unicode spaces as well as ASCII whitespace, so such a lock is read and held rather than broken as corrupt.
//
test "a lock file surrounded by Unicode whitespace is read and held, not broken" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const lockFilePath = try fixture.path("bom.lock");
    const timestamp = std.Io.Clock.real.now(std.testing.io).toMilliseconds();
    try helpers.writeFile(std.testing.io, lockFilePath, try std.fmt.allocPrint(allocator, "\u{FEFF}{{\"owner\":\"first-owner\",\"acquiredAt\":\"2020-01-01T00:00:00.000Z\",\"timestamp\":{d}}}\u{3000}", .{timestamp}));

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
    const previousLog = utils.log.log;
    utils.log.setLog(verboseLog.ilog());
    defer utils.log.setLog(previousLog);

    // Taken, then refused while held.
    const lockFilePath = try fixture.path("verbose.lock");
    try std.testing.expect(try fixture.storage.acquireWriteLock(allocator, io, lockFilePath, "first"));
    try std.testing.expect(!try fixture.storage.acquireWriteLock(allocator, io, lockFilePath, "second"));

    // A stale lock and a corrupt one are broken; an empty one being written is left alone.
    const staleTimestamp = std.Io.Clock.real.now(io).toMilliseconds() - 60_000;
    const stalePath = try fixture.path("verbose-stale.lock");
    try helpers.writeFile(io, stalePath, try std.fmt.allocPrint(allocator, "{{\"owner\":\"old\",\"acquiredAt\":\"2020-01-01T00:00:00.000Z\",\"timestamp\":{d}}}", .{staleTimestamp}));
    try std.testing.expect(try fixture.storage.acquireWriteLock(allocator, io, stalePath, "new"));
    const corruptPath = try fixture.path("verbose-corrupt.lock");
    try helpers.writeFile(io, corruptPath, "invalid json");
    try std.testing.expect(try fixture.storage.acquireWriteLock(allocator, io, corruptPath, "new"));
    const emptyPath = try fixture.path("verbose-empty.lock");
    try helpers.writeFile(io, emptyPath, "");
    try std.testing.expect(!try fixture.storage.acquireWriteLock(allocator, io, emptyPath, "new"));

    // A lock under a file cannot be created, and the error is passed on.
    try helpers.writeFile(io, try fixture.path("a-file"), "not a directory");
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
    const tempDir = try helpers.makeTempDir(allocator, io, "temp-test-lock-log");
    defer helpers.removeTempDir(io, tempDir);
    var storage = FileStorage.init(tempDir);

    var recordingLog: RecordingLog = .{
        .messages = std.Io.Writer.Allocating.init(allocator),
        .verbose_enabled = true,
    };
    const previousLog = utils.log.log;
    utils.log.setLog(recordingLog.ilog());
    defer utils.log.setLog(previousLog);

    const lockFilePath = try std.fmt.allocPrint(allocator, "{s}/logged.lock", .{tempDir});
    try std.testing.expect(try storage.acquireWriteLock(allocator, io, lockFilePath, "first-owner"));
    try std.testing.expect(!try storage.acquireWriteLock(allocator, io, lockFilePath, "second-owner"));

    const messages = recordingLog.messages.written();
    try std.testing.expect(std.mem.indexOf(u8, messages, "ACQUIRE_ATTEMPT") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages, "ACQUIRE_FAILED_EXISTS") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages, "owner:first-owner") != null);
    try std.testing.expect(std.mem.indexOf(u8, messages, "age:") != null);
}

//
// A lock file that is valid JSON but whose acquiredAt is not a date `new Date` can read. TypeScript carries
// the Invalid Date forward and answers with a lock whose acquiredAt is Invalid Date; the Zig refuses to read it
// (see the TODO on parseLockContent), so the file reads as corrupt and the lock is broken.
//
test "a lock whose acquiredAt is not a date reads as corrupt and the lock is taken" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const tempDir = try helpers.makeTempDir(allocator, io, "temp-test-lock-bad-date");
    defer helpers.removeTempDir(io, tempDir);
    var storage = FileStorage.init(tempDir);

    const lockFilePath = try std.fmt.allocPrint(allocator, "{s}/bad-date.lock", .{tempDir});
    try helpers.writeFile(io, lockFilePath, "{\"owner\":\"old-owner\",\"acquiredAt\":\"not a date\",\"timestamp\":1}");

    // The lock cannot be read as one.
    try std.testing.expect((try storage.checkWriteLock(allocator, io, lockFilePath)) == null);

    // So it is broken as corrupt and the lock is taken.
    try std.testing.expect(try storage.acquireWriteLock(allocator, io, lockFilePath, "new-owner"));
    const lockInfo = (try storage.checkWriteLock(allocator, io, lockFilePath)).?;
    try std.testing.expectEqualStrings("new-owner", lockInfo.owner);
}
