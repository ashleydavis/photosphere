//
// How the CLI writes the log lines its workers send: each line as the worker's console would show it, prefixed with the worker and
// the task it is running (`[W<id>:<task id>]`, or `[W<id>]` between tasks), as the TypeScript CLI's WorkerLogBun writes them. Ziggy's
// worker pool hands each line to the handler `logHandler` makes, on the main thread.
//

const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const ziggy = @import("ziggy");
const worker_messages = ziggy.worker_messages;
const LogHandler = ziggy.worker_pool.LogHandler;

//
// Where the handler `logHandler` makes writes the workers' lines: the main thread's log, and whether the command shows tool output.
//
const IWorkerLogTarget = struct {
    // The main thread's log, which every worker's line is written to.
    log: ILog,

    // Whether the command was given --tools, so a tool's output is shown rather than only kept in a log file.
    toolsShown: bool,
};

//
// Makes the handler Ziggy's worker pool gives the workers' log lines to, which writes each to the log given (the main thread's) with
// writeWorkerLog. What it points at is allocated with the allocator, which must live as long as the pool.
//
pub fn logHandler(allocator: std.mem.Allocator, log: ILog, toolsShown: bool) !LogHandler {
    const target = try allocator.create(IWorkerLogTarget);
    target.* = .{
        .log = log,
        .toolsShown = toolsShown,
    };
    return .{
        .user_data = target,
        .write = writeHandledLine,
    };
}

//
// The handler's write: writes the line a worker sent with writeWorkerLog, building it in an arena of its own.
//
fn writeHandledLine(user_data: ?*anyopaque, workerId: u32, taskId: ?[]const u8, message_json: []const u8) void {
    const target: *IWorkerLogTarget = @ptrCast(@alignCast(user_data.?));
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    writeWorkerLog(arena_state.allocator(), target.log, target.toolsShown, workerId, taskId, message_json);
}

//
// Writes a worker's log line to the log given (the main thread's) as WorkerLogBun writes it: the line as the worker's console would
// show it, prefixed with the worker and the task it is running (`[W<id>:<task id>]`, or `[W<id>]` between tasks). With a log
// file, workers send every verbose and tool line: the main thread's log leaves verbose lines off its console as its options say, and
// a tool line is shown only when the command was given --tools (`toolsShown`), otherwise it goes to the log as a tool line, which
// only a log file keeps. WorkerLogBun writes no debug lines. The text is the worker's log message (IWorkerLogMessage).
//
pub fn writeWorkerLog(arena: std.mem.Allocator, log: ILog, toolsShown: bool, workerId: u32, taskId: ?[]const u8, text: []const u8) void {
    const message = worker_messages.decode(worker_messages.IWorkerLogMessage, arena, text) catch |err| {
        std.debug.panic("could not read a worker's log message ({s}): {s}", .{ @errorName(err), text });
    };
    switch (message.level) {
        .info => log.info(prefixMessage(arena, workerId, taskId, message.message)),
        .verbose => log.verbose(prefixMessage(arena, workerId, taskId, message.message)),
        .@"error" => log.err(prefixMessage(arena, workerId, taskId, message.message)),
        .warn => log.warn(prefixMessage(arena, workerId, taskId, message.message)),
        .exception => {
            log.err(prefixMessage(arena, workerId, taskId, message.message));
            if (message.@"error") |errorText| {
                log.err(errorText);
            }
        },
        .debug => {},
        .tool => if (!toolsShown) {
            log.tool(prefixMessage(arena, workerId, taskId, message.message), .{
                .stdout = if (message.toolData) |data| data.stdout else null,
                .stderr = if (message.toolData) |data| data.stderr else null,
            });
        }
        else if (message.toolData) |data| {
            writeToolStream(arena, log, workerId, taskId, message.message, "stdout", data.stdout);
            writeToolStream(arena, log, workerId, taskId, message.message, "stderr", data.stderr);
        },
        .event => log.info(prefixMessage(arena, workerId, taskId, std.fmt.allocPrint(arena, "[EVENT] {s}", .{message.message}) catch @panic("out of memory writing a log line"))),
    }
}

//
// Writes `== <tool> <stream> ==` and what a worker's tool wrote to it, prefixed as the worker's other lines are, when the tool
// wrote anything.
//
fn writeToolStream(arena: std.mem.Allocator, log: ILog, workerId: u32, taskId: ?[]const u8, toolName: []const u8, stream: []const u8, text: ?[]const u8) void {
    const written = text orelse return;
    if (written.len == 0) {
        return;
    }
    log.info(prefixMessage(arena, workerId, taskId, std.fmt.allocPrint(arena, "== {s} {s} ==\n{s}", .{ toolName, stream, written }) catch @panic("out of memory writing a log line")));
}

//
// Prefixes a worker's log line with the worker and the task it is running, as WorkerLogBun's prefixMessage does.
//
fn prefixMessage(arena: std.mem.Allocator, workerId: u32, taskId: ?[]const u8, message: []const u8) []const u8 {
    if (taskId) |id| {
        return std.fmt.allocPrint(arena, "[W{d}:{s}] {s}", .{ workerId, id, message }) catch @panic("out of memory writing a log line");
    }
    return std.fmt.allocPrint(arena, "[W{d}] {s}", .{ workerId, message }) catch @panic("out of memory writing a log line");
}
