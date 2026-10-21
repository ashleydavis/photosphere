//
// The recent-database messages: get-recent-databases, get-last-database and remove-recent-database-name. They read and write the recents and the last database in databases.toml.
//
// Each is a task type, because they read and write a file, and the thread that handles the page's messages must not wait for that.
//
// What the page sees is JSON: get-last-database replies with the path, or null when no database is open, and
// remove-recent-database-name replies with null.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");

const TaskContext = ziggy.task_runner.TaskContext;
const json = ziggy.json;
const databases_config = node_api.databases_config;
const log = &utils.log.log;
const logExceptions = @import("log-exceptions.zig").logExceptions;

//
// get-recent-databases: no payload. The reply is the most recently opened database entries, most recent first, as an array.
//
fn getRecentDatabases(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const recent = try databases_config.getRecentDatabases(context.arena, context.io());
    return try json.stringify(context.arena, recent);
}

//
// get-last-database: no payload. The reply is the path of the database to reopen on this launch, or null when none is open.
//
fn getLastDatabase(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const last = try databases_config.getLastDatabase(context.arena, context.io());
    return try json.stringify(context.arena, last);
}

//
// remove-recent-database-name: the payload is a database name. Removes it from the recents only, not the database entry itself.
//
fn removeRecentDatabaseName(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    if (data != .string) {
        return utils.errors.throwError("The database needs a name.", .{});
    }
    const name = data.string;
    try databases_config.removeRecentDatabaseName(context.arena, context.io(), name);
    log.event(try std.fmt.allocPrint(context.arena, "Recent database removed: {s}", .{name}));
    return try context.arena.dupe(u8, "null");
}

//
// The get-recent-databases message's handler: getRecentDatabases, with its errors logged.
//
pub const getRecentDatabasesHandler = logExceptions(getRecentDatabases, "Error getting recent databases");

//
// The get-last-database message's handler: getLastDatabase, with its errors logged.
//
pub const getLastDatabaseHandler = logExceptions(getLastDatabase, "Error getting the last database");

//
// The remove-recent-database-name message's handler: removeRecentDatabaseName, with its errors logged.
//
pub const removeRecentDatabaseNameHandler = logExceptions(removeRecentDatabaseName, "Error removing recent database name");

//
// The data of get-recent-databases and get-last-database, which have none.
//
pub const NoRequest = struct {};

//
// get-recent-databases: answered by the get-recent-databases task. The response is the most recently opened database entries.
//
pub fn getRecentDatabasesMessageHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: NoRequest) !ziggy.core.Answer([]const databases_config.IDatabaseEntry) {
    _ = core;
    return .{
        .task = .{
            .task_type = "get-recent-databases",
            .data = try json.stringify(arena, request),
        },
    };
}

//
// get-last-database: answered by the get-last-database task. The response is the path of the database to reopen, or null.
//
pub fn getLastDatabaseMessageHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: NoRequest) !ziggy.core.Answer(?[]const u8) {
    _ = core;
    return .{
        .task = .{
            .task_type = "get-last-database",
            .data = try json.stringify(arena, request),
        },
    };
}

//
// remove-recent-database-name: the data is a database name, answered by the remove-recent-database-name task. The response is null.
//
pub fn removeRecentDatabaseNameMessageHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, name: []const u8) !ziggy.core.Answer(void) {
    _ = core;
    return .{
        .task = .{
            .task_type = "remove-recent-database-name",
            .data = try json.stringify(arena, name),
        },
    };
}
