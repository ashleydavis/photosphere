//
// The requests only a phone can answer: requestMediaPermission, exportFile, exportFiles, startBackgroundImport, stopBackgroundImport,
// and the secure store's get, set, delete and keys (secureStoreGet, secureStoreSet, secureStoreDelete and secureStoreKeys here). They
// are the methods of the `JsEngine` and `SecureStore` Capacitor plugins of packages/mobile-frontend/src/lib (js-engine-plugin.ts and
// secure-store-plugin.ts), under the same names and with the same arguments and answers.
//
// Each is a task type, because the phone's shell shows native interface (a permission prompt, a share sheet) and waits for the user, and
// the thread that handles the page's messages must not wait for that. Each asks the shell through the core's one host request callback,
// by the method's name, and passes the shell's answer to the page unchanged. A platform that has no such callback (every desktop) answers
// with an error that says so.
//
// Differences from the Capacitor apps:
//  - The `testOutcome` option of exportFile and exportFiles, which lets a test skip the share sheet, is not passed on. A test answers a
//    native dialog through the test hooks Ziggy provides.
//  - `stageMediaDeleteOutcome` of the JsEngine plugin, which only a test calls, is not a request here, for the same reason.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");

const TaskContext = ziggy.task_runner.TaskContext;
const json_util = ziggy.json_util;

//
// Asks the shell to do what the method names, and returns its answer, which is JSON text. A platform without the callback, a shell that
// cannot do it, and an answer that is not JSON are each an error with a sentence the user can act on.
//
fn askShell(context: *TaskContext, method: []const u8, request_json: []const u8) ![]const u8 {
    const reply = context.hostRequest(method, request_json) catch |err| {
        if (err == error.HostCallbackMissing) {
            return utils.errors.throwError("{s} is only available in the Photosphere app on a phone.", .{method});
        }
        return err;
    };
    if (!reply.succeeded) {
        return utils.errors.throwError("{s}", .{reply.text});
    }
    _ = std.json.parseFromSliceLeaky(std.json.Value, context.arena, reply.text, .{}) catch {
        return utils.errors.throwError("The phone's answer to {s} could not be read.", .{method});
    };
    return reply.text;
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
// exportFile: the payload is {path}, the sandbox-relative path of a finished file. Opens the share or save sheet for it and removes the
// temporary copy on every exit. The reply is {path}, or {path: null} when the user cancelled the sheet.
//
pub fn exportFileHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const path = try requiredString(data, "path", "exportFile");
    return try askShell(context, "exportFile", try json_util.stringify(context.arena, .{
        .path = path,
    }));
}

//
// exportFiles: the payload is {paths}, the sandbox-relative paths of several finished files. Opens one share or save sheet for all of
// them and removes the temporary copies on every exit. The reply is {paths}, or {paths: null} when the user cancelled the sheet.
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
    return try askShell(context, "exportFiles", try json_util.stringify(context.arena, .{
        .paths = paths,
    }));
}

//
// startBackgroundImport: no payload. Starts the background automatic import, which keeps going with the app off screen. Starting it
// when it is already started does nothing. The reply is null.
//
pub fn startBackgroundImportHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    return try askShell(context, "startBackgroundImport", "null");
}

//
// stopBackgroundImport: no payload. Stops the background automatic import and the import in flight, leaving nothing behind. Safe to
// call when nothing is running. The reply is null.
//
pub fn stopBackgroundImportHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    return try askShell(context, "stopBackgroundImport", "null");
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
