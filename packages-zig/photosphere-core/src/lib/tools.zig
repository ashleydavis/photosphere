//
// The check-tools channel, from the ipcMain handler of the same name in apps/desktop/src/main.ts: reports whether the tools Photosphere
// needs to read photos and videos (ImageMagick, ffprobe and ffmpeg) are available, which the page shows when they are not.
//
// It is a task type, because it starts each tool to find its version.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const tools_zig = @import("tools-zig");

const TaskContext = ziggy.task_runner.TaskContext;
const json_util = ziggy.json_util;

//
// check-tools: no payload. The reply is {magick, ffprobe, ffmpeg, allAvailable, missingTools}, each tool as {available, version, error}.
//
pub fn checkToolsHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const status = try tools_zig.verifyTools(context.arena, context.io());
    return try json_util.stringify(context.arena, status);
}
