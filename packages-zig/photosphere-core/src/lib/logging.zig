//
// The logging channels: renderer-log, get-log-details and fps-measurement, from the ipcMain handlers of apps/desktop/src/main.ts of
// the same names.
//
// The log they use is the one installed with utils.log.setLog, which the app makes a FileLogger (file-logger.zig) at startup.
// renderer-log does what it does only when that log is a FileLogger, as the TypeScript does it only when it has a file logger.
//
// renderer-log is a channel answered on the thread that handles the page's messages, and still never waits for the disk: the
// FileLogger queues the line in memory and a thread of its own appends it, as the TypeScript's logger queues it and awaits
// fs.appendFile. get-log-details reads the log file, so it is a task type.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const file_logger = @import("file-logger.zig");

const Core = ziggy.core.Core;
const TaskContext = ziggy.task_runner.TaskContext;
const json_util = ziggy.json_util;
const FileLogger = file_logger.FileLogger;

//
// renderer-log: the payload is {level, message, error?, toolData?{stdout?, stderr?}}, an IRendererLogMessage. It is written to the
// log as the message of a worker is, with the source "Renderer". The reply is null. When the log is not a FileLogger the message is
// dropped, as it is in the TypeScript when there is no file logger.
//
// This differs from the TypeScript in one way: a message that is not laid out as an IRendererLogMessage (not an object, no level or
// message, a level that is not one of the eight, a toolData that is not an object) is an error reply that says what is wrong, where
// the TypeScript's switch would write nothing or the text "undefined". Nothing is dropped without being said, which is what the
// repository requires, and the page's types make the TypeScript's case impossible. The check happens before the test for a file
// logger, so a bad message is reported even when there is no file logger.
//
pub fn rendererLogHandler(core: *Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    _ = core;
    if (data != .object) {
        return utils.errors.throwError("The log message must be an object with a level and a message.", .{});
    }
    const level_text = json_util.getString(data, "level") orelse {
        return utils.errors.throwError("The log message needs a level.", .{});
    };
    const level = std.meta.stringToEnum(file_logger.WorkerLogLevel, level_text) orelse {
        return utils.errors.throwError("The log message has the level \"{s}\", which is not one of info, verbose, error, exception, warn, debug, tool or event.", .{level_text});
    };
    const message = json_util.getString(data, "message") orelse {
        return utils.errors.throwError("The log message needs a message.", .{});
    };
    var tool_data: ?utils.log.IToolOutput = null;
    if (data.object.get("toolData")) |tool_data_value| {
        // A null toolData is absent, as it is for the TypeScript's truthiness test.
        if (tool_data_value != .null) {
            if (tool_data_value != .object) {
                return utils.errors.throwError("The tool data of a log message must be an object.", .{});
            }
            tool_data = .{
                .stdout = json_util.getString(tool_data_value, "stdout"),
                .stderr = json_util.getString(tool_data_value, "stderr"),
            };
        }
    }
    const logger = FileLogger.fromILog(utils.log.log) orelse {
        return try arena.dupe(u8, "null");
    };
    try logger.handleWorkerLogMessage(.{
        .level = level,
        .message = message,
        .@"error" = json_util.getString(data, "error"),
        .tool_data = tool_data,
    }, "Renderer");
    return try arena.dupe(u8, "null");
}

//
// get-log-details: no payload. The reply is {logFilePath, logHeader} of the active log: the path of the log file and the header of
// the file, read from it on demand. A log that writes no file (the console log) replies with a null path and a placeholder header.
//
pub fn getLogDetailsHandler(context: *TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = data;
    const details = try utils.log.log.getLogDetails(context.arena, context.io());
    return try std.json.Stringify.valueAlloc(context.arena, details, .{});
}

//
// fps-measurement: the payload is the frames per second the page measured, a number. A row of the time in milliseconds since the
// Unix epoch and the number is appended to photosphere-fps.csv, and the reply is null. Like the TypeScript's, it answers only when
// the environment variable FPS_LOGGING is 1, and it is an error otherwise.
//
// This differs from the TypeScript in four ways. The file is in the app's data directory, where the TypeScript's is a fixed path
// under /tmp, which nothing new may claim. The column header row is written when the file is empty or not there, where the
// TypeScript writes it each time the app starts, because there is no moment of registration here to write it at. The environment
// variable is read for each message, where the TypeScript reads it once at startup to decide whether to register the channel at all,
// and a message with it off is an error reply where the TypeScript has no handler and so ignores it. A value that is not a number
// is an error reply where the TypeScript would write it into the file whatever it was, because all failures here are noisy.
//
pub fn fpsMeasurementHandler(core: *Core, arena: std.mem.Allocator, data: std.json.Value) anyerror![]const u8 {
    const enabled = node_utils.process_env.getEnv("FPS_LOGGING") orelse "";
    if (!std.mem.eql(u8, enabled, "1")) {
        return utils.errors.throwError("FPS logging is off. Start Photosphere with the environment variable FPS_LOGGING set to 1 to record frame rates.", .{});
    }
    const fps: f64 = switch (data) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => return utils.errors.throwError("The frames per second must be a number.", .{}),
    };
    const fps_path = try std.fs.path.join(arena, &.{ core.data_dir, "photosphere-fps.csv" });
    const io = core.threaded.io();
    var rows = std.Io.Writer.Allocating.init(arena);
    const existing_length = existingLength(io, fps_path) catch |err| {
        return utils.errors.throwError("The frame rate file {s} could not be read: {s}", .{ fps_path, @errorName(err) });
    };
    if (existing_length == 0) {
        try rows.writer.writeAll("timestamp,fps\n");
    }
    try rows.writer.print("{d},", .{std.Io.Clock.real.now(io).toMilliseconds()});
    try utils.js_number.writeNumber(&rows.writer, fps);
    try rows.writer.writeAll("\n");
    file_logger.appendToFile(io, fps_path, rows.written()) catch |err| {
        return utils.errors.throwError("The frame rate could not be written to {s}: {s}", .{ fps_path, @errorName(err) });
    };
    return try arena.dupe(u8, "null");
}

//
// The length of a file, or 0 when it is not there.
//
fn existingLength(io: std.Io, file_path: []const u8) !u64 {
    const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return 0;
        }
        return err;
    };
    defer file.close(io);
    return try file.length(io);
}
