//
// The check-tools message: reports whether the tools Photosphere
// needs to read photos and videos (ImageMagick, ffprobe and ffmpeg) are available, which the page shows when they are not.
//
// It is a task type, because it asks each tool for its version.
//

const std = @import("std");
const ziggy = @import("ziggy");
const tools_zig = @import("tools-zig");
const media_tools = @import("media-tools-zig");
const utils = @import("utils-zig");

const TaskContext = ziggy.task_runner.TaskContext;
const TaskServices = ziggy.task_runner.TaskServices;
const HandlerServices = ziggy.core.HandlerServices;
const Timers = ziggy.timers.Timers;
const json = ziggy.json;
const logExceptions = @import("log-exceptions.zig").logExceptions;

//
// check-tools: no payload. The reply is {magick, ffprobe, ffmpeg, allAvailable, missingTools}, each tool as {available, version, error}.
//
fn checkTools(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    const log = services.log;
    _ = timers;
    _ = context;
    _ = data;
    // The tools built into the program, made on the task's thread, report on themselves.
    var tools = media_tools.ThreadTools.init();
    const status = try tools_zig.verifyTools(allocator, io, log, tools.runner());
    return try json.stringify(allocator, status);
}

//
// The check-tools message's handler: checkTools, with its errors logged.
//
pub const checkToolsHandler = logExceptions(checkTools, "Error checking tools");

//
// The data of check-tools, which has none.
//
pub const NoRequest = struct {};

//
// check-tools: answered by the check-tools task. The response is whether each tool is available, and its version.
//
pub fn checkToolsMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: NoRequest) !ziggy.core.Response(tools_zig.ToolsStatus) {
    _ = services;
    _ = timers;
    _ = io;
    return .{
        .task = .{
            .task_type = "check-tools",
            .data = try json.stringify(allocator, request),
        },
    };
}
