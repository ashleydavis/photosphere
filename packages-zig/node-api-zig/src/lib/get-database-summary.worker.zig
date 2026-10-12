const std = @import("std");
const utils = @import("utils-zig");
const task_queue_zig = @import("task-queue-zig");
const media_file_database = @import("media-file-database.zig");
const open_storage = @import("open-storage.zig");
const errors = utils.errors;
const ITaskContext = task_queue_zig.types.ITaskContext;
const getDatabaseSummary = media_file_database.getDatabaseSummary;
const openStorage = open_storage.openStorage;

//
// Input data for the get-database-summary task.
// (Zig: the `= ""` default lets std.json parse data that leaves the key out, which the handler then refuses.)
//
pub const IGetDatabaseSummaryData = struct {
    //
    // Filesystem path (or S3 path) to the database directory.
    //
    databasePath: []const u8 = "",
};

//
// Task handler that computes a summary of the database at the given path.
// Returns the summary as the task result.
// (Zig: the task data and output are JSON values holding IGetDatabaseSummaryData and IDatabaseSummary. A summary field
// that holds no value is left out of the output. The context is used only for its host requester, which opens the
// storage of a database whose credentials the phone's keychain holds.)
//
pub fn getDatabaseSummaryHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    // (Zig: reading the task data into the typed struct fails when databasePath is not a string.
    // The failure is reported as a sentence, not a bare parser error name.)
    const data = std.json.parseFromValueLeaky(IGetDatabaseSummaryData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errors.throwError("The get-database-summary task data is not valid: databasePath must be a string", .{});
    };
    if (data.databasePath.len == 0) {
        return errors.throwError("databasePath is required", .{});
    }

    const opened = try openStorage(allocator, io, data.databasePath, null, null, context.hostRequester);
    const summary = try getDatabaseSummary(allocator, io, opened.storage);
    const text = try std.json.Stringify.valueAlloc(allocator, summary, .{
        .emit_null_optional_fields = false,
    });
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}
