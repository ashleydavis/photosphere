//
// The recent-database channels: get-recent-databases, get-last-database and remove-recent-database-name, from the ipcMain handlers
// of apps/desktop/src/main.ts of the same names. They read and write the recents and the last database in databases.toml.
//
// Each is a task type, because they read and write a file, and the thread that handles the page's messages must not wait for that.
//
// What the page sees is what Electron sends back, in JSON: get-last-database replies with the path, or null where Electron replies
// undefined when no database is open, and remove-recent-database-name replies with null where Electron replies undefined.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");

const TaskContext = ziggy.task_runner.TaskContext;
const json_util = ziggy.json_util;
const databases_config = node_api.databases_config;
const log = &utils.log.log;

//
// get-recent-databases: no payload. The reply is the most recently opened database entries, most recent first, as an array.
//
pub fn getRecentDatabasesHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const recent = try databases_config.getRecentDatabases(context.arena, context.io());
    return try json_util.stringify(context.arena, recent);
}

//
// get-last-database: no payload. The reply is the path of the database to reopen on this launch, or null when none is open.
//
pub fn getLastDatabaseHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const last = try databases_config.getLastDatabase(context.arena, context.io());
    return try json_util.stringify(context.arena, last);
}

//
// remove-recent-database-name: the payload is a database name. Removes it from the recents only, not the database entry itself.
//
pub fn removeRecentDatabaseNameHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    if (data != .string) {
        return utils.errors.throwError("The database needs a name.", .{});
    }
    const name = data.string;
    try databases_config.removeRecentDatabaseName(context.arena, context.io(), name);
    log.event(try std.fmt.allocPrint(context.arena, "Recent database removed: {s}", .{name}));
    return try context.arena.dupe(u8, "null");
}
