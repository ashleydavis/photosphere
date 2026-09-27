const std = @import("std");
const node_utils = @import("node-utils-zig");
const utils = @import("utils-zig");
const termination = node_utils.termination;

//
// A process for the termination tests: it registers a termination callback, says "ready" and waits for the
// signal the test sends it. The callback writes "callback <exit code>" to stdout. The first argument says
// how the callback behaves: "succeed" always succeeds, "fail-once" throws on its first call only and
// "fail-always" always throws.
//

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
    if (std.mem.eql(u8, callbackMode, "fail-always") or (std.mem.eql(u8, callbackMode, "fail-once") and callbackCalls == 1)) {
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
    try std.Io.File.stdout().writeStreamingAll(io, "ready\n");
    while (true) {
        try io.sleep(.fromSeconds(3600), .awake);
    }
}
