//
// Logs the error of a message handler before the page is told about it: the handler runs, and when it fails the error is logged with the
// message given for it (`log.exception(message, error)`) and passed on unchanged, so the page still gets the error reply.
//

const std = @import("std");
const ziggy = @import("ziggy-core");
const utils = @import("utils-zig");

const TaskHandler = ziggy.task_runner.TaskHandler;

//
// Wraps a task handler so that an error it returns is logged with the message, then returned.
//
// The wrapper is made when the program is compiled, because Zig has no closures to hold the handler and the message in. Every
// handler is given a message, so the message is required.
//
pub fn logExceptions(comptime handler: TaskHandler, comptime message: []const u8) TaskHandler {
    return struct {
        //
        // Runs the handler and logs the error it returns.
        //
        fn run(context: *ziggy.task_runner.TaskContext, data: std.json.Value) anyerror!?[]const u8 {
            return handler(context, data) catch |err| {
                utils.log.log.exception(message, err);
                return err;
            };
        }
    }.run;
}
