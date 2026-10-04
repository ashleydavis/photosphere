//
// The example's file and folder pickers. They answer the same request channels, with the same data and replies, as the
// Electron app's pick-folder, pick-files and pick-file: a cancelled dialog is a reply of null, which Electron gives as
// undefined. Each runs as a task, because a dialog waits for the user and must not hold up the thread that handles page
// messages.
//

const std = @import("std");
const ziggy = @import("ziggy-core");

const TaskContext = ziggy.task_runner.TaskContext;
const json_util = ziggy.json_util;

//
// Shows a dialog and returns the first path chosen as a JSON string, or null when the user cancelled.
//
fn firstPath(context: *TaskContext, kind: ziggy.types.PickKind, title: ?[]const u8, initial_name: ?[]const u8) !?[]const u8 {
    const answer = try context.pickPaths(kind, title, initial_name);
    const paths = try std.json.parseFromSliceLeaky(std.json.Value, context.arena, answer, .{});
    if (paths != .array or paths.array.items.len == 0) {
        return try context.arena.dupe(u8, "null");
    }
    return try json_util.stringify(context.arena, paths.array.items[0]);
}

//
// pick-folder: data is an options object that may name a "title" (Electron's IPickFolderOptions), or null. The reply is the
// folder's path, or null.
//
pub fn pickFolderHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const title = json_util.getString(data, "title") orelse "Select Folder";
    return try firstPath(context, .folder, title, null);
}

//
// pick-files: data is the dialog's title, a string. The reply is the array of the paths chosen, or null.
//
pub fn pickFilesHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const title: []const u8 = if (data == .string) data.string else "Select Files";
    const answer = try context.pickPaths(.open_files, title, null);
    const paths = try std.json.parseFromSliceLeaky(std.json.Value, context.arena, answer, .{});
    if (paths != .array or paths.array.items.len == 0) {
        return try context.arena.dupe(u8, "null");
    }
    return answer;
}

//
// pick-file: a save dialog, as in Electron, where data is the suggested file name, a string. The reply is the path chosen to
// save to, or null.
//
pub fn pickFileHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const initial_name: []const u8 = if (data == .string) data.string else "";
    return try firstPath(context, .save_file, "Save As", initial_name);
}
