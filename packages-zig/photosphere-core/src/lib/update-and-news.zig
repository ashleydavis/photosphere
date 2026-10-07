//
// The channels the page uses to say it has shown the user an update or a news item: mark-update-shown and mark-news-shown, from the
// ipcMain handlers of the same names in apps/desktop/src/main.ts. Each records the fact in the state file, so the same update or
// news item is not announced again at the next start.
//
// Each is a task type, because it writes a file.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");

const TaskContext = ziggy.task_runner.TaskContext;

//
// mark-update-shown: the payload is the version of the update the user has been shown. Records it as the last one shown.
//
pub fn markUpdateShownHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    if (data != .string) {
        return utils.errors.throwError("The request needs the version of the update that was shown.", .{});
    }
    try node_api.news_state.setLastShownUpdateVersion(context.arena, context.io(), data.string);
    utils.log.log.info(try std.fmt.allocPrint(context.arena, "Marked update notification as shown: v{s}", .{data.string}));
    return try context.arena.dupe(u8, "null");
}

//
// mark-news-shown: the payload is the id of the news item the user has been shown. Adds it to the ones shown.
//
pub fn markNewsShownHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    if (data != .string) {
        return utils.errors.throwError("The request needs the id of the news item that was shown.", .{});
    }
    try node_api.news_state.addShownNewsIds(context.arena, context.io(), &[_][]const u8{data.string});
    utils.log.log.info(try std.fmt.allocPrint(context.arena, "Marked news notification as shown: {s}", .{data.string}));
    return try context.arena.dupe(u8, "null");
}
