//
// The channels that save assets to the user's disk and open a folder: save-asset, save-assets and open-path, from the ipcMain handlers of
// the same names in apps/desktop/src/main.ts.
//
// Each is a task type, because they show dialogs, wait for the tasks that write the files, and start the operating system's opener.
//
// Differences from the Electron app, forced by how Ziggy's tasks work:
//  - The Electron app queues the `save-asset` and `save-assets-batch` tasks with the database path as their source, so that opening
//    another database cancels them. save-assets needs to wait for the tasks that do the writing, so they are children of the task
//    answering the page's request, which take its source, and are cancelled with the request and not with the database. (save-asset
//    does not wait, and queues its task under the database path as the Electron app does.)
//  - save-asset takes one object, {assetId, assetType, filename, databasePath, destPath}, where the Electron handler took those as
//    five arguments, because a Ziggy request carries one payload. Only the main process's MCP tool calls it (the page calls
//    save-assets).
//

const std = @import("std");
const builtin = @import("builtin");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const pickers = @import("pickers.zig");
const main_state = @import("main-state.zig");

const TaskContext = ziggy.task_runner.TaskContext;
const json_util = ziggy.json_util;

//
// What a save-assets task of the page asks for: the assets to save, which one shows a Save As dialog and several show a folder
// dialog, and the database they live in.
//
const ISaveAssetsRequest = struct {
    // The assets to write (ISaveAssetItem).
    items: []const std.json.Value,
    // The database the assets live in.
    databasePath: []const u8,
};

//
// The one asset of a save-assets request that has only one.
//
const ISaveAssetItem = struct {
    // The id of the asset.
    assetId: []const u8,
    // The asset type to fetch (such as "asset").
    assetType: []const u8,
    // The original file name to save as.
    filename: []const u8,
};

//
// What the page is told when it asked for assets to be saved (ISaveAssetsResult).
//
const ISaveAssetsReply = struct {
    // "saved", "cancelled" or "failed".
    outcome: []const u8,
    // How many assets were written.
    savedCount: usize,
    // How many could not be written.
    failedCount: usize,
    // The folder the assets were written to, when they were saved.
    savedFolder: ?[]const u8 = null,
    // Why they were not saved, when they failed.
    errorMessage: ?[]const u8 = null,
};

//
// The result a save-assets-batch task gives.
//
const IBatchOutputs = struct {
    // The files that were written.
    succeededFiles: []const []const u8,
    // The files that could not be written.
    failedFiles: []const []const u8,
};

//
// Queues a task as a child of the one answering the request and waits for it to end (`runWorkerTask` of main.ts, which queues a task
// and resolves with its result).
//
fn runChildTask(context: *TaskContext, task_type: []const u8, data: anytype) !ziggy.types.Completion {
    const task_id = try context.queueChild(task_type, data);
    return try context.awaitTask(task_id);
}

//
// save-asset: the payload is {assetId, assetType, filename, databasePath, destPath}. When destPath is given (by the MCP save_media_file
// tool, which already has a path from the model) the save dialog is skipped and the asset is written straight to that path. When it is
// not, the user picks a path in a Save As dialog, and nothing is written when they cancel. The write is queued and not waited for.
//
pub fn saveAssetHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const item = try std.json.parseFromValueLeaky(ISaveAssetItem, context.arena, data, .{
        .ignore_unknown_fields = true,
    });
    const database_path = json_util.getString(data, "databasePath") orelse {
        return utils.errors.throwError("The asset to save needs the path of its database.", .{});
    };
    const given_dest_path: ?[]const u8 = if (json_util.getString(data, "destPath")) |dest_path| (if (dest_path.len > 0) dest_path else null) else null;
    const actual_dest_path: []const u8 = given_dest_path orelse (try pickers.pickFile(context, item.filename)) orelse {
        return try context.arena.dupe(u8, "null");
    };
    const state = main_state.fromContext(context);
    const save_data = try json_util.stringify(context.arena, .{
        .assetId = item.assetId,
        .assetType = item.assetType,
        .destPath = actual_dest_path,
        .databasePath = database_path,
    });
    const task_id = try state.uuid_generator.generate(context.arena, context.io());
    try state.core.runner.addTask(task_id, "save-asset", database_path, save_data, 0, null);
    return try context.arena.dupe(u8, "null");
}

//
// save-assets: the payload is {items, databasePath}. Shows the destination dialog (Save As for one asset, a folder dialog for several),
// writes the assets, and replies with what happened, so a download costs one round trip rather than picking a destination and then
// queueing the write separately.
//
pub fn saveAssetsHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const arena = context.arena;
    const request = try std.json.parseFromValueLeaky(ISaveAssetsRequest, arena, data, .{
        .ignore_unknown_fields = true,
    });
    if (request.items.len == 1) {
        const item = try std.json.parseFromValueLeaky(ISaveAssetItem, arena, request.items[0], .{
            .ignore_unknown_fields = true,
        });
        const dest_path = (try pickers.pickFile(context, item.filename)) orelse {
            return try json_util.stringify(arena, ISaveAssetsReply{
                .outcome = "cancelled",
                .savedCount = 0,
                .failedCount = 0,
            });
        };
        const completion = try runChildTask(context, "save-asset", .{
            .assetId = item.assetId,
            .assetType = item.assetType,
            .destPath = dest_path,
            .databasePath = request.databasePath,
        });
        if (completion.status != .succeeded) {
            return try json_util.stringify(arena, ISaveAssetsReply{
                .outcome = "failed",
                .savedCount = 0,
                .failedCount = 1,
                .errorMessage = completion.error_message,
            });
        }
        return try json_util.stringify(arena, ISaveAssetsReply{
            .outcome = "saved",
            .savedCount = 1,
            .failedCount = 0,
            .savedFolder = node_utils.path.dirname(dest_path),
        });
    }

    const folder_path = (try pickers.pickFolder(context, "Choose folder to save assets", "lastDownloadFolder")) orelse {
        return try json_util.stringify(arena, ISaveAssetsReply{
            .outcome = "cancelled",
            .savedCount = 0,
            .failedCount = 0,
        });
    };
    const completion = try runChildTask(context, "save-assets-batch", .{
        .assets = request.items,
        .folderPath = folder_path,
        .databasePath = request.databasePath,
    });
    if (completion.status != .succeeded) {
        return try json_util.stringify(arena, ISaveAssetsReply{
            .outcome = "failed",
            .savedCount = 0,
            .failedCount = request.items.len,
            .errorMessage = completion.error_message,
        });
    }
    const outputs = try std.json.parseFromSliceLeaky(IBatchOutputs, arena, completion.result_json orelse "null", .{
        .ignore_unknown_fields = true,
    });
    return try json_util.stringify(arena, ISaveAssetsReply{
        .outcome = "saved",
        .savedCount = outputs.succeededFiles.len,
        .failedCount = outputs.failedFiles.len,
        .savedFolder = folder_path,
    });
}

//
// open-path: the payload is the path of a folder. Opens it in the operating system's file manager, as `shell.openPath` of Electron does.
// (Zig: a file manager that cannot be started is an error, where Electron's `shell.openPath` answered with a message that the handler
// ignored.)
//
pub fn openPathHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    if (data != .string) {
        return utils.errors.throwError("The folder to open needs a path.", .{});
    }
    const opener: []const u8 = switch (builtin.os.tag) {
        .macos => "open",
        .windows => "explorer.exe",
        else => "xdg-open",
    };
    const argv = [_][]const u8{ opener, data.string };
    var child = std.process.spawn(context.io(), .{
        .argv = &argv,
        .environ_map = node_utils.process_env.getEnvironMap(),
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        return utils.errors.throwError("The folder \"{s}\" could not be opened, because {s} could not be started: {s}", .{ data.string, opener, @errorName(err) });
    };
    // The opener starts the file manager and ends, and its exit code says nothing the user can act on (Explorer exits with 1 after
    // it has opened a folder), so it is waited for only so that it does not stay behind as a zombie.
    _ = try child.wait(context.io());
    return try context.arena.dupe(u8, "null");
}
