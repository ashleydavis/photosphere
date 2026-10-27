const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const api_zig = @import("api-zig");
const utils = @import("utils-zig");
const MemoryLog = @import("utils-zig").memory_log.MemoryLog;
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const write_lock = api_zig.write_lock;

const io = std.testing.io;

//
// Path of the database write lock file.
//
const LOCK_PATH = ".db/write.lock";

test "acquireWriteLock acquires a free lock for the session on the first attempt" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    try std.testing.expect(try write_lock.acquireWriteLock(allocator, io, log, storage.asStorage(), "session-1", 3));

    const lockInfo = (try storage.asStorage().checkWriteLock(allocator, io, LOCK_PATH)).?;
    try std.testing.expectEqualStrings("session-1", lockInfo.owner);
}

test "acquireWriteLock returns false and warns who holds the lock when it stays held" {
    const memory = try MemoryLog.init(std.testing.allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    _ = try storage.asStorage().acquireWriteLock(allocator, io, memory.log, LOCK_PATH, "other-owner");

    try std.testing.expect(!try write_lock.acquireWriteLock(allocator, io, memory.log, storage.asStorage(), "session-1", 1));

    try std.testing.expect(std.mem.startsWith(u8, memory.stderr(), "Failed to acquire write lock after 1 attempts. Lock is currently held by \"other-owner\" since 0s ago (acquired at "));
    try std.testing.expect(std.mem.endsWith(u8, memory.stderr(), "Z).\n"));
}

test "releaseWriteLock releases the lock so another owner can acquire it" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try std.testing.expect(try write_lock.acquireWriteLock(allocator, io, log, storage.asStorage(), "session-1", 1));

    try write_lock.releaseWriteLock(allocator, io, log, storage.asStorage());

    try std.testing.expect((try storage.asStorage().checkWriteLock(allocator, io, LOCK_PATH)) == null);
    try std.testing.expect(try storage.asStorage().acquireWriteLock(allocator, io, log, LOCK_PATH, "other"));
}

//
// A storage whose write lock can never be acquired and is never held: the lock was let go between the attempt and
// the check of who holds it.
//
fn refuseWriteLock(ptr: *anyopaque, allocator: std.mem.Allocator, ioArgument: std.Io, _: ILog, filePath: []const u8, owner: []const u8) anyerror!bool {
    _ = ptr;
    _ = allocator;
    _ = ioArgument;
    _ = filePath;
    _ = owner;
    return false;
}

test "acquireWriteLock returns false and says the lock looks free when it was let go before the check" {
    const memory = try MemoryLog.init(std.testing.allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var memoryStorage = MemoryStorage.init(allocator);
    const storage = memoryStorage.asStorage();
    var refusingVTable = storage.vtable.*;
    refusingVTable.acquireWriteLock = refuseWriteLock;
    var refusingStorage = storage;
    refusingStorage.vtable = &refusingVTable;

    try std.testing.expect(!try write_lock.acquireWriteLock(allocator, io, memory.log, refusingStorage, "session-1", 1));
    try std.testing.expectEqualStrings("Failed to acquire write lock after 1 attempts. Lock appears to be available but acquisition failed.\n", memory.stderr());
}

//
// A lock held for a minute or more is reported in minutes rather than seconds, and the ISO timestamp in the warning is
// the moment the lock was taken, not the moment the warning was written.
//
test "acquireWriteLock reports a lock held for more than a minute in minutes, with the time it was taken" {
    const memory = try MemoryLog.init(std.testing.allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    const heldSinceMs = std.Io.Clock.real.now(io).toMilliseconds() - 90 * 60 * 1000;
    try storage.locks.put(allocator, LOCK_PATH, .{
        .owner = "other-owner",
        .acquiredAt = .{ .epochMilliseconds = heldSinceMs },
        .timestamp = heldSinceMs,
    });

    try std.testing.expect(!try write_lock.acquireWriteLock(allocator, io, memory.log, storage.asStorage(), "session-1", 1));

    try std.testing.expect(std.mem.startsWith(u8, memory.stderr(), "Failed to acquire write lock after 1 attempts. Lock is currently held by \"other-owner\" since 90m ago (acquired at "));
}

test "refreshWriteLock keeps the lock for the session and moves its timestamp on" {
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try std.testing.expect(try write_lock.acquireWriteLock(allocator, io, log, storage.asStorage(), "session-1", 1));
    const before = (try storage.asStorage().checkWriteLock(allocator, io, LOCK_PATH)).?;

    try io.sleep(.fromMilliseconds(20), .awake);
    try write_lock.refreshWriteLock(allocator, io, log, storage.asStorage(), "session-1");

    const after = (try storage.asStorage().checkWriteLock(allocator, io, LOCK_PATH)).?;
    try std.testing.expectEqualStrings("session-1", after.owner);
    try std.testing.expect(after.timestamp > before.timestamp);
}
