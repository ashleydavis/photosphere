const std = @import("std");
const node_utils = @import("node-utils-zig");
const utils = @import("utils-zig");
const termination = node_utils.termination;

//
// A process for the termination tests: it registers a termination callback, says "ready" and waits for the
// signal the test sends it. The callback writes "callback <exit code>" to stdout. The first argument says
// how the callback behaves: "succeed" always succeeds, "fail-once" throws on its first call only and
// "fail-always" always throws. "fail-always-logged" always throws too and writes the exceptions the log is given to
// stdout. "exit-verbose" writes verbose log messages to stdout and calls exit with 7 straight away instead of waiting
// for a signal.
//

//
// The Io the verbose and exception log messages are written to stdout with.
//
var stdoutIo: std.Io = undefined;

//
// The functions of the log, with verbose replaced by writeVerbose ("exit-verbose" only) or exception replaced by
// writeException ("fail-always-logged" only).
//
var verboseVtable: utils.log.ILog.VTable = undefined;

//
// Writes a verbose log message to stdout on a line of its own.
//
fn writeVerbose(ptr: *anyopaque, message: []const u8) void {
    _ = ptr;
    std.Io.File.stdout().writeStreamingAll(stdoutIo, message) catch |err| {
        std.debug.panic("Writing the verbose message failed: {s}", .{@errorName(err)});
    };
    std.Io.File.stdout().writeStreamingAll(stdoutIo, "\n") catch |err| {
        std.debug.panic("Writing the verbose message failed: {s}", .{@errorName(err)});
    };
}

//
// Writes an exception the log is given to stdout on a line of its own: "exception <message> <error message>".
//
fn writeException(ptr: *anyopaque, message: []const u8, err: anyerror) void {
    _ = ptr;
    var buffer: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "exception {s} {s}\n", .{ message, utils.errors.errorMessage(err) }) catch |formatErr| {
        std.debug.panic("Formatting the exception failed: {s}", .{@errorName(formatErr)});
    };
    std.Io.File.stdout().writeStreamingAll(stdoutIo, line) catch |writeErr| {
        std.debug.panic("Writing the exception failed: {s}", .{@errorName(writeErr)});
    };
}

//
// How the termination callback behaves (the first argument of the process).
//
var callbackMode: []const u8 = "succeed";

//
// Number of times the termination callback has been called.
//
var callbackCalls: usize = 0;

//
// The termination callback: reports its exit code on stdout and throws as the mode says.
//
fn reportExitCode(context: ?*anyopaque, io: std.Io, exitCode: u8) anyerror!void {
    _ = context;
    callbackCalls += 1;
    var buffer: [32]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "callback {d}\n", .{exitCode});
    try std.Io.File.stdout().writeStreamingAll(io, line);
    const failsAlways = std.mem.eql(u8, callbackMode, "fail-always") or std.mem.eql(u8, callbackMode, "fail-always-logged");
    if (failsAlways or (std.mem.eql(u8, callbackMode, "fail-once") and callbackCalls == 1)) {
        return utils.errors.throwError("Callback failed", .{});
    }
}

//
// Registers the callback, reports that it is ready and waits to be terminated.
//
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 2) {
        return error.ExpectedOneArgument;
    }
    callbackMode = arguments[1];
    try termination.registerTerminationCallback(io, .{ .context = null, .function = reportExitCode });
    if (std.mem.eql(u8, callbackMode, "exit-verbose")) {
        stdoutIo = io;
        verboseVtable = utils.log.log.vtable.*;
        verboseVtable.verbose = writeVerbose;
        utils.log.log = .{
            .ptr = utils.log.log.ptr,
            .vtable = &verboseVtable,
        };
        termination.exit(io, 7);
    }
    if (std.mem.eql(u8, callbackMode, "fail-always-logged")) {
        stdoutIo = io;
        verboseVtable = utils.log.log.vtable.*;
        verboseVtable.exception = writeException;
        utils.log.log = .{
            .ptr = utils.log.log.ptr,
            .vtable = &verboseVtable,
        };
    }
    try std.Io.File.stdout().writeStreamingAll(io, "ready\n");
    while (true) {
        try io.sleep(.fromSeconds(3600), .awake);
    }
}
