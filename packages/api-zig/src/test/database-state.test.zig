const std = @import("std");
const api_zig = @import("api-zig");
const utils = @import("utils-zig");
const MemoryStorage = @import("memory-storage.zig").MemoryStorage;
const database_state = api_zig.database_state;
const IDatabaseState = database_state.IDatabaseState;
const loadDatabaseState = database_state.loadDatabaseState;
const saveDatabaseState = database_state.saveDatabaseState;
const mergeDatabaseState = database_state.mergeDatabaseState;
const updateDatabaseStateLocked = database_state.updateDatabaseStateLocked;

const io = std.testing.io;

//
// Path of the database state file.
//
const STATE_PATH = ".db/state.dat";

//
// Path of the database write lock file.
//
const LOCK_PATH = ".db/write.lock";

//
// Asserts that two optional strings are equal (both absent or both the same text).
//
fn expectOptionalString(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected) |expectedText| {
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(expectedText, actual.?);
    }
    else {
        try std.testing.expect(actual == null);
    }
}

//
// Asserts that two states hold the same fields (TypeScript: `expect(loaded).toEqual(state)`).
//
fn expectState(expected: IDatabaseState, actual: IDatabaseState) !void {
    try expectOptionalString(expected.contentHash, actual.contentHash);
    try expectOptionalString(expected.lastModifiedAt, actual.lastModifiedAt);
    try expectOptionalString(expected.lastSyncedAt, actual.lastSyncedAt);
    try expectOptionalString(expected.lastReplicatedAt, actual.lastReplicatedAt);
}

test "round-trips all fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var contentHash: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&contentHash, "0123456789abcdef0123456789abcdef");
    const state: IDatabaseState = .{
        .contentHash = &contentHash,
        .lastModifiedAt = "2026-01-02T03:04:05.000Z",
        .lastSyncedAt = "2026-01-02T03:04:06.000Z",
        .lastReplicatedAt = "2026-01-02T03:04:07.000Z",
    };

    try saveDatabaseState(allocator, io, storage.asStorage(), state);
    const loaded = try loadDatabaseState(allocator, io, storage.asStorage());

    try std.testing.expect(loaded != null);
    try expectState(state, loaded.?);
    try std.testing.expectEqualSlices(u8, state.contentHash.?, loaded.?.contentHash.?);
}

test "a field survives a merge that does not mention it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    try saveDatabaseState(allocator, io, storage.asStorage(), .{
        .lastReplicatedAt = "2026-01-02T03:04:07.000Z",
    });
    try mergeDatabaseState(allocator, io, storage.asStorage(), .{
        .lastSyncedAt = "2026-01-02T03:04:06.000Z",
    });
    const loaded = (try loadDatabaseState(allocator, io, storage.asStorage())).?;

    try expectOptionalString("2026-01-02T03:04:07.000Z", loaded.lastReplicatedAt);
    try expectOptionalString("2026-01-02T03:04:06.000Z", loaded.lastSyncedAt);
}

test "omits absent fields on load" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    try saveDatabaseState(allocator, io, storage.asStorage(), .{
        .lastSyncedAt = "2026-01-02T03:04:06.000Z",
    });
    const loaded = (try loadDatabaseState(allocator, io, storage.asStorage())).?;

    try expectState(.{
        .lastSyncedAt = "2026-01-02T03:04:06.000Z",
    }, loaded);
    try std.testing.expect(loaded.contentHash == null);
    try std.testing.expect(loaded.lastModifiedAt == null);
}

test "returns undefined when the file is missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try std.testing.expect((try loadDatabaseState(allocator, io, storage.asStorage())) == null);
}

test "returns undefined for a zero-byte file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try storage.asStorage().write(allocator, io, STATE_PATH, null, "");
    try std.testing.expect((try loadDatabaseState(allocator, io, storage.asStorage())) == null);
}

test "returns undefined for a garbage file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try storage.asStorage().write(allocator, io, STATE_PATH, null, &([_]u8{0xff} ** 20));
    try std.testing.expect((try loadDatabaseState(allocator, io, storage.asStorage())) == null);
}

test "returns undefined when the checksum does not match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try saveDatabaseState(allocator, io, storage.asStorage(), .{
        .lastModifiedAt = "2026-01-02T03:04:05.000Z",
    });

    // Flip the last checksum byte so the stored checksum no longer matches the payload.
    const good = (try storage.asStorage().read(allocator, io, STATE_PATH)).?;
    const corrupt = try allocator.dupe(u8, good);
    corrupt[corrupt.len - 1] = corrupt[corrupt.len - 1] ^ 0xff;
    try storage.asStorage().write(allocator, io, STATE_PATH, null, corrupt);

    try std.testing.expect((try loadDatabaseState(allocator, io, storage.asStorage())) == null);
}

test "mergeDatabaseState merges into an existing state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try saveDatabaseState(allocator, io, storage.asStorage(), .{
        .lastModifiedAt = "A",
        .lastSyncedAt = "B",
    });

    try mergeDatabaseState(allocator, io, storage.asStorage(), .{
        .lastSyncedAt = "C",
    });

    try expectState(.{
        .lastModifiedAt = "A",
        .lastSyncedAt = "C",
    }, (try loadDatabaseState(allocator, io, storage.asStorage())).?);
}

test "mergeDatabaseState creates the state when absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    try mergeDatabaseState(allocator, io, storage.asStorage(), .{
        .lastModifiedAt = "A",
    });
    try expectState(.{
        .lastModifiedAt = "A",
    }, (try loadDatabaseState(allocator, io, storage.asStorage())).?);
}

test "updateDatabaseStateLocked writes while holding the lock, then releases it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);

    try updateDatabaseStateLocked(allocator, io, storage.asStorage(), "session-1", .{
        .lastSyncedAt = "X",
    });

    try expectState(.{
        .lastSyncedAt = "X",
    }, (try loadDatabaseState(allocator, io, storage.asStorage())).?);
    // The lock is released afterwards, so another owner can acquire it.
    try std.testing.expect(try storage.asStorage().acquireWriteLock(allocator, io, LOCK_PATH, "other"));
}

test "updateDatabaseStateLocked does nothing when the lock is held by another owner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    _ = try storage.asStorage().acquireWriteLock(allocator, io, LOCK_PATH, "other-owner");

    // (Zig: the warning acquireWriteLock logs is captured, because the test runner fails a test that writes to stderr.)
    var stderr_capture = std.Io.Writer.Allocating.init(allocator);
    utils.console.setCapture(null, &stderr_capture.writer);
    defer utils.console.setCapture(null, null);

    try updateDatabaseStateLocked(allocator, io, storage.asStorage(), "session-1", .{
        .lastSyncedAt = "X",
    });

    try std.testing.expect((try loadDatabaseState(allocator, io, storage.asStorage())) == null);
    try std.testing.expect(std.mem.startsWith(u8, stderr_capture.written(), "Failed to acquire write lock after 3 attempts. Lock is currently held by \"other-owner\" since "));
    try std.testing.expect(std.mem.indexOf(u8, stderr_capture.written(), "s ago (acquired at ") != null);
}

test "the state file is byte-identical to the one TypeScript writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var storage = MemoryStorage.init(allocator);
    var contentHash: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&contentHash, "0123456789abcdef0123456789abcdef");
    try saveDatabaseState(allocator, io, storage.asStorage(), .{
        .contentHash = &contentHash,
        .lastModifiedAt = "2026-01-02T03:04:05.000Z",
        .lastReplicatedAt = "2026-01-02T03:04:07.000Z",
    });
    const expected = try std.Io.Dir.cwd().readFileAlloc(io, "src/test/fixtures/database-state.dat", allocator, .unlimited);
    try std.testing.expectEqualSlices(u8, expected, storage.getFile(STATE_PATH).?);

    try storage.putFile(STATE_PATH, expected);
    try expectState(.{
        .contentHash = &contentHash,
        .lastModifiedAt = "2026-01-02T03:04:05.000Z",
        .lastReplicatedAt = "2026-01-02T03:04:07.000Z",
    }, (try loadDatabaseState(allocator, io, storage.asStorage())).?);
}
