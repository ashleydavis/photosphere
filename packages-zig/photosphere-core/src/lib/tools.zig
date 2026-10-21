//
// The check-tools message: reports whether the tools Photosphere
// needs to read photos and videos (ImageMagick, ffprobe and ffmpeg) are available, which the page shows when they are not.
//
// It is a task type, because it asks each tool for its version.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const tools_zig = @import("tools-zig");
const main_state = @import("main-state.zig");

const TaskContext = ziggy.task_runner.TaskContext;
const json = ziggy.json;
const logExceptions = @import("log-exceptions.zig").logExceptions;

//
// check-tools: no payload. The reply is {magick, ffprobe, ffmpeg, allAvailable, missingTools}, each tool as {available, version, error}.
//
fn checkTools(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    // The tools built into the program answer for themselves, and a tool that is not built in is started as a program.
    const status = try tools_zig.verifyTools(context.arena, context.io(), main_state.fromContext(context).media_tools.runner());
    return try json.stringify(context.arena, status);
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
pub fn checkToolsMessageHandler(core: *ziggy.core.Core, arena: std.mem.Allocator, request: NoRequest) !ziggy.core.Answer(tools_zig.ToolsStatus) {
    _ = core;
    return .{
        .task = .{
            .task_type = "check-tools",
            .data = try json.stringify(arena, request),
        },
    };
}
