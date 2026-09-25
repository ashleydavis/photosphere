//
// Worker log implementation for the CLI worker threads (TypeScript: Bun CLI workers).
// Writes log messages directly to the console, prefixed with worker and task IDs.
//
// Zig workers are threads of the CLI process and share the global log, so the log of a worker is
// thread-local: installWorkerLogRouting (no TypeScript counterpart) replaces the global log with a log
// that forwards each message to the worker log of the calling thread, or to the main log on other threads.
//

const std = @import("std");
const utils = @import("utils-zig");
const console_output = @import("console-output.zig");
const writeOutputLine = console_output.writeOutputLine;
const writeErrorLine = console_output.writeErrorLine;
const ILog = utils.log.ILog;
const ILogDetails = utils.log.ILogDetails;
const IToolOutput = utils.log.IToolOutput;
const noLogDetails = utils.log.noLogDetails;

//
// Bun CLI worker log implementation.
// Writes log messages directly to the console, prefixed with worker and task IDs.
//
pub const WorkerLogBun = struct {
    // Whether verbose logging is enabled.
    verboseEnabled: bool,

    // Whether tool output logging is enabled.
    toolsEnabled: bool,

    // Numeric ID of this worker, used in log prefixes.
    workerId: u32,

    // The current task ID for log prefixing, null when idle.
    currentTaskId: ?[]const u8,

    //
    // Creates the log of a worker.
    //
    pub fn init(workerId: u32, verboseEnabled: bool, toolsEnabled: bool) WorkerLogBun {
        return .{
            .verboseEnabled = verboseEnabled,
            .toolsEnabled = toolsEnabled,
            .workerId = workerId,
            .currentTaskId = null,
        };
    }

    //
    // Sets the task ID used in the prefix.
    //
    pub fn setTaskId(self: *WorkerLogBun, taskId: ?[]const u8) void {
        self.currentTaskId = taskId;
    }

    //
    // Writes the prefix `[W<id>:<taskId>] ` (the task ID only while a task runs) and the message.
    //
    fn prefixMessage(self: *WorkerLogBun, writer: *std.Io.Writer, message: []const u8) std.Io.Writer.Error!void {
        try writer.print("[W{d}", .{self.workerId});
        if (self.currentTaskId) |taskId| {
            try writer.print(":{s}", .{taskId});
        }
        try writer.print("] {s}", .{message});
    }

    //
    // Formats a prefixed message and passes it to the console function.
    //
    fn writePrefixed(self: *WorkerLogBun, message: []const u8, consoleFunction: *const fn ([]const u8) void) void {
        var allocating_writer = std.Io.Writer.Allocating.init(std.heap.smp_allocator);
        defer allocating_writer.deinit();
        self.prefixMessage(&allocating_writer.writer, message) catch return;
        consoleFunction(allocating_writer.written());
    }

    //
    // Logs a verbose message when verbose logging is enabled.
    //
    pub fn verbose(self: *WorkerLogBun, message: []const u8) void {
        if (!self.verboseEnabled) {
            return;
        }
        self.writePrefixed(message, writeOutputLine);
    }

    //
    // Logs an informational message.
    //
    pub fn info(self: *WorkerLogBun, message: []const u8) void {
        self.writePrefixed(message, writeOutputLine);
    }

    //
    // Logs an error message.
    //
    pub fn @"error"(self: *WorkerLogBun, message: []const u8) void {
        self.writePrefixed(message, writeErrorLine);
    }

    //
    // Logs a message and an error with its cause chain.
    //
    pub fn exception(self: *WorkerLogBun, message: []const u8, err: anyerror) void {
        self.writePrefixed(message, writeErrorLine);
        var allocating_writer = std.Io.Writer.Allocating.init(std.heap.smp_allocator);
        defer allocating_writer.deinit();
        utils.wrapped_error.writeErrorChain(&allocating_writer.writer, err) catch return;
        writeErrorLine(allocating_writer.written());
    }

    //
    // Logs a warning.
    //
    pub fn warn(self: *WorkerLogBun, message: []const u8) void {
        self.writePrefixed(message, writeErrorLine);
    }

    //
    // Workers don't support debug logging
    //
    pub fn debug(self: *WorkerLogBun, message: []const u8) void {
        _ = self;
        _ = message;
    }

    //
    // Logs the output of an external tool when tool logging is enabled.
    //
    pub fn tool(self: *WorkerLogBun, toolName: []const u8, data: IToolOutput) void {
        if (!self.toolsEnabled) {
            return;
        }

        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        if (data.stdout) |stdout| {
            if (stdout.len > 0) {
                const text = std.fmt.allocPrint(arena.allocator(), "== {s} stdout ==\n{s}", .{ toolName, stdout }) catch return;
                self.writePrefixed(text, writeOutputLine);
            }
        }
        if (data.stderr) |stderr| {
            if (stderr.len > 0) {
                const text = std.fmt.allocPrint(arena.allocator(), "== {s} stderr ==\n{s}", .{ toolName, stderr }) catch return;
                self.writePrefixed(text, writeOutputLine);
            }
        }
    }

    //
    // Logs an event.
    //
    pub fn event(self: *WorkerLogBun, message: []const u8) void {
        var buffer: [16 * 1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "[EVENT] {s}", .{message}) catch message;
        self.writePrefixed(text, writeOutputLine);
    }

    //
    // Gets details about the active log file for inclusion in bug reports.
    // Worker logs have no log file of their own.
    //
    pub fn getLogDetails(self: *WorkerLogBun) ILogDetails {
        _ = self;
        return noLogDetails;
    }
};

// Global reference to the worker log instance for setting task ID
// (thread-local in Zig: each worker thread has its own log).
threadlocal var workerLogInstance: ?*WorkerLogBun = null;

//
// Sets the current task ID for worker logging.
// All subsequent log messages will be prefixed with [shortTaskId].
//
pub fn setWorkerTaskId(taskId: ?[]const u8) void {
    if (workerLogInstance) |instance| {
        instance.setTaskId(taskId);
    }
}

//
// Creates and registers the WorkerLogBun instance of the calling worker thread.
// The instance must stay valid while the thread logs (it is usually on the thread's stack).
// (TypeScript returns an ILog to pass to setLog; in Zig installWorkerLogRouting sends the calling
// thread's messages to it.)
//
pub fn createWorkerLog(workerLog: *WorkerLogBun) void {
    workerLogInstance = workerLog;
}

//
// Clears the worker log of the calling thread (Zig only: called when a worker thread ends).
//
pub fn clearWorkerLog() void {
    workerLogInstance = null;
}

//
// The log that messages from threads without a worker log go to.
//
var main_log: ?ILog = null;

//
// The log installed by installWorkerLogRouting: forwards to the worker log of the calling thread,
// or to the main log.
//
const routing_log_vtable: ILog.VTable = .{
    .info = routeInfo,
    .verbose = routeVerbose,
    .@"error" = routeError,
    .exception = routeException,
    .warn = routeWarn,
    .debug = routeDebug,
    .tool = routeTool,
    .event = routeEvent,
    .verboseEnabled = routeVerboseEnabled,
    .getLogDetails = routeGetLogDetails,
};

//
// The routing log does not need state; this gives it an address.
//
var routing_log_state: u8 = 0;

//
// Replaces the global log with a log that sends the messages of worker threads to their worker log and
// all other messages to the log that was installed before (no TypeScript counterpart).
// Does nothing when the routing log is already installed.
//
pub fn installWorkerLogRouting() void {
    const current = utils.log.log;
    if (current.vtable == &routing_log_vtable) {
        return;
    }
    main_log = current;
    utils.log.setLog(.{ .ptr = &routing_log_state, .vtable = &routing_log_vtable });
}

//
// Gets the main log (the log that was installed before the routing log).
//
fn mainLog() ILog {
    return main_log.?;
}

//
// ILog.info of the routing log.
//
fn routeInfo(ptr: *anyopaque, message: []const u8) void {
    _ = ptr;
    if (workerLogInstance) |workerLog| {
        workerLog.info(message);
        return;
    }
    mainLog().info(message);
}

//
// ILog.verbose of the routing log.
//
fn routeVerbose(ptr: *anyopaque, message: []const u8) void {
    _ = ptr;
    if (workerLogInstance) |workerLog| {
        workerLog.verbose(message);
        return;
    }
    mainLog().verbose(message);
}

//
// ILog.error of the routing log.
//
fn routeError(ptr: *anyopaque, message: []const u8) void {
    _ = ptr;
    if (workerLogInstance) |workerLog| {
        workerLog.@"error"(message);
        return;
    }
    mainLog().@"error"(message);
}

//
// ILog.exception of the routing log.
//
fn routeException(ptr: *anyopaque, message: []const u8, err: anyerror) void {
    _ = ptr;
    if (workerLogInstance) |workerLog| {
        workerLog.exception(message, err);
        return;
    }
    mainLog().exception(message, err);
}

//
// ILog.warn of the routing log.
//
fn routeWarn(ptr: *anyopaque, message: []const u8) void {
    _ = ptr;
    if (workerLogInstance) |workerLog| {
        workerLog.warn(message);
        return;
    }
    mainLog().warn(message);
}

//
// ILog.debug of the routing log.
//
fn routeDebug(ptr: *anyopaque, message: []const u8) void {
    _ = ptr;
    if (workerLogInstance) |workerLog| {
        workerLog.debug(message);
        return;
    }
    mainLog().debug(message);
}

//
// ILog.tool of the routing log.
//
fn routeTool(ptr: *anyopaque, toolName: []const u8, data: IToolOutput) void {
    _ = ptr;
    if (workerLogInstance) |workerLog| {
        workerLog.tool(toolName, data);
        return;
    }
    mainLog().tool(toolName, data);
}

//
// ILog.event of the routing log.
//
fn routeEvent(ptr: *anyopaque, message: []const u8) void {
    _ = ptr;
    if (workerLogInstance) |workerLog| {
        workerLog.event(message);
        return;
    }
    mainLog().event(message);
}

//
// ILog.verboseEnabled of the routing log.
//
fn routeVerboseEnabled(ptr: *anyopaque) bool {
    _ = ptr;
    if (workerLogInstance) |workerLog| {
        return workerLog.verboseEnabled;
    }
    return mainLog().verboseEnabled();
}

//
// ILog.getLogDetails of the routing log.
//
fn routeGetLogDetails(ptr: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!ILogDetails {
    _ = ptr;
    if (workerLogInstance) |workerLog| {
        return workerLog.getLogDetails();
    }
    return mainLog().getLogDetails(allocator, io);
}
