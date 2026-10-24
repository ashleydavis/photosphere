//
// The logging messages: renderer-log, get-log-details and fps-measurement.
//
// The log they use is the one installed with utils.log.setLog, which the app makes a FileLogger (file-logger.zig) at startup.
// renderer-log does what it does only when that log is a FileLogger.
//
// renderer-log is a message handled on the main thread, whose log the FileLogger is, and which writes the line to the log file.
// get-log-details reads the log file, so it is a task type, given the path of the main thread's log file.
//

const std = @import("std");
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const file_logger = @import("file-logger.zig");

const TaskContext = ziggy.task_runner.TaskContext;
const TaskServices = ziggy.task_runner.TaskServices;
const HandlerServices = ziggy.core.HandlerServices;
const Timers = ziggy.timers.Timers;
const json = ziggy.json;
const FileLogger = file_logger.FileLogger;
const logExceptions = @import("log-exceptions.zig").logExceptions;

//
// The output of a tool, in a renderer-log message.
//
pub const ToolDataRequest = struct {
    // What the tool wrote to its standard output, or null.
    stdout: ?[]const u8 = null,
    // What the tool wrote to its standard error, or null.
    stderr: ?[]const u8 = null,
};

//
// The data of renderer-log, an IRendererLogMessage.
//
pub const RendererLogRequest = struct {
    // The level, one of info, verbose, error, exception, warn, debug, tool or event.
    level: []const u8,
    // The text of the message.
    message: []const u8,
    // The text of the error the message is about, or null.
    @"error": ?[]const u8 = null,
    // The output of the tool the message is about, or null.
    toolData: ?ToolDataRequest = null,
};

//
// renderer-log: written to the log as the message of a worker is, with the source "Renderer". The response is null. When the log is
// not a FileLogger the message is dropped.
//
// Data that is not laid out as an IRendererLogMessage is refused by Ziggy as InvalidMessageData. A level that is not one of the
// eight is an error reply that says so, because the level has to be one of them to be read into the log's level type, and nothing
// is dropped without being said, which is what the repository requires. The check happens before the test for a file logger, so a
// bad message is reported even when there is no file logger.
//
pub fn rendererLogHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: RendererLogRequest) !void {
    _ = services;
    _ = timers;
    _ = io;
    _ = allocator;
    const level = std.meta.stringToEnum(file_logger.WorkerLogLevel, request.level) orelse {
        return utils.errors.throwError("The log message has the level \"{s}\", which is not one of info, verbose, error, exception, warn, debug, tool or event.", .{request.level});
    };
    var tool_data: ?utils.log.IToolOutput = null;
    if (request.toolData) |tool_data_request| {
        tool_data = .{
            .stdout = tool_data_request.stdout,
            .stderr = tool_data_request.stderr,
        };
    }
    const logger = FileLogger.fromILog(utils.log.currentLog()) orelse {
        return;
    };
    try logger.handleWorkerLogMessage(.{
        .level = level,
        .message = request.message,
        .@"error" = request.@"error",
        .tool_data = tool_data,
    }, "Renderer");
}

//
// get-log-details: no payload. The reply is {logFilePath, logHeader} of the active log: the path of the log file and the header of
// the file, read from it on demand. A log that writes no file (the console log) replies with a null path and a placeholder header.
//
fn getLogDetails(services: TaskServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, context: TaskContext, data: std.json.Value) anyerror!?[]const u8 {
    _ = services;
    _ = timers;
    _ = context;
    const given = try std.json.parseFromValueLeaky(ILogDetailsData, allocator, data, .{
        .ignore_unknown_fields = true,
    });
    const log_file = given.logFilePath orelse {
        return try std.json.Stringify.valueAlloc(allocator, utils.log.noLogDetails, .{});
    };
    const details = try file_logger.readLogDetails(allocator, io, log_file);
    return try std.json.Stringify.valueAlloc(allocator, details, .{});
}

//
// What the main thread gives the get-log-details task: the log is the main thread's, which a task cannot reach.
//
const ILogDetailsData = struct {
    // The path of the main thread's log file, or null when its log writes no file (the console log).
    logFilePath: ?[]const u8 = null,
};

//
// fps-measurement: the payload is the frames per second the page measured, a number. A row of the time in milliseconds since the
// Unix epoch and the number is appended to photosphere-fps.csv, and the reply is null. It answers only when
// the environment variable FPS_LOGGING is 1, and it is an error otherwise.
//
// The file is in the app's data directory, because a fixed path under /tmp does not exist on Windows
// and nothing may claim a fixed machine-wide path. The column header row is written when the file is empty or not there,
// because the messages are a fixed list and there is no moment of registration to write it at. The
// environment variable is read for each message, and a message with it off is an error reply. A value that is
// not a number is refused by Ziggy as InvalidMessageData, because all failures here are noisy.
//
pub fn fpsMeasurementHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, fps: f64) !void {
    _ = timers;
    const enabled = node_utils.process_env.getEnv("FPS_LOGGING") orelse "";
    if (!std.mem.eql(u8, enabled, "1")) {
        return utils.errors.throwError("FPS logging is off. Start Photosphere with the environment variable FPS_LOGGING set to 1 to record frame rates.", .{});
    }
    const fps_path = try std.fs.path.join(allocator, &.{ services.dataDir(), "photosphere-fps.csv" });
    var rows = std.Io.Writer.Allocating.init(allocator);
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

//
// The get-log-details message's handler: getLogDetails, with its errors logged.
//
pub const getLogDetailsHandler = logExceptions(getLogDetails, "Error getting log details");

//
// The data of get-log-details, which has none.
//
pub const NoRequest = struct {};

//
// get-log-details: answered by the get-log-details task. The response is the path of the log file and its header.
//
pub fn getLogDetailsMessageHandler(services: HandlerServices, timers: Timers, io: std.Io, allocator: std.mem.Allocator, request: NoRequest) !ziggy.core.Response(utils.log.ILogDetails) {
    _ = services;
    _ = timers;
    _ = io;
    _ = request;
    const logger = FileLogger.fromILog(utils.log.currentLog());
    return .{
        .task = .{
            .task_type = "get-log-details",
            .data = try json.stringify(allocator, ILogDetailsData{
                .logFilePath = if (logger) |file_log| file_log.getLogFilePath() else null,
            }),
        },
    };
}
