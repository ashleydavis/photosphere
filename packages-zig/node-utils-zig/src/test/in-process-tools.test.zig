const std = @import("std");
const ILog = @import("utils-zig").log.ILog;
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const in_process_tools = node_utils.in_process_tools;

// Records the last call a test runner was given and answers with the output and exit code the test set.
const RecordingRunner = struct {
    // The tool the last call named.
    tool: []const u8,

    // The arguments of the last call.
    arguments: []const []const u8,

    // How many calls were made.
    calls: u32,

    // The exit code to answer with.
    exit_code: i32,

    // The output to answer with.
    output: []const u8,

    fn run(context: ?*anyopaque, _: std.Io, _: ILog, allocator: std.mem.Allocator, tool: []const u8, arguments: []const []const u8) anyerror!in_process_tools.ToolOutput {
        const self: *RecordingRunner = @ptrCast(@alignCast(context.?));
        self.tool = tool;
        self.arguments = arguments;
        self.calls += 1;
        _ = allocator;
        return .{
            .exit_code = self.exit_code,
            .output = self.output,
        };
    }

    fn runner(self: *RecordingRunner) in_process_tools.InProcessRunner {
        return .{
            .context = self,
            .run = run,
        };
    }
};

fn newRunner(exit_code: i32, output: []const u8) RecordingRunner {
    return .{
        .tool = "",
        .arguments = &.{},
        .calls = 0,
        .exit_code = exit_code,
        .output = output,
    };
}

test "runTool passes the tool and the arguments to the runner unchanged and returns its output" {
    // The goal is to show that no argument is quoted, split or changed on its way to the runner. The method is to pass arguments
    // holding a space, `$`, a backtick and `"` to a recording runner and compare what it was given byte for byte.
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runner = newRunner(0, "800 600");
    const arguments = [_][]const u8{ "identify", "-format", "%w %h", "a $b `c` \"d\".jpg" };

    const result = try in_process_tools.runTool(arena.allocator(), std.testing.io, log, runner.runner(), "magick", &arguments);
    try std.testing.expectEqualStrings("800 600", result.stdout);
    try std.testing.expectEqual(@as(u32, 1), runner.calls);
    try std.testing.expectEqualStrings("magick", runner.tool);
    try std.testing.expectEqual(arguments.len, runner.arguments.len);
    for (arguments, runner.arguments) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "runTool fails with the tool, its arguments and the output when the tool ends with a non-zero code" {
    // The goal is to show that a failing tool is reported loudly with what was run and what it printed. The method is a runner
    // that exits with 1 and a check of the error message.
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runner = newRunner(1, "no decode delegate");

    try std.testing.expectError(error.Thrown, in_process_tools.runTool(arena.allocator(), std.testing.io, log, runner.runner(), "magick", &.{ "x.heic", "-resize", "10x10", "y.jpg" }));
    try std.testing.expectEqualStrings("Command failed: magick x.heic -resize 10x10 y.jpg\nno decode delegate", utils.errors.lastErrorMessage());
}

//
// A validation that always fails, with the reason "no output file".
//
fn failValidation(context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!?[]const u8 {
    _ = context;
    _ = allocator;
    _ = io;
    return "no output file";
}

test "runToolLogged logs the command at verbose and returns the output when the tool works and the validation passes" {
    // The goal is to show that runToolLogged logs the command it runs at verbose. The method is a runner that succeeds and a
    // memory log with verbose on.
    const memory = try utils.memory_log.MemoryLog.init(std.testing.allocator, .{
        .verbose = true,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runner = newRunner(0, "800 600");

    const result = try in_process_tools.runToolLogged(arena.allocator(), std.testing.io, memory.log, runner.runner(), "magick", &.{ "identify", "-format", "%w %h", "a.jpg" }, null);
    try std.testing.expectEqualStrings("800 600", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, memory.stdout(), "Executing magick with command: \"magick identify -format %w %h a.jpg\"") != null);
}

test "runToolLogged reports a failed validation as a failure to execute the command" {
    // The goal is to show that a failed validation is logged as an error and thrown as a failure to execute the command. The method is a runner
    // that succeeds and a validation that always fails.
    const memory = try utils.memory_log.MemoryLog.init(std.testing.allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runner = newRunner(0, "");
    var unused: u8 = 0;
    const description = "magick a.jpg b.jpg";

    try std.testing.expectError(error.Thrown, in_process_tools.runToolLogged(arena.allocator(), std.testing.io, memory.log, runner.runner(), "magick", &.{ "a.jpg", "b.jpg" }, .{
        .context = &unused,
        .function = failValidation,
    }));
    try std.testing.expectEqualStrings("Failed to execute command: " ++ description, utils.errors.lastErrorMessage());
    try std.testing.expect(std.mem.indexOf(u8, memory.stderr(), "Validation failed for command: " ++ description ++ "\nReason: no output file") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory.stdout(), "===\nCommand: " ++ description ++ "\nCommand stdout:\n") != null);
}

test "runToolLogged reports a tool that fails as a failure to execute the command" {
    // The goal is to show that a failing tool is logged and thrown as a failure to execute the command. The method is a runner that exits with 1.
    const memory = try utils.memory_log.MemoryLog.init(std.testing.allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runner = newRunner(1, "no decode delegate");
    const description = "magick x.heic y.jpg";

    try std.testing.expectError(error.Thrown, in_process_tools.runToolLogged(arena.allocator(), std.testing.io, memory.log, runner.runner(), "magick", &.{ "x.heic", "y.jpg" }, null));
    try std.testing.expectEqualStrings("Failed to execute command: " ++ description, utils.errors.lastErrorMessage());
    try std.testing.expect(std.mem.indexOf(u8, memory.stderr(), "Failed to execute command: " ++ description) != null);
}
