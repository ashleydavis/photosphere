const std = @import("std");
const api_zig = @import("api-zig");
const utils = @import("utils-zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const write_lock = api_zig.write_lock;

const io = std.testing.io;

//
// Path of the database write lock file.
//
const LOCK_PATH = ".db/write.lock";

test "acquireWriteLock acquires a free lock for the session on the first attempt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    try std.testing.expect(try write_lock.acquireWriteLock(allocator, io, storage.asStorage(), "session-1", 3));

    const lockInfo = (try storage.asStorage().checkWriteLock(allocator, io, LOCK_PATH)).?;
    try std.testing.expectEqualStrings("session-1", lockInfo.owner);
}

test "acquireWriteLock returns false and warns who holds the lock when it stays held" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    _ = try storage.asStorage().acquireWriteLock(allocator, io, LOCK_PATH, "other-owner");

    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(null, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    try std.testing.expect(!try write_lock.acquireWriteLock(allocator, io, storage.asStorage(), "session-1", 1));

    try std.testing.expect(std.mem.startsWith(u8, stderr_capture.written(), "Failed to acquire write lock after 1 attempts. Lock is currently held by \"other-owner\" since 0s ago (acquired at "));
    try std.testing.expect(std.mem.endsWith(u8, stderr_capture.written(), "Z).\n"));
}

test "releaseWriteLock releases the lock so another owner can acquire it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try std.testing.expect(try write_lock.acquireWriteLock(allocator, io, storage.asStorage(), "session-1", 1));

    try write_lock.releaseWriteLock(allocator, io, storage.asStorage());

    try std.testing.expect((try storage.asStorage().checkWriteLock(allocator, io, LOCK_PATH)) == null);
    try std.testing.expect(try storage.asStorage().acquireWriteLock(allocator, io, LOCK_PATH, "other"));
}

//
// A storage whose write lock can never be acquired and is never held: the lock was let go between the attempt and
// the check of who holds it.
//
fn refuseWriteLock(ptr: *anyopaque, allocator: std.mem.Allocator, ioArgument: std.Io, filePath: []const u8, owner: []const u8) anyerror!bool {
    _ = ptr;
    _ = allocator;
    _ = ioArgument;
    _ = filePath;
    _ = owner;
    return false;
}

test "acquireWriteLock returns false and says the lock looks free when it was let go before the check" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var memoryStorage = MemoryStorage.init(allocator);
    const storage = memoryStorage.asStorage();
    var refusingVTable = storage.vtable.*;
    refusingVTable.acquireWriteLock = refuseWriteLock;
    var refusingStorage = storage;
    refusingStorage.vtable = &refusingVTable;

    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(null, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    try std.testing.expect(!try write_lock.acquireWriteLock(allocator, io, refusingStorage, "session-1", 1));
    try std.testing.expectEqualStrings("Failed to acquire write lock after 1 attempts. Lock appears to be available but acquisition failed.\n", stderr_capture.written());
}
