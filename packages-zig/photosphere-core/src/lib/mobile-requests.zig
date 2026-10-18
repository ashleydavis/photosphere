//
// The requests only a phone can answer: requestMediaPermission, exportFile, exportFiles, exportTempFolder, startBackgroundImport, stopBackgroundImport,
// and the secure store's get, set, delete and keys (secureStoreGet, secureStoreSet, secureStoreDelete and secureStoreKeys here).
//
// Each is a task type, because the phone's shell shows native interface (a permission prompt, a share sheet) and waits for the user, and
// the thread that handles the page's messages must not wait for that. Each asks the shell through the core's one host request callback,
// by the method's name, and passes the shell's answer to the page unchanged. A platform that has no such callback (every desktop) answers
// with an error that says so.
//
// A test can stage the outcome of the share sheet: exportFile and exportFiles pass a "testOutcome" ("shared" or "cancelled") on to the
// shell, which then skips its sheet and completes the export as that outcome. The request is passed on unchanged apart from that.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");
const background_work = @import("background-work.zig");

const TaskContext = ziggy.task_runner.TaskContext;
const json_util = ziggy.json_util;

//
// Asks the shell to do what the method names, and returns its answer, which is JSON text. A platform without the callback, a shell that
// cannot do it, and an answer that is not JSON are each an error with a sentence the user can act on.
//
fn askShell(context: *TaskContext, method: []const u8, request_json: []const u8) ![]const u8 {
    const answer = try background_work.askShell(context, method, request_json);
    _ = std.json.parseFromSliceLeaky(std.json.Value, context.arena, answer, .{}) catch {
        return utils.errors.throwError("The phone's answer to {s} could not be read.", .{method});
    };
    return answer;
}

//
// The text of a field the request must have, or an error that says which one is missing.
//
fn requiredString(data: std.json.Value, name: []const u8, method: []const u8) ![]const u8 {
    return json_util.getString(data, name) orelse {
        return utils.errors.throwError("{s} needs \"{s}\".", .{ method, name });
    };
}

//
// requestMediaPermission: no payload. Asks the user for access to the photo library. The reply is {granted, partial}, where partial is
// true when the user gave access to only the photos they picked (Android 14 and later).
//
pub fn requestMediaPermissionHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    return try askShell(context, "requestMediaPermission", "null");
}

//
// The staged test outcome of a request, or null when it has none. It must be text when it is there, so a malformed one is an error and
// not an export that quietly shows the sheet.
//
fn optionalTestOutcome(data: std.json.Value, method: []const u8) !?[]const u8 {
    const value = if (data == .object) data.object.get("testOutcome") else null;
    const present = value orelse {
        return null;
    };
    return switch (present) {
        .null => null,
        .string => |text| text,
        else => utils.errors.throwError("{s} needs \"testOutcome\" to be text.", .{method}),
    };
}

//
// exportFile: the payload is {path}, the sandbox-relative path of a finished file, and optionally {testOutcome}, the outcome a test
// staged in place of the sheet. Opens the share or save sheet for it and removes the temporary copy on every exit. The reply is {path},
// or {path: null} when the user cancelled the sheet.
//
pub fn exportFileHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const path = try requiredString(data, "path", "exportFile");
    if (try optionalTestOutcome(data, "exportFile")) |test_outcome| {
        return try askShell(context, "exportFile", try json_util.stringify(context.arena, .{
            .path = path,
            .testOutcome = test_outcome,
        }));
    }
    return try askShell(context, "exportFile", try json_util.stringify(context.arena, .{
        .path = path,
    }));
}

//
// exportFiles: the payload is {paths}, the sandbox-relative paths of several finished files, and optionally {testOutcome}, the outcome a
// test staged in place of the sheet. Opens one share or save sheet for all of them and removes the temporary copies on every exit. The
// reply is {paths}, or {paths: null} when the user cancelled the sheet.
//
pub fn exportFilesHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const paths_value = if (data == .object) data.object.get("paths") else null;
    const paths = paths_value orelse {
        return utils.errors.throwError("exportFiles needs \"paths\".", .{});
    };
    if (paths != .array) {
        return utils.errors.throwError("exportFiles needs \"paths\" to be a list of paths.", .{});
    }
    for (paths.array.items) |item| {
        if (item != .string) {
            return utils.errors.throwError("exportFiles needs \"paths\" to be a list of paths.", .{});
        }
    }
    if (try optionalTestOutcome(data, "exportFiles")) |test_outcome| {
        return try askShell(context, "exportFiles", try json_util.stringify(context.arena, .{
            .paths = paths,
            .testOutcome = test_outcome,
        }));
    }
    return try askShell(context, "exportFiles", try json_util.stringify(context.arena, .{
        .paths = paths,
    }));
}

//
// exportTempFolder: the payload is {folder}, a sandbox-relative folder for the files of one export. Asks the phone to make it, because
// the save tasks write to an absolute path in a folder that exists. The reply is {path}, the folder's absolute path.
//
pub fn exportTempFolderHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const folder = try requiredString(data, "folder", "exportTempFolder");
    return try askShell(context, "exportTempFolder", try json_util.stringify(context.arena, .{
        .folder = folder,
    }));
}

//
// startBackgroundImport: no payload. Starts the background work (automatic import, sync and prefetch), which keeps going with the app
// off screen. The notification permission is asked for here and nowhere else, because this is the moment the user switches the work on:
// nothing about it exists before that, and the work starts whatever the answer, because a foreground service without the permission
// still runs and it is only the notification that is missing. Starting it when it is already started does nothing. The reply is null.
//
pub fn startBackgroundImportHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const answer = try std.json.parseFromSliceLeaky(std.json.Value, context.arena, try askShell(context, "requestNotificationPermission", "null"), .{});
    const granted = if (answer == .object) answer.object.get("granted") else null;
    if (granted == null or granted.? != .bool) {
        return utils.errors.throwError("The phone's answer to requestNotificationPermission could not be read.", .{});
    }
    if (!granted.?.bool) {
        utils.log.log.info("Notifications were refused; the background import runs without its notification.");
    }
    background_work.startBackgroundWork(context);
    utils.log.log.info("Started the background automatic import.");
    return try context.arena.dupe(u8, "null");
}

//
// stopBackgroundImport: no payload. Stops the background work and the import, sync or prefetch in flight, leaving nothing behind. Safe
// to call when nothing is running. The reply is null.
//
pub fn stopBackgroundImportHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    background_work.stopBackgroundWork(context);
    utils.log.log.info("Stopped the background automatic import.");
    return try context.arena.dupe(u8, "null");
}

//
// secureStoreGet: the payload is {key}. The reply is {value}, where value is null when the key is absent.
//
pub fn secureStoreGetHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const key = try requiredString(data, "key", "secureStoreGet");
    return try askShell(context, "secureStoreGet", try json_util.stringify(context.arena, .{
        .key = key,
    }));
}

//
// secureStoreSet: the payload is {key, value}. Writes the item to the phone's keychain, or overwrites it. The reply is null.
//
pub fn secureStoreSetHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const key = try requiredString(data, "key", "secureStoreSet");
    const value = try requiredString(data, "value", "secureStoreSet");
    return try askShell(context, "secureStoreSet", try json_util.stringify(context.arena, .{
        .key = key,
        .value = value,
    }));
}

//
// secureStoreDelete: the payload is {key}. Deletes the item. A key that is not there is not an error. The reply is null.
//
pub fn secureStoreDeleteHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const key = try requiredString(data, "key", "secureStoreDelete");
    return try askShell(context, "secureStoreDelete", try json_util.stringify(context.arena, .{
        .key = key,
    }));
}

//
// secureStoreKeys: no payload. The reply is {keys}, every key in the phone's keychain.
//
pub fn secureStoreKeysHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    return try askShell(context, "secureStoreKeys", "null");
}
