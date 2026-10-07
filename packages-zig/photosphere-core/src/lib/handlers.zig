//
// Every channel and task type Photosphere answers, in the order of the ipcMain handlers of apps/desktop/src/main.ts, and the
// function that turns an error into the text of an error reply. The app's own core package gives these to Ziggy's core, with
// its menu and its page.
//
// A handler that waits on something slow (the keychain, a file, a dialog) is a task type, and a channel in task_channels answers
// by running it, so that it does not hold up the thread that handles the page's messages.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");
const vault = @import("vault.zig");
const databases = @import("databases.zig");
const recents = @import("recents.zig");
const share_import = @import("share-import.zig");
const update_and_news = @import("update-and-news.zig");
const main_state = @import("main-state.zig");
const main_process = @import("main-process.zig");
const logging = @import("logging.zig");
const pickers = @import("pickers.zig");
const saving_assets = @import("saving-assets.zig");
const tools = @import("tools.zig");
const config_and_state = @import("config-and-state.zig");
const mobile_requests = @import("mobile-requests.zig");

//
// The channels Photosphere answers on the thread that handles the page's messages.
//
pub const channels = [_]ziggy.core.ChannelEntry{
    .{ .name = "fps-measurement", .handler = logging.fpsMeasurementHandler },
    .{ .name = "main-command", .handler = main_process.mainCommandHandler },
    .{ .name = "notify-database-edited", .handler = main_process.notifyDatabaseEditedHandler },
    .{ .name = "renderer-log", .handler = logging.rendererLogHandler },
};

//
// The channels Photosphere answers with a task, each by the task type of the same name.
//
pub const task_channels = [_]ziggy.core.TaskChannelEntry{
    .{ .name = "open-database", .task_type = "open-database" },
    .{ .name = "remove-database-entry", .task_type = "remove-database-entry" },
    .{ .name = "find-database", .task_type = "find-database" },
    .{ .name = "vault-get", .task_type = "vault-get" },
    .{ .name = "vault-set", .task_type = "vault-set" },
    .{ .name = "vault-delete", .task_type = "vault-delete" },
    .{ .name = "vault-list", .task_type = "vault-list" },
    .{ .name = "get-databases", .task_type = "get-databases" },
    .{ .name = "add-database", .task_type = "add-database" },
    .{ .name = "update-database", .task_type = "update-database" },
    .{ .name = "set-database-origin", .task_type = "set-database-origin" },
    .{ .name = "pick-folder", .task_type = "pick-folder" },
    .{ .name = "pick-file", .task_type = "pick-file" },
    .{ .name = "pick-files", .task_type = "pick-files" },
    .{ .name = "notify-database-opened", .task_type = "notify-database-opened" },
    .{ .name = "get-recent-databases", .task_type = "get-recent-databases" },
    .{ .name = "get-last-database", .task_type = "get-last-database" },
    .{ .name = "remove-recent-database-name", .task_type = "remove-recent-database-name" },
    .{ .name = "list-s3-dirs", .task_type = "list-s3-dirs" },
    .{ .name = "notify-database-closed", .task_type = "notify-database-closed" },
    .{ .name = "get-config", .task_type = "get-config" },
    .{ .name = "set-config", .task_type = "set-config" },
    .{ .name = "get-state", .task_type = "get-state" },
    .{ .name = "set-state", .task_type = "set-state" },
    .{ .name = "save-asset", .task_type = "save-asset-request" },
    .{ .name = "save-assets", .task_type = "save-assets" },
    .{ .name = "open-path", .task_type = "open-path" },
    .{ .name = "get-log-details", .task_type = "get-log-details" },
    .{ .name = "import-share-payload", .task_type = "import-share-payload" },
    .{ .name = "check-tools", .task_type = "check-tools" },
    .{ .name = "mark-update-shown", .task_type = "mark-update-shown" },
    .{ .name = "mark-news-shown", .task_type = "mark-news-shown" },
    .{ .name = "requestMediaPermission", .task_type = "requestMediaPermission" },
    .{ .name = "exportFile", .task_type = "exportFile" },
    .{ .name = "exportFiles", .task_type = "exportFiles" },
    .{ .name = "startBackgroundImport", .task_type = "startBackgroundImport" },
    .{ .name = "stopBackgroundImport", .task_type = "stopBackgroundImport" },
    .{ .name = "secureStoreGet", .task_type = "secureStoreGet" },
    .{ .name = "secureStoreSet", .task_type = "secureStoreSet" },
    .{ .name = "secureStoreDelete", .task_type = "secureStoreDelete" },
    .{ .name = "secureStoreKeys", .task_type = "secureStoreKeys" },
};

//
// The task types Photosphere's channels are answered by, and `ensure-auto-import`, which the main process queues itself.
//
pub const tasks = [_]ziggy.task_runner.TaskHandlerEntry{
    .{ .name = "open-database", .handler = pickers.openDatabaseHandler },
    .{ .name = "remove-database-entry", .handler = databases.removeDatabaseEntryHandler },
    .{ .name = "find-database", .handler = databases.findDatabaseHandler },
    .{ .name = "vault-get", .handler = vault.vaultGetHandler },
    .{ .name = "vault-set", .handler = vault.vaultSetHandler },
    .{ .name = "vault-delete", .handler = vault.vaultDeleteHandler },
    .{ .name = "vault-list", .handler = vault.vaultListHandler },
    .{ .name = "get-databases", .handler = databases.getDatabasesHandler },
    .{ .name = "add-database", .handler = databases.addDatabaseHandler },
    .{ .name = "update-database", .handler = databases.updateDatabaseHandler },
    .{ .name = "set-database-origin", .handler = databases.setDatabaseOriginHandler },
    .{ .name = "pick-folder", .handler = pickers.pickFolderHandler },
    .{ .name = "pick-file", .handler = pickers.pickFileHandler },
    .{ .name = "pick-files", .handler = pickers.pickFilesHandler },
    .{ .name = "notify-database-opened", .handler = main_process.notifyDatabaseOpenedHandler },
    .{ .name = "get-recent-databases", .handler = recents.getRecentDatabasesHandler },
    .{ .name = "get-last-database", .handler = recents.getLastDatabaseHandler },
    .{ .name = "remove-recent-database-name", .handler = recents.removeRecentDatabaseNameHandler },
    .{ .name = "list-s3-dirs", .handler = databases.listS3DirsHandler },
    .{ .name = "notify-database-closed", .handler = main_process.notifyDatabaseClosedHandler },
    .{ .name = "get-config", .handler = config_and_state.getConfigHandler },
    .{ .name = "set-config", .handler = config_and_state.setConfigHandler },
    .{ .name = "get-state", .handler = config_and_state.getStateHandler },
    .{ .name = "set-state", .handler = config_and_state.setStateHandler },
    .{ .name = "save-asset-request", .handler = saving_assets.saveAssetHandler },
    .{ .name = "save-assets", .handler = saving_assets.saveAssetsHandler },
    .{ .name = "open-path", .handler = saving_assets.openPathHandler },
    .{ .name = "get-log-details", .handler = logging.getLogDetailsHandler },
    .{ .name = "import-share-payload", .handler = share_import.importSharePayloadHandler },
    .{ .name = "check-tools", .handler = tools.checkToolsHandler },
    .{ .name = "mark-update-shown", .handler = update_and_news.markUpdateShownHandler },
    .{ .name = "mark-news-shown", .handler = update_and_news.markNewsShownHandler },
    .{ .name = "requestMediaPermission", .handler = mobile_requests.requestMediaPermissionHandler },
    .{ .name = "exportFile", .handler = mobile_requests.exportFileHandler },
    .{ .name = "exportFiles", .handler = mobile_requests.exportFilesHandler },
    .{ .name = "startBackgroundImport", .handler = mobile_requests.startBackgroundImportHandler },
    .{ .name = "stopBackgroundImport", .handler = mobile_requests.stopBackgroundImportHandler },
    .{ .name = "secureStoreGet", .handler = mobile_requests.secureStoreGetHandler },
    .{ .name = "secureStoreSet", .handler = mobile_requests.secureStoreSetHandler },
    .{ .name = "secureStoreDelete", .handler = mobile_requests.secureStoreDeleteHandler },
    .{ .name = "secureStoreKeys", .handler = mobile_requests.secureStoreKeysHandler },
    .{ .name = "ensure-auto-import", .handler = main_process.ensureAutoImportTask },
};

//
// Gives the text of the error reply for an error a handler returned, in words the user can act on. A thrown error gives the message
// the code that failed recorded, which is what the page showed when the same handler threw in the Electron app. An error the
// operating system or the allocator returned gives a sentence for the common ones. Any other error is not described, so the reply carries its name.
//
pub fn describeError(err: anyerror) ?[]const u8 {
    if (err == error.Thrown or err == error.FatalError) {
        return utils.errors.errorMessage(err);
    }
    return switch (err) {
        error.FileNotFound => "A file or folder the request needs was not found.",
        error.AccessDenied => "Photosphere is not allowed to read or write a file or folder the request needs.",
        error.PermissionDenied => "Photosphere is not allowed to read or write a file or folder the request needs.",
        error.OutOfMemory => "Photosphere ran out of memory.",
        error.NoSpaceLeft => "There is no space left on the disk.",
        error.DiskQuota => "There is no space left on the disk.",
        error.ConnectionRefused => "The server refused the connection.",
        error.ConnectionTimedOut => "The connection to the server timed out.",
        error.NetworkUnreachable => "The network cannot be reached.",
        error.Cancelled => "The request was cancelled.",
        else => null,
    };
}

//
// Everything Photosphere gives Ziggy's core, with the app's menu and page. The app's own core package and the tests both build the
// core's handlers with it.
//
pub fn appHandlers(menu_json: []const u8, ui_files: []const ziggy.ui_files.UiFile) ziggy.core.AppHandlers {
    return .{
        .channels = &channels,
        .tasks = &tasks,
        .task_channels = &task_channels,
        .menu_json = menu_json,
        .ui_files = ui_files,
        .describe_error = describeError,
        .state = main_state.state_hooks,
        .on_task_end = main_process.onTaskEnd,
        .on_task_message = main_process.onTaskMessage,
    };
}
