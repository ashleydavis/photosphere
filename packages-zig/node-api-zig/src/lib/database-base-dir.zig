//
// The directory a simple database name is resolved against (a short name a user types, such as `my-photos`, in the New database,
// Add database, Edit origin, Replicate or Consolidate dialog): `<data dir>/dbs`. It is passed to createStorage, which resolves any
// other relative path against the working directory and keeps an absolute or S3 path as it is.
//

const std = @import("std");
const node_utils = @import("node-utils-zig");
const storage_zig = @import("storage-zig");

//
// The key of a task's data under which the app's data directory is handed to a task queue handler. Ziggy's ITaskContext does not
// carry the data directory, and runQueueHandler passes the handler nothing but the context and the data, so the task adapter
// (`fromNodeApiHandler` in task-handlers.zig) puts Ziggy's TaskContext.data_dir in the data under this key before the handler runs.
// The adapter always writes it, so a value queued under this key by anything else is replaced.
//
pub const TASK_DATA_DIR_KEY = "taskDataDir";

//
// Whether a database path is a simple name, a single path segment such as `my-photos`: the only kind of path resolved against
// databaseBaseDir. Every other relative path is resolved against the working directory. It lives in storage-zig, where createStorage
// uses it, and is named here beside the base directory it decides the use of.
//
pub const isSimpleName = storage_zig.storage_factory.isSimpleName;

//
// The base directory for the app's database paths: the `dbs` directory in the app's data directory, so databases sit apart from the
// other things kept there (logs, the single-instance lock, the web view's data). The data directory is the one PHOTOSPHERE_DATA_DIR
// names when it is set, which is how a test gives each run of the app a data directory of its own, or else the app's data directory.
// An empty data directory, which is what a program with none (the CLI) has, is the working directory itself, with no `dbs` added.
// The `dbs` directory need not exist: creating a database makes the directories its path needs. The joined path is allocated with
// the given allocator.
//
pub fn databaseBaseDir(allocator: std.mem.Allocator, data_dir: []const u8) ![]const u8 {
    const resolved_data_dir = node_utils.process_env.getEnv("PHOTOSPHERE_DATA_DIR") orelse data_dir;
    if (resolved_data_dir.len == 0) {
        return "";
    }
    return try std.fs.path.join(allocator, &.{ resolved_data_dir, "dbs" });
}

//
// The base directory for the database paths a task queue handler is given: databaseBaseDir of the data directory the task adapter put
// in the task's data under TASK_DATA_DIR_KEY. Data with no such key (a task the CLI runs, whose handlers are not given one) has the
// empty data directory, which is the working directory.
//
pub fn taskDatabaseBaseDir(allocator: std.mem.Allocator, taskData: std.json.Value) ![]const u8 {
    if (taskData == .object) {
        if (taskData.object.get(TASK_DATA_DIR_KEY)) |value| {
            if (value == .string) {
                return try databaseBaseDir(allocator, value.string);
            }
        }
    }
    return try databaseBaseDir(allocator, "");
}

//
// The task's data with the data directory put in it under TASK_DATA_DIR_KEY, allocated with the task's allocator. An object is copied
// with the key added, and no data (null) becomes an object holding only the key. Data of another kind (a string, a number, an array)
// is returned as it is, since it has nowhere to hold the key; no task that is given a database path is queued with data of that kind.
//
pub fn withTaskDataDir(allocator: std.mem.Allocator, taskData: std.json.Value, data_dir: []const u8) !std.json.Value {
    var object: std.json.ObjectMap = switch (taskData) {
        .object => |given| try given.clone(allocator),
        .null => .empty,
        else => return taskData,
    };
    try object.put(allocator, TASK_DATA_DIR_KEY, .{
        .string = data_dir,
    });
    return .{
        .object = object,
    };
}
