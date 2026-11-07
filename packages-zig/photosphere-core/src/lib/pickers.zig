//
// The messages that show a file or folder dialog: pick-folder, pick-file, pick-files and open-database.
//
// Each is a task type, because a dialog waits for the user and the thread that handles the page's messages must not.
//
// What the page sees is JSON: a dialog the user cancelled is a reply of null.
//
// What the dialogs Ziggy shows through its native apps force:
//  - Ziggy's dialog request carries one string besides the title, the initial name, which is the suggested file name of a save
//    dialog and, for a dialog that opens a file or a folder, the folder to start in. A save dialog is therefore given the file
//    name only, without the remembered download folder.
//  - The "New Folder" button is not requested: the native apps' folder dialogs offer it themselves.
//  - The dialogs do not restore the main window if it is minimised or focus it. Ziggy's dialog request has no such step.
//
// In test mode the dialogs for the download folder and for the path to save to are answered by the environment variables
// PHOTOSPHERE_TEST_DOWNLOAD_FOLDER and PHOTOSPHERE_TEST_PICK_FILE_PATH, so a smoke test does not block on a
// native dialog.
//

const std = @import("std");
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const events = @import("events.zig");
const main_state = @import("main-state.zig");
const test_mode = @import("test-mode.zig");

const TaskContext = ziggy.task_runner.TaskContext;
const TaskServices = ziggy.task_runner.TaskServices;
const HandlerServices = ziggy.core.HandlerServices;
const Timers = ziggy.timers.Timers;
const json = ziggy.json;
const app_state = node_api.app_state;
const logExceptions = @import("log-exceptions.zig").logExceptions;

//
// Shows a dialog and returns the paths the user chose, an empty list when they cancelled.
//
fn pickedPaths(services: TaskServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers, kind: ziggy.types.PickKind, title: ?[]const u8, initial_name: ?[]const u8) ![]const []const u8 {
    const answer = try services.pickPaths(io, allocator, timers, kind, title, initial_name);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, answer, .{});
    if (parsed != .array) {
        return utils.errors.throwError("The dialog did not answer with a list of paths.", .{});
    }
    var paths: std.ArrayList([]const u8) = .empty;
    for (parsed.array.items) |item| {
        if (item != .string) {
            return utils.errors.throwError("The dialog did not answer with a list of paths.", .{});
        }
        try paths.append(allocator, item.string);
    }
    return paths.items;
}

//
// A string field of the payload, or null when it is missing or empty: an empty string counts as no value.
//
fn nonEmptyString(data: std.json.Value, name: []const u8) ?[]const u8 {
    const text = json.getString(data, name) orelse {
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
fn optionalPathReply(allocator: std.mem.Allocator, path: ?[]const u8) ![]const u8 {
    return try json.stringify(allocator, path);
}

//
// Opens a directory picker and returns the folder chosen, or null if the user cancelled. It starts in the last folder opened in a
// file dialog.
//
fn showDirectoryPicker(services: TaskServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers, title: []const u8) !?[]const u8 {
    const state = try app_state.loadAppState(allocator, io);
    const paths = try pickedPaths(services, io, allocator, timers, .folder, title, state.lastFolder);
    if (paths.len == 0) {
        return null;
    }
    return paths[0];
}

//
// Shows a folder dialog titled `title`, which starts in the folder remembered under `folder_key`, and remembers the folder chosen
// under that key. Returns the folder's path, or null when the user cancelled. The key must be one of
// the state keys that remember a folder.
//
// In test mode, PHOTOSPHERE_TEST_DOWNLOAD_FOLDER answers the dialog for the download folder, so the smoke test for downloading several
// assets does not block on a native dialog. Nothing is remembered when it does.
//
pub fn pickFolder(services: TaskServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers, title: []const u8, folder_key: []const u8) !?[]const u8 {
    if (test_mode.isTestMode() and std.mem.eql(u8, folder_key, "lastDownloadFolder")) {
        if (test_mode.envValue("PHOTOSPHERE_TEST_DOWNLOAD_FOLDER")) |download_folder| {
            return download_folder;
        }
    }
    const default_path = try app_state.getFolderPath(allocator, io, folder_key);
    const paths = try pickedPaths(services, io, allocator, timers, .folder, title, default_path);
    if (paths.len == 0) {
        return null;
    }
    const chosen = paths[0];
    try app_state.updateFolderPath(allocator, io, folder_key, chosen);
    return chosen;
}

//
// pick-folder: the payload is optional options, {title, folderKey, createDirectory}. Shows a folder dialog titled `title` ("Select
// Folder" when there is none), which starts in the folder remembered under `folderKey` ("lastFolder" when there is none), and
// remembers the folder chosen under that key. The reply is the folder's path, or null when the user cancelled.
//
fn pickFolderChannel(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
    const title = nonEmptyString(data, "title") orelse "Select Folder";
    const folder_key = nonEmptyString(data, "folderKey") orelse "lastFolder";
    return try optionalPathReply(allocator, try pickFolder(services, io, allocator, timers, title, folder_key));
}

//
// Shows a save dialog with a suggested file name, remembers the folder of the path chosen as the folder to download to, and returns
// the path, or null when the user cancelled.
//
// In test mode, PHOTOSPHERE_TEST_PICK_FILE_PATH answers the dialog, so the smoke test for downloading one asset does not block on a
// native dialog. Nothing is remembered when it does.
//
pub fn pickFile(services: TaskServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers, default_filename: []const u8) !?[]const u8 {
    if (test_mode.isTestMode()) {
        if (test_mode.envValue("PHOTOSPHERE_TEST_PICK_FILE_PATH")) |pick_file_path| {
            return pick_file_path;
        }
    }
    return try showSaveDialog(services, io, allocator, timers, default_filename);
}

//
// Shows a save dialog with a suggested file name, remembers the folder of the path chosen as the folder to download to, and returns
// the path, or null when the user cancelled. This is the dialog the pick-file message shows, and the one the save-asset handler
// shows for itself, which has no test mode answer.
//
pub fn showSaveDialog(services: TaskServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers, default_filename: []const u8) !?[]const u8 {
    const paths = try pickedPaths(services, io, allocator, timers, .save_file, null, default_filename);
    if (paths.len == 0) {
        return null;
    }
    const chosen = paths[0];
    try app_state.updateLastDownloadFolder(allocator, io, node_utils.path.dirname(chosen));
    return chosen;
}

//
// pick-file: the payload is the suggested file name. Replies with the path chosen in a save dialog, or null when the user cancelled.
//
fn pickFileChannel(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
    if (data != .string) {
        return utils.errors.throwError("The save dialog needs a suggested file name.", .{});
    }
    return try optionalPathReply(allocator, try pickFile(services, io, allocator, timers, data.string));
}

//
// pick-files: the payload is the dialog's title. Shows a dialog to choose several files, which starts in the last folder opened in a
// file dialog. The reply is the paths chosen, or null when the user cancelled.
//
fn pickFilesChannel(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
    if (data != .string) {
        return utils.errors.throwError("The file dialog needs a title.", .{});
    }
    const state = try app_state.loadAppState(allocator, io);
    const paths = try pickedPaths(services, io, allocator, timers, .open_files, data.string, state.lastFolder);
    if (paths.len == 0) {
        return try allocator.dupe(u8, "null");
    }
    return try json.stringify(allocator, paths);
}

//
// open-database: no payload. Shows a dialog to choose a database folder, remembers the folder that holds it, and tells the page to load
// it (the `database-opened` event). The reply is null.
//
fn openDatabase(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
    _ = data;
    const database_path = (try showDirectoryPicker(services, io, allocator, timers, "Open Database")) orelse {
        return try allocator.dupe(u8, "null");
    };
    try app_state.updateLastFolder(allocator, io, node_utils.path.dirname(database_path));

    // Tell the page to load the database. The asset server does not need to be restarted since it handles multiple databases
    // dynamically. The menu is updated when the page calls notify-database-opened.
    try events.sendDatabaseOpened(services, io, allocator, database_path);
    return try allocator.dupe(u8, "null");
}

//
// The pick-folder message's handler: pickFolderChannel, with its errors logged.
//
pub const pickFolderHandler = logExceptions(pickFolderChannel, "Error picking folder");

//
// The pick-file message's handler: pickFileChannel, with its errors logged.
//
pub const pickFileHandler = logExceptions(pickFileChannel, "Error picking save location");

//
// The pick-files message's handler: pickFilesChannel, with its errors logged.
//
pub const pickFilesHandler = logExceptions(pickFilesChannel, "Error picking files");

//
// The open-database message's handler: openDatabase, with its errors logged.
//
pub const openDatabaseHandler = logExceptions(openDatabase, "Error opening database");

//
// The data of open-database, which has none.
//
pub const NoRequest = struct {};

//
// The data of pick-folder: options the page may leave out, or null for none.
//
pub const PickFolderRequest = struct {
    // The dialog's title, or null for "Select Folder".
    title: ?[]const u8 = null,
    // The state key the folder is remembered under, or null for "lastFolder".
    folderKey: ?[]const u8 = null,
};

//
// pick-folder: answered by the pick-folder task. The response is the folder's path, or null when the user cancelled.
//
pub fn pickFolderMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: PickFolderRequest) !ziggy.core.Response(?[]const u8) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "pick-folder",
            .data = try json.stringify(allocator, request),
        },
    };
}

//
// pick-file: the data is the suggested file name, answered by the pick-file task. The response is the path chosen, or null.
//
pub fn pickFileMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, suggested_name: []const u8) !ziggy.core.Response(?[]const u8) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "pick-file",
            .data = try json.stringify(allocator, suggested_name),
        },
    };
}

//
// pick-files: the data is the dialog's title, answered by the pick-files task. The response is the paths chosen, or null.
//
pub fn pickFilesMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, title: []const u8) !ziggy.core.Response(?[]const []const u8) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "pick-files",
            .data = try json.stringify(allocator, title),
        },
    };
}

//
// open-database: answered by the open-database task, which shows the dialog and tells the page to load the database. The response
// is null.
//
pub fn openDatabaseMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: NoRequest) !ziggy.core.Response(void) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "open-database",
            .data = try json.stringify(allocator, request),
        },
    };
}
