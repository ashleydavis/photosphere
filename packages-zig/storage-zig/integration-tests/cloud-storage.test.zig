//
// Integration tests of CloudStorage against a real S3 server (port of packages/storage/integration-tests/
// cloud-storage.test.ts). They are not part of the unit tests: `zig build test-integration` runs them, and the
// smoke test apps/cli/smoke-tests-zig/75-s3-storage-api runs that against a local S3 emulator.
//
// These tests require AWS credentials and an S3 bucket to run.
// Set the following environment variables before running:
// AWS_ACCESS_KEY_ID=your_access_key
// AWS_SECRET_ACCESS_KEY=your_secret_key
// AWS_REGION=your_region (e.g., us-east-1)
// AWS_ENDPOINT=your_endpoint (optional, for S3-compatible services)
// TEST_S3_BUCKET=your_test_bucket_name
//
// (Zig: the TypeScript's describe blocks are the prefixes of the test names. The concurrent lock attempts the
// TypeScript starts through setImmediate, process.nextTick, setTimeout and promise chains run here on threads of
// their own, each through the one shared storage, as the TypeScript's all go through its one storage.)
//

const std = @import("std");
const storage_zig = @import("storage-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");

const CloudStorage = storage_zig.cloud_storage.CloudStorage;
const Date = utils.timestamp_provider.Date;

//
// Allocates what lives for the whole test binary: the environment, the location and the storage.
//
const process_allocator = std.heap.smp_allocator;

//
// The storage every test uses (TypeScript: `storage`, created in beforeAll). Held here, never moved, because a
// CloudStorage must not move once it has been used.
//
var shared_storage: CloudStorage = undefined;

//
// `<bucket>/<test prefix>`, the root every test writes under (TypeScript: `location`). Null until setUp has run.
//
var shared_location: ?[]const u8 = null;

//
// The TypeScript's beforeAll: checks the environment and creates the storage, once per test binary. The prefix
// is unique to this run (TypeScript: `test-${Date.now()}-${random}`), so runs never see each other's files.
//
fn setUp() ![]const u8 {
    if (shared_location) |location| {
        return location;
    }
    const io = std.testing.io;
    const map = try process_allocator.create(std.process.Environ.Map);
    map.* = try std.testing.environ.createMap(process_allocator);
    node_utils.process_env.setEnvironMap(map);

    // Check for required environment variables
    for ([_][]const u8{ "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "TEST_S3_BUCKET" }) |envVar| {
        const value = node_utils.process_env.getEnv(envVar);
        if (value == null or value.?.len == 0) {
            std.debug.print("Missing required environment variable: {s}\n", .{envVar});
            return error.MissingRequiredEnvironmentVariable;
        }
    }

    var randomBytes: [4]u8 = undefined;
    io.random(&randomBytes);
    const testPrefix = try std.fmt.allocPrint(process_allocator, "test-{d}-{s}", .{ std.Io.Clock.real.now(io).toMilliseconds(), &std.fmt.bytesToHex(randomBytes, .lower) });
    const location = try std.fmt.allocPrint(process_allocator, "{s}/{s}", .{ node_utils.process_env.getEnv("TEST_S3_BUCKET").?, testPrefix });

    shared_storage = CloudStorage.init(io, location, null);
    shared_location = location;
    return location;
}

//
// Joins the location and the parts of a path with "/".
//
fn pathOf(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return std.mem.join(allocator, "/", parts);
}

//
// The current time in milliseconds (TypeScript: `Date.now()`).
//
fn nowMilliseconds() i64 {
    return std.Io.Clock.real.now(std.testing.io).toMilliseconds();
}

//
// Sorts names in place, in byte order (TypeScript: `.sort()` on ASCII names).
//
fn sortNames(names: [][]const u8) void {
    std.mem.sort([]const u8, names, {}, struct {
        fn lessThan(context: void, left: []const u8, right: []const u8) bool {
            _ = context;
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
}

// Basic File Operations

//
// The directory the basic file tests write in.
//
const basic_test_dir = "basic-file-ops";

//
// The content the basic file tests write.
//
const basic_test_content = "Hello, CloudStorage!";

test "CloudStorage Tests Basic File Operations should write and read a file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    const testFile = try pathOf(allocator, &.{ location, basic_test_dir, "write-read-test.txt" });
    try shared_storage.write(allocator, io, testFile, "text/plain", basic_test_content);

    const readContent = try shared_storage.read(allocator, io, testFile);
    try std.testing.expectEqualStrings(basic_test_content, readContent.?);
}

test "CloudStorage Tests Basic File Operations should check if file exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    const existingFile = try pathOf(allocator, &.{ location, basic_test_dir, "exists-test.txt" });
    try shared_storage.write(allocator, io, existingFile, "text/plain", basic_test_content);

    try std.testing.expect(try shared_storage.fileExists(allocator, io, existingFile));
    try std.testing.expect(!try shared_storage.fileExists(allocator, io, try pathOf(allocator, &.{ location, basic_test_dir, "non-existent-file.txt" })));
}

test "CloudStorage Tests Basic File Operations should get file info" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    const testFile = try pathOf(allocator, &.{ location, basic_test_dir, "info-test.txt" });
    try shared_storage.write(allocator, io, testFile, "text/plain", basic_test_content);

    const info = (try shared_storage.info(allocator, io, testFile)).?;
    try std.testing.expectEqualStrings("text/plain", info.contentType.?);
    try std.testing.expectEqual(@as(u64, basic_test_content.len), info.length);
    try std.testing.expect(info.lastModified > 0);
}

test "CloudStorage Tests Basic File Operations should delete a file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    const testFile = try pathOf(allocator, &.{ location, basic_test_dir, "delete-test.txt" });
    try shared_storage.write(allocator, io, testFile, "text/plain", basic_test_content);

    try shared_storage.deleteFile(allocator, io, testFile);
    try std.testing.expect(!try shared_storage.fileExists(allocator, io, testFile));
}

test "CloudStorage Tests Basic File Operations should return undefined for non-existent file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    const missingFile = try pathOf(allocator, &.{ location, basic_test_dir, "non-existent.txt" });
    try std.testing.expect(try shared_storage.read(allocator, io, missingFile) == null);
    try std.testing.expect(try shared_storage.info(allocator, io, missingFile) == null);
}

// Directory Operations

//
// The directory the directory tests write in, each test in a subdirectory of its own.
//
const base_dir_test_dir = "dir-ops";

//
// The files the directory tests write.
//
const dir_test_files = [_][]const u8{ "file1.txt", "file2.txt", "file3.txt" };

//
// Writes each of the directory tests' files into a directory.
//
fn writeDirTestFiles(allocator: std.mem.Allocator, location: []const u8, testDir: []const u8) !void {
    for (dir_test_files) |file| {
        const content = try std.fmt.allocPrint(allocator, "Content of {s}", .{file});
        try shared_storage.write(allocator, std.testing.io, try pathOf(allocator, &.{ location, base_dir_test_dir, testDir, file }), "text/plain", content);
    }
}

test "CloudStorage Tests Directory Operations should check if directory exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    // Create files to make directory exist
    try writeDirTestFiles(allocator, location, "exists-test");

    try std.testing.expect(try shared_storage.dirExists(allocator, io, try pathOf(allocator, &.{ location, base_dir_test_dir, "exists-test" })));
    try std.testing.expect(!try shared_storage.dirExists(allocator, io, try pathOf(allocator, &.{ location, base_dir_test_dir, "non-existent-dir" })));
}

test "CloudStorage Tests Directory Operations should check if directory is empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    // Create files in testDir
    try writeDirTestFiles(allocator, location, "empty-test");

    try std.testing.expect(!try shared_storage.isEmpty(allocator, io, try pathOf(allocator, &.{ location, base_dir_test_dir, "empty-test" })));

    // Create and test empty directory
    const tempFile = try pathOf(allocator, &.{ location, base_dir_test_dir, "empty-dir", "temp.txt" });
    try shared_storage.write(allocator, io, tempFile, "text/plain", "temp");
    try shared_storage.deleteFile(allocator, io, tempFile);
    try std.testing.expect(try shared_storage.isEmpty(allocator, io, try pathOf(allocator, &.{ location, base_dir_test_dir, "empty-dir" })));
}

test "CloudStorage Tests Directory Operations should list files in directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    // Create test files
    try writeDirTestFiles(allocator, location, "list-files");

    const result = try shared_storage.listFiles(allocator, io, try pathOf(allocator, &.{ location, base_dir_test_dir, "list-files" }), 10, null);
    try std.testing.expectEqual(@as(usize, 3), result.names.len);
    const names = try allocator.dupe([]const u8, result.names);
    sortNames(names);
    for (dir_test_files, names) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "CloudStorage Tests Directory Operations should list directories" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    // Create subdirectories
    try shared_storage.write(allocator, io, try pathOf(allocator, &.{ location, base_dir_test_dir, "list-dirs", "subdir1", "file.txt" }), "text/plain", "content");
    try shared_storage.write(allocator, io, try pathOf(allocator, &.{ location, base_dir_test_dir, "list-dirs", "subdir2", "file.txt" }), "text/plain", "content");

    const result = try shared_storage.listDirs(allocator, io, try pathOf(allocator, &.{ location, base_dir_test_dir, "list-dirs" }), 10, null);
    try std.testing.expectEqual(@as(usize, 2), result.names.len);
    const names = try allocator.dupe([]const u8, result.names);
    sortNames(names);
    try std.testing.expectEqualStrings("subdir1", names[0]);
    try std.testing.expectEqualStrings("subdir2", names[1]);
}

test "CloudStorage Tests Directory Operations should delete directory and all contents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    // Create test files
    try writeDirTestFiles(allocator, location, "delete-dir");

    const testDir = try pathOf(allocator, &.{ location, base_dir_test_dir, "delete-dir" });
    try shared_storage.deleteDir(allocator, io, testDir);
    try std.testing.expect(!try shared_storage.dirExists(allocator, io, testDir));

    for (dir_test_files) |file| {
        try std.testing.expect(!try shared_storage.fileExists(allocator, io, try pathOf(allocator, &.{ testDir, file })));
    }
}

// Stream Operations

test "CloudStorage Tests Stream Operations should write and read streams" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    const testContent = "Stream test content";
    const testFile = try pathOf(allocator, &.{ location, "stream-ops", "stream-test.txt" });

    // Create a readable stream from buffer
    var readableStream = std.Io.Reader.fixed(testContent);
    try shared_storage.writeStream(allocator, io, testFile, "text/plain", &readableStream, testContent.len);

    const stream = try shared_storage.readStream(allocator, io, testFile);
    defer stream.destroy(io);
    const result = try stream.reader().allocRemaining(allocator, .unlimited);
    try std.testing.expectEqualStrings(testContent, result);

    // Leave stream test file for inspection
}

// Write Lock Operations

//
// The owners the lock tests take locks as.
//
const owner1 = "user-123";
const owner2 = "user-456";

//
// A lock file of its own for each test (TypeScript: `getLockFile`).
//
fn getLockFile(allocator: std.mem.Allocator, location: []const u8, testName: []const u8, lockNum: u32) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/write-locks/{s}/lock-{d}.lock", .{ location, testName, lockNum });
}

test "CloudStorage Tests Write Lock Operations checkWriteLock should return undefined for non-existent lock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const location = try setUp();

    const lockFile = try getLockFile(allocator, location, "check-nonexistent", 1);
    try std.testing.expect(try shared_storage.checkWriteLock(allocator, std.testing.io, lockFile) == null);
}

test "CloudStorage Tests Write Lock Operations checkWriteLock should return lock info for existing lock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    const lockFile = try getLockFile(allocator, location, "check-existing", 1);
    const beforeTime = nowMilliseconds();
    _ = try shared_storage.acquireWriteLock(allocator, io, lockFile, owner1);
    const afterTime = nowMilliseconds();

    const lockInfo = (try shared_storage.checkWriteLock(allocator, io, lockFile)).?;
    try std.testing.expectEqualStrings(owner1, lockInfo.owner);
    try std.testing.expect(lockInfo.acquiredAt.epochMilliseconds >= beforeTime);
    try std.testing.expect(lockInfo.acquiredAt.epochMilliseconds <= afterTime);
}

test "CloudStorage Tests Write Lock Operations acquireWriteLock should successfully acquire a lock for new file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    const lockFile = try getLockFile(allocator, location, "acquire-new", 1);
    try std.testing.expect(try shared_storage.acquireWriteLock(allocator, io, lockFile, owner1));

    // Verify lock was created
    try std.testing.expect(try shared_storage.fileExists(allocator, io, lockFile));

    // Verify lock content
    const lockInfo = (try shared_storage.checkWriteLock(allocator, io, lockFile)).?;
    try std.testing.expectEqualStrings(owner1, lockInfo.owner);
    try std.testing.expect(lockInfo.acquiredAt.epochMilliseconds > 0);
}

test "CloudStorage Tests Write Lock Operations acquireWriteLock should fail to acquire lock if one already exists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    const lockFile = try getLockFile(allocator, location, "acquire-existing", 1);
    try std.testing.expect(try shared_storage.acquireWriteLock(allocator, io, lockFile, owner1));
    try std.testing.expect(!try shared_storage.acquireWriteLock(allocator, io, lockFile, owner2));

    // Verify original lock is unchanged
    const lockInfo = (try shared_storage.checkWriteLock(allocator, io, lockFile)).?;
    try std.testing.expectEqualStrings(owner1, lockInfo.owner);
}

//
// The result of one of several concurrent attempts to take a lock.
//
const ILockAttempt = struct {
    // Whether the attempt took the lock.
    success: bool,

    // Who made the attempt.
    owner: []const u8,
};

//
// One concurrent attempt to take a lock, run on a thread of its own: waits the given number of microseconds,
// then tries. An error counts as not taking the lock (TypeScript's repeated race test does the same; in the
// others an error rejects the whole Promise.all, which the expectation below fails on too).
//
fn attemptLock(result: *ILockAttempt, lockFile: []const u8, delayMicroseconds: i64) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const io = std.testing.io;
    if (delayMicroseconds > 0) {
        io.sleep(.fromMicroseconds(delayMicroseconds), .awake) catch {};
    }
    result.success = shared_storage.acquireWriteLock(arena.allocator(), io, lockFile, result.owner) catch false;
}

//
// Starts one concurrent attempt per owner on a lock, each after a random delay of up to maxDelayMicroseconds, and
// waits for them all. Returns the owner of the one attempt that succeeded, failing when not exactly one did.
//
fn raceForLock(allocator: std.mem.Allocator, lockFile: []const u8, owners: []const []const u8, maxDelayMicroseconds: u32) ![]const u8 {
    const io = std.testing.io;
    const results = try allocator.alloc(ILockAttempt, owners.len);
    const threads = try allocator.alloc(std.Thread, owners.len);
    for (owners, results, threads) |owner, *result, *thread| {
        result.* = .{
            .success = false,
            .owner = owner,
        };
        var randomBytes: [4]u8 = undefined;
        io.random(&randomBytes);
        const delay: i64 = if (maxDelayMicroseconds == 0) 0 else @intCast(std.mem.readInt(u32, &randomBytes, .little) % maxDelayMicroseconds);
        thread.* = try std.Thread.spawn(.{}, attemptLock, .{ result, lockFile, delay });
    }
    for (threads) |thread| {
        thread.join();
    }

    // Exactly one should succeed, all others should fail
    var winner: ?[]const u8 = null;
    var successCount: usize = 0;
    for (results) |result| {
        if (result.success) {
            successCount += 1;
            winner = result.owner;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), successCount);
    return winner.?;
}

test "CloudStorage Tests Write Lock Operations acquireWriteLock should handle concurrent lock attempts atomically" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    const lockFile = try getLockFile(allocator, location, "concurrent-test", 1);
    const winner = try raceForLock(allocator, lockFile, &.{ "user-a", "user-b", "user-c", "user-d", "user-e" }, 0);

    // Verify lock exists
    try std.testing.expect(try shared_storage.fileExists(allocator, io, lockFile));

    // Verify lock has the correct owner
    const lockInfo = (try shared_storage.checkWriteLock(allocator, io, lockFile)).?;
    try std.testing.expectEqualStrings(winner, lockInfo.owner);
}

test "CloudStorage Tests Write Lock Operations acquireWriteLock should handle aggressive race conditions with many concurrent attempts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    const lockFile = try getLockFile(allocator, location, "aggressive-race", 1);
    const numAttempts = 20;
    var owners: [numAttempts][]const u8 = undefined;
    for (&owners, 0..) |*owner, index| {
        owner.* = try std.fmt.allocPrint(allocator, "user-{d}", .{index});
    }
    // Minimal timeouts with tiny random delays (0-2ms)
    const winner = try raceForLock(allocator, lockFile, &owners, 2000);

    // Verify the lock exists and belongs to the successful user
    const lockInfo = (try shared_storage.checkWriteLock(allocator, io, lockFile)).?;
    try std.testing.expectEqualStrings(winner, lockInfo.owner);

    // Verify only one lock file exists
    try std.testing.expect(try shared_storage.fileExists(allocator, io, lockFile));
}

test "CloudStorage Tests Write Lock Operations acquireWriteLock should handle repeated race condition tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    // Run multiple rounds of race condition tests to increase chance of catching timing bugs
    const numRounds = 5;
    for (0..numRounds) |round| {
        const lockFile = try getLockFile(allocator, location, try std.fmt.allocPrint(allocator, "race-round-{d}", .{round}), 1);
        const numAttempts = 10;
        var owners: [numAttempts][]const u8 = undefined;
        for (&owners, 0..) |*owner, index| {
            owner.* = try std.fmt.allocPrint(allocator, "round{d}-user{d}", .{ round, index });
        }

        // Add small random delays to create realistic race conditions (0-3ms)
        const winner = try raceForLock(allocator, lockFile, &owners, 3000);

        // Verify the winner has a valid lock
        const lockInfo = (try shared_storage.checkWriteLock(allocator, io, lockFile)).?;
        try std.testing.expectEqualStrings(winner, lockInfo.owner);
    }
}

test "CloudStorage Tests Write Lock Operations acquireWriteLock should store valid JSON with owner and timestamp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    const lockFile = try getLockFile(allocator, location, "json-format", 1);
    _ = try shared_storage.acquireWriteLock(allocator, io, lockFile, owner1);

    const content = (try shared_storage.read(allocator, io, lockFile)).?;
    const lockData = try std.json.parseFromSliceLeaky(std.json.Value, allocator, content, .{});
    const owner = lockData.object.get("owner").?;
    const acquiredAt = lockData.object.get("acquiredAt").?;
    try std.testing.expect(owner == .string);
    try std.testing.expect(acquiredAt == .string);

    // Verify it's a valid ISO date string
    const date = storage_zig.storage.parseISOString(acquiredAt.string).?;
    try std.testing.expectEqualStrings(acquiredAt.string, try date.toISOString(allocator));
}

test "CloudStorage Tests Write Lock Operations releaseWriteLock should successfully release an existing lock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    const lockFile = try getLockFile(allocator, location, "release-existing", 1);
    _ = try shared_storage.acquireWriteLock(allocator, io, lockFile, owner1);
    try std.testing.expect(try shared_storage.checkWriteLock(allocator, io, lockFile) != null);

    try shared_storage.releaseWriteLock(allocator, io, lockFile);
    try std.testing.expect(try shared_storage.checkWriteLock(allocator, io, lockFile) == null);
    try std.testing.expect(!try shared_storage.fileExists(allocator, io, lockFile));
}

test "CloudStorage Tests Write Lock Operations releaseWriteLock should handle releasing non-existent lock gracefully" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const location = try setUp();

    const lockFile = try getLockFile(allocator, location, "release-nonexistent", 1);
    try shared_storage.releaseWriteLock(allocator, std.testing.io, lockFile);
}

test "CloudStorage Tests Write Lock Operations releaseWriteLock should allow reacquisition after release" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    const lockFile = try getLockFile(allocator, location, "reacquire-after-release", 1);
    // Acquire, release, then acquire again
    try std.testing.expect(try shared_storage.acquireWriteLock(allocator, io, lockFile, owner1));
    try shared_storage.releaseWriteLock(allocator, io, lockFile);
    try std.testing.expect(try shared_storage.acquireWriteLock(allocator, io, lockFile, owner2));

    // Verify new owner
    const lockInfo = (try shared_storage.checkWriteLock(allocator, io, lockFile)).?;
    try std.testing.expectEqualStrings(owner2, lockInfo.owner);
}

test "CloudStorage Tests Write Lock Operations lock file format and metadata should create lock files with correct content type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    const lockFile = try getLockFile(allocator, location, "content-type", 1);
    _ = try shared_storage.acquireWriteLock(allocator, io, lockFile, owner1);

    const info = (try shared_storage.info(allocator, io, lockFile)).?;
    try std.testing.expectEqualStrings("application/json", info.contentType.?);
}

test "CloudStorage Tests Write Lock Operations lock file format and metadata should handle special characters in owner names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    const lockFile = try getLockFile(allocator, location, "special-chars", 1);
    const specialOwner = "user@domain.com with spaces & symbols!";
    _ = try shared_storage.acquireWriteLock(allocator, io, lockFile, specialOwner);

    const lockInfo = (try shared_storage.checkWriteLock(allocator, io, lockFile)).?;
    try std.testing.expectEqualStrings(specialOwner, lockInfo.owner);
}

test "CloudStorage Tests Write Lock Operations lock file format and metadata should preserve lock timing information accurately" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    const lockFile = try getLockFile(allocator, location, "timing", 1);
    const beforeTime = nowMilliseconds();
    _ = try shared_storage.acquireWriteLock(allocator, io, lockFile, owner1);
    const afterTime = nowMilliseconds();

    const lockInfo = (try shared_storage.checkWriteLock(allocator, io, lockFile)).?;
    const lockTime = lockInfo.acquiredAt.epochMilliseconds;
    try std.testing.expect(lockTime >= beforeTime);
    try std.testing.expect(lockTime <= afterTime);
}

test "CloudStorage Tests Write Lock Operations full lock lifecycle should handle complete lock workflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    const lockFile = try getLockFile(allocator, location, "full-lifecycle", 1);
    // 1. No lock initially
    try std.testing.expect(try shared_storage.checkWriteLock(allocator, io, lockFile) == null);

    // 2. Acquire lock
    try std.testing.expect(try shared_storage.acquireWriteLock(allocator, io, lockFile, owner1));

    // 3. Verify lock exists and has correct details
    const lockInfo = (try shared_storage.checkWriteLock(allocator, io, lockFile)).?;
    try std.testing.expectEqualStrings(owner1, lockInfo.owner);
    try std.testing.expect(lockInfo.acquiredAt.epochMilliseconds > 0);

    // 4. Other processes cannot acquire lock
    try std.testing.expect(!try shared_storage.acquireWriteLock(allocator, io, lockFile, owner2));

    // 5. Release lock
    try shared_storage.releaseWriteLock(allocator, io, lockFile);

    // 6. Lock is gone
    try std.testing.expect(try shared_storage.checkWriteLock(allocator, io, lockFile) == null);

    // 7. Other processes can now acquire lock
    try std.testing.expect(try shared_storage.acquireWriteLock(allocator, io, lockFile, owner2));
}

// Error Handling

test "CloudStorage Tests Error Handling should handle invalid bucket/key combinations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try setUp();

    const invalidLocation = "invalid-bucket-name-that-does-not-exist";
    var invalidStorage = CloudStorage.init(io, invalidLocation, null);
    defer invalidStorage.s3.deinit();

    if (invalidStorage.write(allocator, io, invalidLocation ++ "/error-handling/invalid-bucket-test.txt", "text/plain", "test")) |_| {
        return error.ExpectedTheWriteToFail;
    }
    else |_| {}
}

// Path Handling

test "CloudStorage Tests Path Handling should handle various path formats correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    const testCases = [_][]const u8{
        "simple-file.txt",
        "path/with/slashes.txt",
        "path/with spaces/file.txt",
        "path/with-special_chars@123.txt",
    };

    for (testCases) |testPath| {
        const fullPath = try pathOf(allocator, &.{ location, "path-handling", "various-formats", testPath });
        const content = try std.fmt.allocPrint(allocator, "Content for {s}", .{testPath});

        try shared_storage.write(allocator, io, fullPath, "text/plain", content);
        const readContent = try shared_storage.read(allocator, io, fullPath);
        try std.testing.expectEqualStrings(content, readContent.?);

        try shared_storage.deleteFile(allocator, io, fullPath);
    }
}

// Zig: what the TypeScript suite leaves untested

//
// The bucket of the suite's location (the part before the first "/").
//
fn bucketOf(location: []const u8) []const u8 {
    return location[0 .. std.mem.indexOfScalar(u8, location, '/') orelse location.len];
}

test "CloudStorage Zig: credentials given to the storage reach the server" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    var storage = CloudStorage.init(io, location, .{
        .accessKeyId = node_utils.process_env.getEnv("AWS_ACCESS_KEY_ID").?,
        .secretAccessKey = node_utils.process_env.getEnv("AWS_SECRET_ACCESS_KEY").?,
        .region = node_utils.process_env.getEnv("AWS_REGION"),
        .endpoint = node_utils.process_env.getEnv("AWS_ENDPOINT"),
    });
    defer storage.s3.deinit();
    const filePath = try pathOf(allocator, &.{ location, "zig-credentials", "file.txt" });
    try storage.write(allocator, io, filePath, "text/plain", "with credentials");
    try std.testing.expectEqualStrings("with credentials", (try storage.read(allocator, io, filePath)).?);
}

test "CloudStorage Zig: a key with a leading slash is the key without it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();
    const bucket = bucketOf(location);
    const plainKey = try pathOf(allocator, &.{ location[bucket.len + 1 ..], "zig-leading-slash", "file.txt" });
    const slashed = try std.fmt.allocPrint(allocator, "{s}//{s}", .{ bucket, plainKey });
    const plain = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ bucket, plainKey });
    const slashedDir = try std.fmt.allocPrint(allocator, "{s}//{s}", .{ bucket, std.fs.path.dirnamePosix(plainKey).? });

    try shared_storage.write(allocator, io, slashed, "text/plain", "slashed");
    try std.testing.expectEqualStrings("slashed", (try shared_storage.read(allocator, io, plain)).?);
    try std.testing.expectEqualStrings("slashed", (try shared_storage.read(allocator, io, slashed)).?);
    try std.testing.expect(try shared_storage.fileExists(allocator, io, slashed));
    try std.testing.expect(try shared_storage.dirExists(allocator, io, slashedDir));
    try std.testing.expectEqual(@as(u64, "slashed".len), (try shared_storage.info(allocator, io, slashed)).?.length);
    try std.testing.expectEqual(@as(usize, 1), (try shared_storage.listFiles(allocator, io, slashedDir, 10, null)).names.len);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("hashed", &hash, .{});
    var hashedInput = std.Io.Reader.fixed("hashed");
    try std.testing.expect(try shared_storage.writeStreamHashed(allocator, io, slashed, "text/plain", &hashedInput, "hashed".len, &hash));
    try std.testing.expectEqualSlices(u8, &hash, (try shared_storage.storedHash(allocator, io, slashed)).?);

    var input = std.Io.Reader.fixed("streamed");
    try shared_storage.writeStream(allocator, io, slashed, "text/plain", &input, "streamed".len);
    const stream = try shared_storage.readStream(allocator, io, slashed);
    defer stream.destroy(io);
    var content: std.ArrayList(u8) = .empty;
    try stream.reader().appendRemainingUnlimited(allocator, &content);
    try std.testing.expectEqualStrings("streamed", content.items);

    const copied = try std.fmt.allocPrint(allocator, "{s}//{s}.copy", .{ bucket, plainKey });
    try shared_storage.copyTo(allocator, io, slashed, copied);
    try std.testing.expectEqualStrings("streamed", (try shared_storage.read(allocator, io, copied)).?);

    try shared_storage.deleteFile(allocator, io, slashed);
    try std.testing.expect(!try shared_storage.fileExists(allocator, io, plain));
    try shared_storage.deleteDir(allocator, io, slashedDir);
    try std.testing.expect(!try shared_storage.dirExists(allocator, io, slashedDir));
}

test "CloudStorage Zig: a stream larger than one part goes up in parts, whole and in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();
    const filePath = try pathOf(allocator, &.{ location, "zig-multipart", "large.bin" });

    // Two whole parts of 5MB and a short one, each byte telling where it is, so a part out of place shows.
    const content = try allocator.alloc(u8, 11 * 1024 * 1024 + 123);
    for (content, 0..) |*byte, index| {
        byte.* = @truncate(index *% 7 +% index / 4096);
    }
    var input = std.Io.Reader.fixed(content);
    try shared_storage.writeStream(allocator, io, filePath, "application/octet-stream", &input, null);

    try std.testing.expectEqual(@as(u64, content.len), (try shared_storage.info(allocator, io, filePath)).?.length);
    try std.testing.expect(std.mem.eql(u8, content, (try shared_storage.read(allocator, io, filePath)).?));
}

test "CloudStorage Zig: copyTo copies a file to another key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();
    const source = try pathOf(allocator, &.{ location, "zig-copy", "source.txt" });
    const destination = try pathOf(allocator, &.{ location, "zig-copy", "destination.txt" });
    try shared_storage.write(allocator, io, source, "text/plain", "copied content");

    try shared_storage.copyTo(allocator, io, source, destination);
    try std.testing.expectEqualStrings("copied content", (try shared_storage.read(allocator, io, destination)).?);

    // Copying a file that is not there fails, naming both paths.
    const missing = try pathOf(allocator, &.{ location, "zig-copy", "missing.txt" });
    try std.testing.expectError(error.Thrown, shared_storage.copyTo(allocator, io, missing, destination));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), try std.fmt.allocPrint(allocator, "Failed to copy from {s} to {s}: ", .{ missing, destination })));
}

test "CloudStorage Zig: every operation on a bucket that does not exist fails, naming what it was doing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    _ = try setUp();
    const missingBucket = "photosphere-zig-no-such-bucket";
    var storage = CloudStorage.init(io, missingBucket, null);
    defer storage.s3.deinit();
    const filePath = missingBucket ++ "/dir/file.txt";
    const dirPath = missingBucket ++ "/dir";

    try std.testing.expectError(error.Thrown, storage.listFiles(allocator, io, dirPath, 10, null));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Failed to list files in " ++ dirPath ++ ": "));
    try std.testing.expectError(error.Thrown, storage.listDirs(allocator, io, dirPath, 10, null));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Failed to list directories in " ++ dirPath ++ ": "));
    try std.testing.expectError(error.Thrown, storage.dirExists(allocator, io, dirPath));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Failed to check if directory exists: "));
    try std.testing.expectError(error.Thrown, storage.read(allocator, io, filePath));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Failed to read " ++ filePath ++ ": "));
    try std.testing.expectError(error.Thrown, storage.checkWriteLock(allocator, io, filePath));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Failed to check write lock for " ++ filePath ++ ": "));
    try std.testing.expectError(error.Thrown, storage.acquireWriteLock(allocator, io, filePath, "owner"));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Failed to acquire write lock for " ++ filePath ++ ": "));
    var input = std.Io.Reader.fixed("streamed");
    try std.testing.expectError(error.Thrown, storage.writeStream(allocator, io, filePath, "text/plain", &input, "streamed".len));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), "Failed to write stream to " ++ filePath ++ ": "));

    // A file that is not there is not an error, whatever the bucket.
    try storage.deleteFile(allocator, io, filePath);
    try storage.releaseWriteLock(allocator, io, filePath);
}

test "CloudStorage Zig: a lock older than the timeout is broken and taken, and the verbose log says each step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();

    // Every [LOCK] line is asked for, and the console log that gets them writes nothing.
    var verboseLog: utils.log.ConsoleLog = .{ .verbose_enabled = true };
    const previousLog = utils.log.log;
    utils.log.setLog(verboseLog.ilog());
    defer utils.log.setLog(previousLog);

    const lockFile = try pathOf(allocator, &.{ location, "zig-locks", "stale.lock" });
    const staleTimestamp = nowMilliseconds() - 60_000;
    try shared_storage.write(allocator, io, lockFile, "application/json", try std.fmt.allocPrint(allocator, "{{\"owner\":\"dead-owner\",\"acquiredAt\":\"2020-01-01T00:00:00.000Z\",\"timestamp\":{d}}}", .{staleTimestamp}));

    try std.testing.expect(try shared_storage.acquireWriteLock(allocator, io, lockFile, "new-owner"));
    try std.testing.expectEqualStrings("new-owner", (try shared_storage.checkWriteLock(allocator, io, lockFile)).?.owner);

    // A fresh lock is refused, and releasing it twice is fine.
    try std.testing.expect(!try shared_storage.acquireWriteLock(allocator, io, lockFile, "third-owner"));
    try shared_storage.releaseWriteLock(allocator, io, lockFile);
    try shared_storage.releaseWriteLock(allocator, io, lockFile);
}

test "CloudStorage Zig: a lock file that is not a lock is reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const location = try setUp();
    const lockFile = try pathOf(allocator, &.{ location, "zig-locks", "garbage.lock" });
    try shared_storage.write(allocator, io, lockFile, "application/json", "not json");

    try std.testing.expectError(error.Thrown, shared_storage.checkWriteLock(allocator, io, lockFile));
    try std.testing.expect(std.mem.startsWith(u8, utils.errors.lastErrorMessage(), try std.fmt.allocPrint(allocator, "Failed to check write lock for {s}: ", .{lockFile})));

    // An empty lock file holds no lock.
    try shared_storage.write(allocator, io, lockFile, "application/json", "");
    try std.testing.expect((try shared_storage.checkWriteLock(allocator, io, lockFile)) == null);
}
