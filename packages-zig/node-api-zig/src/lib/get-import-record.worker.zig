const std = @import("std");
const utils = @import("utils-zig");
const task_queue_zig = @import("ziggy").task_queue;
const import_record_storage = @import("import-record-storage.zig");
const errors = utils.errors;
const ITaskContext = task_queue_zig.types.ITaskContext;
const loadImportRecord = import_record_storage.loadImportRecord;

//
// What this machine has imported into a database, for the Import page to show.
//
// This exists so opening a database shows what it last took in, rather than only what happened while
// the app has been running. The interface cannot reach the machine's cache directory itself, on any
// platform, so it asks through here.
//
// The database's storage is never opened: the record is a local file beside the hash cache, so the
// record can be read for a database whose credentials are missing or whose remote is unreachable.
//

//
// Input data for the get-import-record task.
// (Zig: the `= ""` default lets std.json parse data that leaves the key out, which the handler then refuses.)
//
pub const IGetImportRecordData = struct {
    //
    // Filesystem path (or S3 path) to the database directory.
    //
    databasePath: []const u8 = "",
};

//
// Task handler returning the database's import record.
// (Zig: the task data and output are JSON values holding IGetImportRecordData and IImportRecord. A micro thumbnail
// that an entry does not have is left out of the output. The context is ignored.)
//
pub fn getImportRecordHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    _ = context;
    // (Zig: reading the task data into the typed struct fails when databasePath is not a string.
    // The failure is reported as a sentence, not a bare parser error name.)
    const data = std.json.parseFromValueLeaky(IGetImportRecordData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errors.throwError("The get-import-record task data is not valid: databasePath must be a string", .{});
    };
    if (data.databasePath.len == 0) {
        return errors.throwError("databasePath is required", .{});
    }

    const record = try loadImportRecord(allocator, io, data.databasePath);
    const text = try std.json.Stringify.valueAlloc(allocator, record, .{
        .emit_null_optional_fields = false,
    });
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}
