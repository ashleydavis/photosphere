//
// The channels that show a file or folder dialog: pick-folder, pick-file, pick-files and open-database, from the ipcMain handlers of
// apps/desktop/src/main.ts of the same names and the functions beside them (pickFolder and pickFile of apps/desktop/src/lib/pickers.ts,
// showDirectoryPicker, showFilePicker and openDatabase of main.ts).
//
// Each is a task type, because a dialog waits for the user and the thread that handles the page's messages must not.
//
// What the page sees is what Electron sends back, in JSON: a dialog the user cancelled is a reply of null, where Electron replies
// undefined.
//
// Differences from the Electron app, forced by the dialogs Ziggy shows through its shells:
//  - The Electron dialogs start in the folder remembered in the state file (`defaultPath`). Ziggy's dialog request carries one string
//    besides the title, the initial name, which is the suggested file name of a save dialog and, for a dialog that opens a file or a
//    folder, the folder to start in. A save dialog is therefore given the file name only, without the remembered download folder.
//  - Electron's `createDirectory` option (the "New Folder" button) is not passed: the shells' folder dialogs offer it themselves.
//  - The Electron dialogs first restore the main window if it is minimised and focus it. Ziggy's dialog request has no such step.
//  - The environment variables the Electron app reads in test mode to answer a dialog (PHOTOSPHERE_TEST_DOWNLOAD_FOLDER and
//    PHOTOSPHERE_TEST_PICK_FILE_PATH) are not read. A test answers a dialog through the test hooks Ziggy provides.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const events = @import("events.zig");
const main_state = @import("main-state.zig");

const TaskContext = ziggy.task_runner.TaskContext;
const json_util = ziggy.json_util;
const app_state = node_api.app_state;

//
// Shows a dialog and returns the paths the user chose, an empty list when they cancelled.
//
fn pickedPaths(context: *TaskContext, kind: ziggy.types.PickKind, title: ?[]const u8, initial_name: ?[]const u8) ![]const []const u8 {
    const answer = try context.pickPaths(kind, title, initial_name);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, context.arena, answer, .{});
    if (parsed != .array) {
        return utils.errors.throwError("The dialog did not answer with a list of paths.", .{});
    }
    var paths: std.ArrayList([]const u8) = .empty;
    for (parsed.array.items) |item| {
        if (item != .string) {
            return utils.errors.throwError("The dialog did not answer with a list of paths.", .{});
        }
        try paths.append(context.arena, item.string);
    }
    return paths.items;
}

//
// A string field of the payload, or null when it is missing or empty, as `options?.title || 'Select Folder'` of pickers.ts treats
// an empty string as no value.
//
fn nonEmptyString(data: std.json.Value, name: []const u8) ?[]const u8 {
    const text = json_util.getString(data, name) orelse {
        return null;
    };
    if (text.len == 0) {
        return null;
    }
    return text;
}

//
// A path as the JSON text of the reply, or "null" for no path (`undefined`).
//
fn optionalPathReply(arena: std.mem.Allocator, path: ?[]const u8) ![]const u8 {
    return try json_util.stringify(arena, path);
}

//
// Opens a directory picker and returns the folder chosen, or null if the user cancelled. It starts in the last folder opened in a
// file dialog (`showDirectoryPicker` of main.ts).
//
fn showDirectoryPicker(context: *TaskContext, title: []const u8) !?[]const u8 {
    const state = try app_state.loadAppState(context.arena, context.io());
    const paths = try pickedPaths(context, .folder, title, state.lastFolder);
    if (paths.len == 0) {
        return null;
    }
    return paths[0];
}

//
// Shows a folder dialog titled `title`, which starts in the folder remembered under `folder_key`, and remembers the folder chosen
// under that key. Returns the folder's path, or null when the user cancelled (`pickFolder` of pickers.ts). The key must be one of
// the state keys that remember a folder.
//
pub fn pickFolder(context: *TaskContext, title: []const u8, folder_key: []const u8) !?[]const u8 {
    const default_path = try app_state.getFolderPath(context.arena, context.io(), folder_key);
    const paths = try pickedPaths(context, .folder, title, default_path);
    if (paths.len == 0) {
        return null;
    }
    const chosen = paths[0];
    try app_state.updateFolderPath(context.arena, context.io(), folder_key, chosen);
    return chosen;
}

//
// pick-folder: the payload is optional options, {title, folderKey, createDirectory}. Shows a folder dialog titled `title` ("Select
// Folder" when there is none), which starts in the folder remembered under `folderKey` ("lastFolder" when there is none), and
// remembers the folder chosen under that key. The reply is the folder's path, or null when the user cancelled.
//
pub fn pickFolderHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const title = nonEmptyString(data, "title") orelse "Select Folder";
    const folder_key = nonEmptyString(data, "folderKey") orelse "lastFolder";
    return try optionalPathReply(context.arena, try pickFolder(context, title, folder_key));
}

//
// Shows a save dialog with a suggested file name, remembers the folder of the path chosen as the folder to download to, and returns
// the path, or null when the user cancelled (`pickFile` of pickers.ts).
//
pub fn pickFile(context: *TaskContext, default_filename: []const u8) !?[]const u8 {
    const paths = try pickedPaths(context, .save_file, null, default_filename);
    if (paths.len == 0) {
        return null;
    }
    const chosen = paths[0];
    try app_state.updateLastDownloadFolder(context.arena, context.io(), node_utils.path.dirname(chosen));
    return chosen;
}

//
// pick-file: the payload is the suggested file name. Replies with the path chosen in a save dialog, or null when the user cancelled.
//
pub fn pickFileHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    if (data != .string) {
        return utils.errors.throwError("The save dialog needs a suggested file name.", .{});
    }
    return try optionalPathReply(context.arena, try pickFile(context, data.string));
}

//
// pick-files: the payload is the dialog's title. Shows a dialog to choose several files, which starts in the last folder opened in a
// file dialog. The reply is the paths chosen, or null when the user cancelled (`showFilePicker` of main.ts).
//
pub fn pickFilesHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    if (data != .string) {
        return utils.errors.throwError("The file dialog needs a title.", .{});
    }
    const state = try app_state.loadAppState(context.arena, context.io());
    const paths = try pickedPaths(context, .open_files, data.string, state.lastFolder);
    if (paths.len == 0) {
        return try context.arena.dupe(u8, "null");
    }
    return try json_util.stringify(context.arena, paths);
}

//
// open-database: no payload. Shows a dialog to choose a database folder, remembers the folder that holds it, and tells the page to load
// it (the `database-opened` event). The reply is null (`openDatabase` of main.ts).
//
pub fn openDatabaseHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const database_path = (try showDirectoryPicker(context, "Open Database")) orelse {
        return try context.arena.dupe(u8, "null");
    };
    try app_state.updateLastFolder(context.arena, context.io(), node_utils.path.dirname(database_path));

    // Tell the page to load the database. The asset server does not need to be restarted since it handles multiple databases
    // dynamically. The menu is updated when the page calls notify-database-opened.
    try events.sendDatabaseOpened(main_state.fromContext(context).core, context.arena, database_path);
    return try context.arena.dupe(u8, "null");
}
