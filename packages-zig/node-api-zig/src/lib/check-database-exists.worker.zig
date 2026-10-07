//
// Check-database-exists worker handler.
//
// Runs on both platforms via the shared task queue: desktop registers it through initTaskHandlers and
// mobile through mobile-worker-entry, so "the database exists" means the same thing everywhere. The
// handler reuses checkDatabaseExists, which builds storage for the path (FileStorage over the native
// host.fs* functions on device, real fs on desktop/worker threads) and asks whether the database's
// merkle tree file exists, so a directory that exists but holds no database reads as absent identically
// on desktop and mobile.
//

const std = @import("std");
const utils = @import("utils-zig");
const task_queue_zig = @import("task-queue-zig");
const media_file_database = @import("media-file-database.zig");
const errors = utils.errors;
const ITaskContext = task_queue_zig.types.ITaskContext;
const checkDatabaseExists = media_file_database.checkDatabaseExists;

//
// Input for the check-database-exists task.
// (Zig: the `= ""` default lets std.json parse data that leaves the key out, which the check below then refuses.)
//
pub const ICheckDatabaseExistsData = struct {
    // The database path to probe (sandbox-relative on device, e.g. "my-db", or an fs:/s3: path).
    databasePath: []const u8 = "",
};

//
// Result of the check-database-exists task.
//
pub const ICheckDatabaseExistsResult = struct {
    // True when a real database is accessible at the path (its merkle tree file exists).
    exists: bool,
};

//
// Handler for the check-database-exists task. Returns whether an accessible database lives at the
// given path, reusing checkDatabaseExists so "exists" means the same thing on desktop and mobile.
// (Zig: the task data and output are JSON values holding ICheckDatabaseExistsData and ICheckDatabaseExistsResult.
// The context is ignored, as in TypeScript.)
//
pub fn checkDatabaseExistsHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    _ = context;
    // (Zig: reading the task data into the typed struct fails when databasePath is not a string, where TypeScript would
    // pass the wrong value on to checkDatabaseExists. The failure is reported as a sentence, not a bare parser error name.)
    const data = std.json.parseFromValueLeaky(ICheckDatabaseExistsData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errors.throwError("The check-database-exists task data is not valid: databasePath must be a string", .{});
    };
    if (data.databasePath.len == 0) {
        return errors.throwError("databasePath is required", .{});
    }

    const exists = try checkDatabaseExists(allocator, io, data.databasePath);
    const result: ICheckDatabaseExistsResult = .{
        .exists = exists,
    };
    const text = try std.json.Stringify.valueAlloc(allocator, result, .{});
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}
