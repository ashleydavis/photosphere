//
// The check-tools channel: reports whether the tools Photosphere
// needs to read photos and videos (ImageMagick, ffprobe and ffmpeg) are available, which the page shows when they are not.
//
// It is a task type, because it starts each tool to find its version.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const tools_zig = @import("tools-zig");
const node_utils = @import("node-utils-zig");

const TaskContext = ziggy.task_runner.TaskContext;
const json_util = ziggy.json_util;
const logExceptions = @import("log-exceptions.zig").logExceptions;

//
// check-tools: no payload. The reply is {magick, ffprobe, ffmpeg, allAvailable, missingTools}, each tool as {available, version, error}.
//
fn checkTools(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    // On a phone the shell runs ImageMagick and ffmpeg, and the task asks it through its host requester.
    var requester_storage: ziggy.task_runner.TaskHostRequester = undefined;
    var tool_runner_storage: node_utils.host_tools.HostToolRunner = undefined;
    const tool_runner = try node_utils.host_tools.toolRunnerFor(context.hostRequester(&requester_storage), &tool_runner_storage);
    const status = try tools_zig.verifyTools(context.arena, context.io(), tool_runner);
    return try json_util.stringify(context.arena, status);
}

//
// The check-tools channel's handler: checkTools, with its errors logged.
//
pub const checkToolsHandler = logExceptions(checkTools, "Error checking tools");
