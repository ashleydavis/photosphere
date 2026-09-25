const std = @import("std");
const api_zig = @import("api-zig");
const utils = @import("utils-zig");
const storage_zig = @import("storage-zig");
const database_config = api_zig.database_config;
const IDatabaseConfig = database_config.IDatabaseConfig;
const IStorage = storage_zig.storage.IStorage;
const IListResult = storage_zig.storage.IListResult;
const IFileInfo = storage_zig.storage.IFileInfo;
const IReadStream = storage_zig.storage.IReadStream;
const errors = utils.errors;

//
// An in-memory IStorage for the tests (only fileExists, read and write are implemented).
//
const MemoryStorage = struct {
    // Allocator for the stored files.
    allocator: std.mem.Allocator,

    // The files in the storage, keyed by path.
    files: std.StringArrayHashMapUnmanaged([]const u8),

    // Number of times write was called.
    writeCount: u32,

    //
    // Creates an empty storage.
    //
    fn init(allocator: std.mem.Allocator) MemoryStorage {
        return .{ .allocator = allocator, .files = .empty, .writeCount = 0 };
    }

    //
    // Gets the IStorage interface for this storage.
    //
    fn storage(self: *MemoryStorage) IStorage {
        return .{ .ptr = self, .vtable = &vtable, .location = "memory:" };
    }

    //
    // The IStorage functions of this storage.
    //
    const vtable: IStorage.VTable = .{
        .isEmpty = isEmpty,
        .listFiles = listFiles,
        .listDirs = listDirs,
        .fileExists = fileExists,
        .dirExists = dirExists,
        .info = info,
        .read = read,
        .write = write,
        .readStream = readStream,
        .writeStream = writeStream,
        .deleteFile = deleteFile,
        .deleteDir = deleteDir,
        .copyTo = copyTo,
        .checkWriteLock = checkWriteLock,
        .acquireWriteLock = acquireWriteLock,
        .releaseWriteLock = releaseWriteLock,
    };

    //
    // Not used by the tests.
    //
    fn isEmpty(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8) anyerror!bool {
        _ = ptr;
        _ = allocator;
        _ = io;
        _ = path;
        return error.NotImplemented;
    }

    //
    // Not used by the tests.
    //
    fn listFiles(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) anyerror!IListResult {
        _ = ptr;
        _ = allocator;
        _ = io;
        _ = path;
        _ = max;
        _ = next;
        return error.NotImplemented;
    }

    //
    // Not used by the tests.
    //
    fn listDirs(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) anyerror!IListResult {
        _ = ptr;
        _ = allocator;
        _ = io;
        _ = path;
        _ = max;
        _ = next;
        return error.NotImplemented;
    }

    //
    // Returns true if the file is stored.
    //
    fn fileExists(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!bool {
        _ = allocator;
        _ = io;
        const self: *MemoryStorage = @ptrCast(@alignCast(ptr));
        return self.files.contains(filePath);
    }

    //
    // Not used by the tests.
    //
    fn dirExists(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) anyerror!bool {
        _ = ptr;
        _ = allocator;
        _ = io;
        _ = dirPath;
        return error.NotImplemented;
    }

    //
    // Not used by the tests.
    //
    fn info(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!?IFileInfo {
        _ = ptr;
        _ = allocator;
        _ = io;
        _ = filePath;
        return error.NotImplemented;
    }

    //
    // Returns a copy of the stored file, or null.
    //
    fn read(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!?[]u8 {
        _ = io;
        const self: *MemoryStorage = @ptrCast(@alignCast(ptr));
        const data = self.files.get(filePath) orelse return null;
        return try allocator.dupe(u8, data);
    }

    //
    // Stores a copy of the data.
    //
    fn write(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, data: []const u8) anyerror!void {
        _ = allocator;
        _ = io;
        const self: *MemoryStorage = @ptrCast(@alignCast(ptr));
        try std.testing.expectEqualStrings("application/json", contentType.?);
        try self.files.put(self.allocator, try self.allocator.dupe(u8, filePath), try self.allocator.dupe(u8, data));
        self.writeCount += 1;
    }

    //
    // Not used by the tests.
    //
    fn readStream(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!IReadStream {
        _ = ptr;
        _ = allocator;
        _ = io;
        _ = filePath;
        return error.NotImplemented;
    }

    //
    // Not used by the tests.
    //
    fn writeStream(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64) anyerror!void {
        _ = ptr;
        _ = allocator;
        _ = io;
        _ = filePath;
        _ = contentType;
        _ = inputStream;
        _ = contentLength;
        return error.NotImplemented;
    }

    //
    // Not used by the tests.
    //
    fn deleteFile(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!void {
        _ = ptr;
        _ = allocator;
        _ = io;
        _ = filePath;
        return error.NotImplemented;
    }

    //
    // Not used by the tests.
    //
    fn deleteDir(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) anyerror!void {
        _ = ptr;
        _ = allocator;
        _ = io;
        _ = dirPath;
        return error.NotImplemented;
    }

    //
    // Not used by the tests.
    //
    fn copyTo(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, srcPath: []const u8, destPath: []const u8) anyerror!void {
        _ = ptr;
        _ = allocator;
        _ = io;
        _ = srcPath;
        _ = destPath;
        return error.NotImplemented;
    }

    //
    // Not implemented.
    //
    fn checkWriteLock(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!?storage_zig.storage.IWriteLockInfo {
        _ = ptr;
        _ = allocator;
        _ = io;
        _ = filePath;
        return error.NotImplemented;
    }

    //
    // Not implemented.
    //
    fn acquireWriteLock(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, owner: []const u8) anyerror!bool {
        _ = ptr;
        _ = allocator;
        _ = io;
        _ = filePath;
        _ = owner;
        return error.NotImplemented;
    }

    //
    // Not implemented.
    //
    fn releaseWriteLock(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) anyerror!void {
        _ = ptr;
        _ = allocator;
        _ = io;
        _ = filePath;
        return error.NotImplemented;
    }
};

//
// A scenario recorded by generate.ts from the TypeScript implementation.
//
const IScenario = struct {
    // Name of the scenario.
    name: []const u8,

    // Initial contents of .db/config.json (null when the file does not exist).
    initial: ?[]const u8 = null,

    // "save" or "update".
    operation: []const u8,

    // The config passed to saveDatabaseConfig or the partial passed to updateDatabaseConfig.
    config: IDatabaseConfig,

    // The bytes TypeScript wrote to .db/config.json.
    expected: []const u8,
};

test "saveDatabaseConfig and updateDatabaseConfig write the same bytes as TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    const json = try std.Io.Dir.cwd().readFileAlloc(io, "src/test/fixtures/database-config.json", allocator, .unlimited);
    const scenarios = try std.json.parseFromSliceLeaky([]IScenario, allocator, json, .{});
    try std.testing.expect(scenarios.len >= 7);

    for (scenarios) |scenario| {
        var memory_storage = MemoryStorage.init(allocator);
        if (scenario.initial) |initial| {
            try memory_storage.files.put(allocator, ".db/config.json", initial);
        }
        if (std.mem.eql(u8, scenario.operation, "save")) {
            try database_config.saveDatabaseConfig(allocator, io, memory_storage.storage(), scenario.config);
        }
        else {
            try database_config.updateDatabaseConfig(allocator, io, memory_storage.storage(), scenario.config);
        }
        std.testing.expectEqualStrings(scenario.expected, memory_storage.files.get(".db/config.json").?) catch |err| {
            std.debug.print("scenario {s} failed\n", .{scenario.name});
            return err;
        };
    }
}

test "loadDatabaseConfig returns null if the file does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var memory_storage = MemoryStorage.init(arena.allocator());
    const config = try database_config.loadDatabaseConfig(arena.allocator(), std.testing.io, memory_storage.storage());
    try std.testing.expect(config == null);
}

test "loadDatabaseConfig reads every field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var memory_storage = MemoryStorage.init(allocator);
    try memory_storage.files.put(allocator, ".db/config.json",
        \\{
        \\  "lastModifiedAt": "m",
        \\  "origin": "o",
        \\  "lastReplicatedAt": "r",
        \\  "lastSyncedAt": "s",
        \\  "unknown": 5
        \\}
    );
    const config = (try database_config.loadDatabaseConfig(allocator, std.testing.io, memory_storage.storage())).?.object;
    try std.testing.expectEqualStrings("o", config.get("origin").?.string);
    try std.testing.expectEqualStrings("r", config.get("lastReplicatedAt").?.string);
    try std.testing.expectEqualStrings("s", config.get("lastSyncedAt").?.string);
    try std.testing.expectEqualStrings("m", config.get("lastModifiedAt").?.string);
    try std.testing.expectEqual(@as(i64, 5), config.get("unknown").?.integer);
}

test "loadDatabaseConfig returns an empty object for an empty config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var memory_storage = MemoryStorage.init(allocator);
    try memory_storage.files.put(allocator, ".db/config.json", "{}");
    const config = (try database_config.loadDatabaseConfig(allocator, std.testing.io, memory_storage.storage())).?.object;
    try std.testing.expectEqual(@as(usize, 0), config.count());
}

test "loadDatabaseConfig returns the JSON null of a null file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var memory_storage = MemoryStorage.init(allocator);
    try memory_storage.files.put(allocator, ".db/config.json", "null");
    try std.testing.expect((try database_config.loadDatabaseConfig(allocator, std.testing.io, memory_storage.storage())).? == .null);
}

test "loadDatabaseConfig throws a WrappedError for invalid JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var memory_storage = MemoryStorage.init(allocator);
    try memory_storage.files.put(allocator, ".db/config.json", "{ not json");
    try std.testing.expectError(error.Thrown, database_config.loadDatabaseConfig(allocator, std.testing.io, memory_storage.storage()));
    try std.testing.expect(std.mem.startsWith(u8, errors.lastErrorMessage(), "Failed to parse database config at .db/config.json: "));
    try std.testing.expectEqualStrings("WrappedError", errors.lastErrorName());
    try std.testing.expect(errors.lastErrorCauseMessage().len > 0);
}

test "saveDatabaseConfig then loadDatabaseConfig round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var memory_storage = MemoryStorage.init(allocator);
    try database_config.saveDatabaseConfig(allocator, io, memory_storage.storage(), IDatabaseConfig{ .origin = "fs:/a" });
    try std.testing.expectEqual(@as(u32, 1), memory_storage.writeCount);
    const config = (try database_config.loadDatabaseConfig(allocator, io, memory_storage.storage())).?.object;
    try std.testing.expectEqualStrings("fs:/a", config.get("origin").?.string);
    try std.testing.expectEqual(@as(usize, 1), config.count());
}

test "updateDatabaseConfig overwrites existing values in place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var memory_storage = MemoryStorage.init(allocator);
    try memory_storage.files.put(allocator, ".db/config.json", "{\n  \"origin\": \"first\",\n  \"lastModifiedAt\": \"m\"\n}");
    try database_config.updateDatabaseConfig(allocator, io, memory_storage.storage(), .{ .origin = "second" });
    try std.testing.expectEqualStrings("{\n  \"origin\": \"second\",\n  \"lastModifiedAt\": \"m\"\n}", memory_storage.files.get(".db/config.json").?);
}
