const std = @import("std");
const utils = @import("utils-zig");
const task_queue_zig = @import("task-queue-zig");
const api = @import("api-zig");
const open_storage = @import("open-storage.zig");
const errors = utils.errors;
const ITaskContext = task_queue_zig.types.ITaskContext;
const updateDatabaseConfig = api.database_config.updateDatabaseConfig;
const openStorage = open_storage.openStorage;

//
// Records where a database syncs to, in the database's own config.
//
// The origin has to live inside the database because that is where every sync reads it from: a
// background pass runs when there is no interface and nothing has been opened, so it opens the
// database it was told to sync and asks that. A copy kept only in the machine's database list is a
// copy the sync loop never sees, which is a database that silently never syncs.
//
// The interface cannot write into a database's storage on any platform, so it asks through here.
// Desktop does the same work in its own process; this exists for mobile, where the WebView has no
// filesystem and every storage write goes through a task.
//

//
// Input data for the set-database-origin task.
// (Zig: the `= ""` and `= null` defaults let std.json parse data that leaves keys out.)
//
pub const ISetDatabaseOriginData = struct {
    //
    // Filesystem path (or S3 path) to the database whose origin is being set.
    //
    databasePath: []const u8 = "",

    //
    // Where the database syncs to. Undefined clears the origin, which stops it syncing anywhere.
    //
    origin: ?[]const u8 = null,
};

//
// Task handler that writes the origin into the database's config.
// (Zig: the task data is a JSON value holding ISetDatabaseOriginData, and the task returns no value, so the handler
// returns JSON null. The context is ignored.)
//
pub fn setDatabaseOriginHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    // (Zig: reading the task data into the typed struct fails when a key holds the wrong type.
    // The failure is reported as a sentence, not a bare parser error name.)
    const data = std.json.parseFromValueLeaky(ISetDatabaseOriginData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errors.throwError("The set-database-origin task data is not valid: databasePath and origin must be strings", .{});
    };
    if (data.databasePath.len == 0) {
        return errors.throwError("databasePath is required", .{});
    }

    const opened = try openStorage(allocator, io, data.databasePath, null, null, context.hostRequester);
    try updateDatabaseConfig(allocator, io, opened.rawStorage, .{
        .origin = data.origin,
    });
    return .null;
}
