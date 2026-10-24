//
// The requests only a phone can answer: requestMediaPermission, exportFile, exportFiles, exportTempFolder, startBackgroundImport, stopBackgroundImport,
// and the secure store's get, set, delete and keys (secureStoreGet, secureStoreSet, secureStoreDelete and secureStoreKeys here).
//
// Each is a task type, because the phone's native app shows native interface (a permission prompt, a share sheet) and waits for the
// user, and the thread that handles the page's messages must not wait for that. Each calls the native app through the core's one native
// call callback, by the method's name, and passes the native app's result to the page unchanged. A platform that has no such
// callback answers with an error that says so, except that on Windows, whose native app has none, the core answers
// startBackgroundImport's notification permission itself (windows-native-calls.zig).
//
// A test can stage the outcome of the share sheet: exportFile and exportFiles pass a "testOutcome" ("shared" or "cancelled") on to the
// native app, which then skips its sheet and completes the export as that outcome. The request is passed on unchanged apart from that.
//

const std = @import("std");
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const background_work = @import("background-work.zig");
const main_state = @import("main-state.zig");

const TaskContext = ziggy.task_runner.TaskContext;
const TaskServices = ziggy.task_runner.TaskServices;
const HandlerServices = ziggy.core.HandlerServices;
const Timers = ziggy.timers.Timers;
const json = ziggy.json;

//
// Calls the native app to do what the method names, and returns its result, which is JSON text. A platform without the callback, a
// native app that cannot do it, and a result that is not JSON are each an error with a sentence the user can act on.
//
fn callNativeApp(services: TaskServices, io: std.Io, allocator: std.mem.Allocator, timers: Timers, method: []const u8, request_json: []const u8) ![]const u8 {
    const result = try background_work.callNativeApp(services, io, allocator, timers, method, request_json);
    _ = std.json.parseFromSliceLeaky(std.json.Value, allocator, result, .{}) catch {
        return utils.errors.throwError("The phone's answer to {s} could not be read.", .{method});
    };
    return result;
}

//
// The text of a field the request must have, or an error that says which one is missing.
//
fn requiredString(data: std.json.Value, name: []const u8, method: []const u8) ![]const u8 {
    return json.getString(data, name) orelse {
        return utils.errors.throwError("{s} needs \"{s}\".", .{ method, name });
    };
}

//
// requestMediaPermission: no payload. Asks the user for access to the photo library. The reply is {granted, partial}, where partial is
// true when the user gave access to only the photos they picked (Android 14 and later).
//
pub fn requestMediaPermissionHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
    _ = data;
    return try callNativeApp(services, io, allocator, timers, "requestMediaPermission", "null");
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
pub fn exportFileHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
    const path = try requiredString(data, "path", "exportFile");
    if (try optionalTestOutcome(data, "exportFile")) |test_outcome| {
        return try callNativeApp(services, io, allocator, timers, "exportFile", try json.stringify(allocator, .{
            .path = path,
            .testOutcome = test_outcome,
        }));
    }
    return try callNativeApp(services, io, allocator, timers, "exportFile", try json.stringify(allocator, .{
        .path = path,
    }));
}

//
// exportFiles: the payload is {paths}, the sandbox-relative paths of several finished files, and optionally {testOutcome}, the outcome a
// test staged in place of the sheet. Opens one share or save sheet for all of them and removes the temporary copies on every exit. The
// reply is {paths}, or {paths: null} when the user cancelled the sheet.
//
pub fn exportFilesHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
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
        return try callNativeApp(services, io, allocator, timers, "exportFiles", try json.stringify(allocator, .{
            .paths = paths,
            .testOutcome = test_outcome,
        }));
    }
    return try callNativeApp(services, io, allocator, timers, "exportFiles", try json.stringify(allocator, .{
        .paths = paths,
    }));
}

//
// exportTempFolder: the payload is {folder}, a sandbox-relative folder for the files of one export. Asks the phone to make it, because
// the save tasks write to an absolute path in a folder that exists. The reply is {path}, the folder's absolute path.
//
pub fn exportTempFolderHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
    const folder = try requiredString(data, "folder", "exportTempFolder");
    return try callNativeApp(services, io, allocator, timers, "exportTempFolder", try json.stringify(allocator, .{
        .folder = folder,
    }));
}

//
// startBackgroundImport: no payload. Starts the background work (automatic import, sync and prefetch), which keeps going with the app
// off screen. The notification permission is asked for here and nowhere else, because this is the moment the user switches the work on:
// nothing about it exists before that, and the work starts whatever the answer, because a foreground service without the permission
// still runs and it is only the notification that is missing. Starting it when it is already started does nothing. The reply is null.
//
pub fn startBackgroundImportHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
    _ = data;
    const result = try std.json.parseFromSliceLeaky(std.json.Value, allocator, try callNativeApp(services, io, allocator, timers, "requestNotificationPermission", "null"), .{});
    const granted = if (result == .object) result.object.get("granted") else null;
    if (granted == null or granted.? != .bool) {
        return utils.errors.throwError("The phone's answer to requestNotificationPermission could not be read.", .{});
    }
    if (!granted.?.bool) {
        utils.log.log.info("Notifications were refused; the background import runs without its notification.");
    }
    // The main thread switches the work on when this task ends (see main-process.zig), and logs it.
    return try allocator.dupe(u8, "null");
}

//
// secureStoreGet: the payload is {key}. The reply is {value}, where value is null when the key is absent.
//
pub fn secureStoreGetHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
    const key = try requiredString(data, "key", "secureStoreGet");
    return try callNativeApp(services, io, allocator, timers, "secureStoreGet", try json.stringify(allocator, .{
        .key = key,
    }));
}

//
// secureStoreSet: the payload is {key, value}. Writes the item to the phone's keychain, or overwrites it. The reply is null.
//
pub fn secureStoreSetHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
    const key = try requiredString(data, "key", "secureStoreSet");
    const value = try requiredString(data, "value", "secureStoreSet");
    return try callNativeApp(services, io, allocator, timers, "secureStoreSet", try json.stringify(allocator, .{
        .key = key,
        .value = value,
    }));
}

//
// secureStoreDelete: the payload is {key}. Deletes the item. A key that is not there is not an error. The reply is null.
//
pub fn secureStoreDeleteHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
    const key = try requiredString(data, "key", "secureStoreDelete");
    return try callNativeApp(services, io, allocator, timers, "secureStoreDelete", try json.stringify(allocator, .{
        .key = key,
    }));
}

//
// secureStoreKeys: no payload. The reply is {keys}, every key in the phone's keychain.
//
pub fn secureStoreKeysHandler(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = context;
    _ = data;
    return try callNativeApp(services, io, allocator, timers, "secureStoreKeys", "null");
}

//
// The data of requestMediaPermission, startBackgroundImport, stopBackgroundImport and secureStoreKeys, which have none.
//
pub const NoRequest = struct {};

//
// requestMediaPermission: answered by the requestMediaPermission task. The response is the phone's answer, {granted, partial}.
//
pub fn requestMediaPermissionMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: NoRequest) !ziggy.core.Response(std.json.Value) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "requestMediaPermission",
            .data = try json.stringify(allocator, request),
        },
    };
}

//
// The data of exportFile.
//
pub const ExportFileRequest = struct {
    // The sandbox-relative path of the finished file.
    path: []const u8,
    // The outcome a test staged in place of the sheet ("shared" or "cancelled"), or null.
    testOutcome: ?[]const u8 = null,
};

//
// exportFile: answered by the exportFile task. The response is the phone's answer, {path}.
//
pub fn exportFileMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: ExportFileRequest) !ziggy.core.Response(std.json.Value) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "exportFile",
            .data = try json.stringify(allocator, request),
        },
    };
}

//
// The data of exportFiles.
//
pub const ExportFilesRequest = struct {
    // The sandbox-relative paths of the finished files.
    paths: []const []const u8,
    // The outcome a test staged in place of the sheet ("shared" or "cancelled"), or null.
    testOutcome: ?[]const u8 = null,
};

//
// exportFiles: answered by the exportFiles task. The response is the phone's answer, {paths}.
//
pub fn exportFilesMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: ExportFilesRequest) !ziggy.core.Response(std.json.Value) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "exportFiles",
            .data = try json.stringify(allocator, request),
        },
    };
}

//
// The data of exportTempFolder.
//
pub const ExportTempFolderRequest = struct {
    // The sandbox-relative folder for the files of one export.
    folder: []const u8,
};

//
// exportTempFolder: answered by the exportTempFolder task. The response is the phone's answer, {path}.
//
pub fn exportTempFolderMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: ExportTempFolderRequest) !ziggy.core.Response(std.json.Value) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "exportTempFolder",
            .data = try json.stringify(allocator, request),
        },
    };
}

//
// startBackgroundImport: answered by the startBackgroundImport task. The response is null.
//
pub fn startBackgroundImportMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: NoRequest) !ziggy.core.Response(void) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "startBackgroundImport",
            .data = try json.stringify(allocator, request),
        },
    };
}

//
// stopBackgroundImport: no payload. Stops the background work and the import, sync or prefetch in flight, leaving nothing behind, on the
// main thread, which owns it. Safe to call when nothing is running. The response is null.
//
pub fn stopBackgroundImportMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, _: std.mem.Allocator, request: NoRequest) !void {
    _ = request;
    main_state.current().stopBackgroundWork(services, timers, io, main_state.stateAllocator());
    utils.log.log.info("Stopped the background automatic import.");
}

//
// The data of secureStoreGet and secureStoreDelete.
//
pub const SecureStoreKeyRequest = struct {
    // The key of the item in the phone's keychain.
    key: []const u8,
};

//
// The data of secureStoreSet.
//
pub const SecureStoreSetRequest = struct {
    // The key of the item in the phone's keychain.
    key: []const u8,
    // The value to store under it.
    value: []const u8,
};

//
// secureStoreGet: answered by the secureStoreGet task. The response is the phone's answer, {value}.
//
pub fn secureStoreGetMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: SecureStoreKeyRequest) !ziggy.core.Response(std.json.Value) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "secureStoreGet",
            .data = try json.stringify(allocator, request),
        },
    };
}

//
// secureStoreSet: answered by the secureStoreSet task. The response is the phone's answer.
//
pub fn secureStoreSetMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: SecureStoreSetRequest) !ziggy.core.Response(std.json.Value) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "secureStoreSet",
            .data = try json.stringify(allocator, request),
        },
    };
}

//
// secureStoreDelete: answered by the secureStoreDelete task. The response is the phone's answer.
//
pub fn secureStoreDeleteMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: SecureStoreKeyRequest) !ziggy.core.Response(std.json.Value) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "secureStoreDelete",
            .data = try json.stringify(allocator, request),
        },
    };
}

//
// secureStoreKeys: answered by the secureStoreKeys task. The response is the phone's answer, {keys}.
//
pub fn secureStoreKeysMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: NoRequest) !ziggy.core.Response(std.json.Value) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "secureStoreKeys",
            .data = try json.stringify(allocator, request),
        },
    };
}
