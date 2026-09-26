const std = @import("std");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const IStorage = storage_zig.storage.IStorage;
const log = &utils.log.log;
const sleep = utils.sleep.sleep;
const retry = utils.retry.retry;

//
// How long one request against the lock file may take before it is retried.
//
// Thirty seconds, the retry default, is a desktop's idea of a long time. The lock file lives beside
// the database, so on a phone syncing to S3 it is a network request queued behind whatever else that
// connection is carrying. Every background sync pass on a Pixel 6 died with "Operation timed out
// after 30000ms: () => rawStorage.releaseWriteLock(...)", thrown from the release in a finally
// block, which killed the pass before it reached the half that pushes files. The library never went
// up, and the reason was the lock being let go of rather than anything to do with the photos.
//
const LOCK_REQUEST_TIMEOUT_MS = 5 * 60 * 1000;

//
// Rounds like JavaScript's Math.round (halves round towards positive infinity).
// (No TypeScript counterpart: stands in for Math.round.)
//
fn mathRound(value: f64) i64 {
    return @intFromFloat(@floor(value + 0.5));
}

//
// Acquires the write lock for the database.
// Only needed for writing to:
// - the merkle tree file (files.dat).
// - the BSON database and sorted indexes.
//
// Throws when the write lock cannot be acquired.
//
pub fn acquireWriteLock(allocator: std.mem.Allocator, io: std.Io, rawStorage: IStorage, sessionId: []const u8, maxAttempts: u32) !bool {

    const lockFilePath = ".db/write.lock";

    var attempt: u32 = 1;
    while (attempt <= maxAttempts) : (attempt += 1) {
        const haveWriteLock = try rawStorage.acquireWriteLock(allocator, io, lockFilePath, sessionId);
        if (haveWriteLock) {
            // We have the write lock.
            return true;
        }

        // Wait with increasing timeout before next attempt (unless this is the last attempt).
        if (attempt < maxAttempts) {
            const timeoutMs: u64 = attempt * 1000; // 1s, 2s
            try sleep(io, timeoutMs);
        }
    }

    // All attempts failed - check lock info for detailed error message.
    const lockInfo = try rawStorage.checkWriteLock(allocator, io, lockFilePath);
    if (lockInfo) |info| {
        const timeSinceLocked = std.Io.Clock.real.now(io).toMilliseconds() - info.acquiredAt.epochMilliseconds;
        const timeString = if (timeSinceLocked < 60000)
            try std.fmt.allocPrint(allocator, "{d}s", .{mathRound(@as(f64, @floatFromInt(timeSinceLocked)) / 1000)})
        else
            try std.fmt.allocPrint(allocator, "{d}m", .{mathRound(@as(f64, @floatFromInt(timeSinceLocked)) / 60000)});

        log.warn(try std.fmt.allocPrint(
            allocator,
            "Failed to acquire write lock after {d} attempts. " ++
                "Lock is currently held by \"{s}\" since {s} ago " ++
                "(acquired at {s}).",
            .{ maxAttempts, info.owner, timeString, try info.acquiredAt.toISOString(allocator) },
        ));
    }
    else {
        log.warn(try std.fmt.allocPrint(
            allocator,
            "Failed to acquire write lock after {d} attempts. " ++
                "Lock appears to be available but acquisition failed.",
            .{maxAttempts},
        ));
    }

    return false;
}

// Not ported: refreshWriteLock (not used by psi replicate or psi verify).

//
// Releases the write lock for the database (the `() => rawStorage.releaseWriteLock(".db/write.lock")` of TypeScript).
//
const ReleaseWriteLockOperation = struct {
    // The Bun toString() of the TypeScript operation (read by retryOnce for its timeout message).
    pub const source = "() => rawStorage.releaseWriteLock(\".db/write.lock\")";

    // Allocator for the storage implementation's temporary data.
    allocator: std.mem.Allocator,

    // The storage holding the lock.
    rawStorage: IStorage,

    //
    // Releases the lock.
    //
    pub fn run(self: *ReleaseWriteLockOperation, io: std.Io) !void {
        return self.rawStorage.releaseWriteLock(self.allocator, io, ".db/write.lock");
    }
};

//
// Releases the write lock for the database.
//
pub fn releaseWriteLock(allocator: std.mem.Allocator, io: std.Io, rawStorage: IStorage) !void {
    var operation: ReleaseWriteLockOperation = .{ .allocator = allocator, .rawStorage = rawStorage };
    try retry(io, &operation, 3, 1_000, 2, LOCK_REQUEST_TIMEOUT_MS, "Failed to release the database write lock");
}
