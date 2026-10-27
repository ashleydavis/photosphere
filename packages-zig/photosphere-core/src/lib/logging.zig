//
// The logging messages: get-log-details and fps-measurement. The page's own log lines reach the log files through Ziggy's
// `window.ziggy.log`, which writes them tagged Frontend.
//
// The log is Ziggy's file log, which Ziggy starts when the app starts. get-log-details reads its log file, so it is
// a task type, given the path of the main thread's log file.
//

const std = @import("std");
const ziggy = @import("ziggy");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");

const TaskContext = ziggy.task_runner.TaskContext;
const TaskServices = ziggy.task_runner.TaskServices;
const HandlerServices = ziggy.core.HandlerServices;
const Timers = ziggy.timers.Timers;
const json = ziggy.json;
const logExceptions = @import("log-exceptions.zig").logExceptions;

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
    const details = try utils.file_log.readLogDetails(allocator, io, log_file);
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
    appendToFile(io, fps_path, rows.written()) catch |err| {
        return utils.errors.throwError("The frame rate could not be written to {s}: {s}", .{ fps_path, @errorName(err) });
    };
}

//
// Appends text to the end of a file, creating it when it is not there.
//
fn appendToFile(io: std.Io, file_path: []const u8, content: []const u8) !void {
    // Opened for reading as well, because file.length needs read access on Windows, where Zig opens a file with GENERIC_WRITE alone
    // and the size query is refused.
    const file = try std.Io.Dir.cwd().createFile(io, file_path, .{
        .truncate = false,
        .read = true,
    });
    defer file.close(io);
    const length = try file.length(io);
    try file.writePositionalAll(io, content, length);
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
    _ = timers;
    _ = io;
    _ = request;
    return .{
        .task = .{
            .task_type = "get-log-details",
            .data = try json.stringify(allocator, ILogDetailsData{
                .logFilePath = services.log.logFilePath(),
            }),
        },
    };
}
