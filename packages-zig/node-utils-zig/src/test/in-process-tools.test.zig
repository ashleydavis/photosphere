const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const in_process_tools = node_utils.in_process_tools;
const exec = node_utils.exec.exec;

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

    // The tool the runner does not handle, or empty when it handles all three.
    refused_tool: []const u8,

    // The output to answer with.
    output: []const u8,

    fn handles(context: ?*anyopaque, tool: []const u8) bool {
        const self: *RecordingRunner = @ptrCast(@alignCast(context.?));
        return !std.mem.eql(u8, tool, self.refused_tool);
    }

    fn run(context: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, tool: []const u8, arguments: []const []const u8) anyerror!in_process_tools.ToolOutput {
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
            .handles = handles,
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
        .refused_tool = "",
        .output = output,
    };
}

test "splitCommand splits on white space and joins quoted parts into their word" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const words = try in_process_tools.splitCommand(arena.allocator(), "magick identify -format \"%w %h\" jpeg:\"/a b/c.jpg\"  'x y'");
    try std.testing.expectEqual(@as(usize, 6), words.len);
    try std.testing.expectEqualStrings("magick", words[0]);
    try std.testing.expectEqualStrings("identify", words[1]);
    try std.testing.expectEqualStrings("-format", words[2]);
    try std.testing.expectEqualStrings("%w %h", words[3]);
    try std.testing.expectEqualStrings("jpeg:/a b/c.jpg", words[4]);
    try std.testing.expectEqualStrings("x y", words[5]);
}

test "splitCommand keeps an escaped double quote and a pattern full of brackets and stars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const words = try in_process_tools.splitCommand(arena.allocator(), "magick \"a\\\"b.jpg\" -format \"%[fx:int(mean.r*255)],%[EXIF:*]\" info:");
    try std.testing.expectEqual(@as(usize, 5), words.len);
    try std.testing.expectEqualStrings("a\"b.jpg", words[1]);
    try std.testing.expectEqualStrings("%[fx:int(mean.r*255)],%[EXIF:*]", words[3]);
}

test "splitCommand keeps an empty quoted word" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const words = try in_process_tools.splitCommand(arena.allocator(), "magick \"\" x");
    try std.testing.expectEqual(@as(usize, 3), words.len);
    try std.testing.expectEqualStrings("", words[1]);
}

test "splitCommand fails on a quote that is not closed and on shell syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.Thrown, in_process_tools.splitCommand(arena.allocator(), "magick \"a"));
    try std.testing.expectError(error.Thrown, in_process_tools.splitCommand(arena.allocator(), "magick 'a"));
    try std.testing.expectError(error.Thrown, in_process_tools.splitCommand(arena.allocator(), "magick a | b"));
    try std.testing.expectError(error.Thrown, in_process_tools.splitCommand(arena.allocator(), "magick \"$HOME\""));
}

test "splitCommand keeps the character after a backslash and fails on a backslash at the end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const words = try in_process_tools.splitCommand(arena.allocator(), "magick a\\ b");
    try std.testing.expectEqual(@as(usize, 2), words.len);
    try std.testing.expectEqualStrings("a b", words[1]);
    try std.testing.expectError(error.Thrown, in_process_tools.splitCommand(arena.allocator(), "magick a\\"));
    try std.testing.expectEqualStrings("The command ends with a backslash: magick a\\", utils.errors.lastErrorMessage());
}

test "exec gives a magick command to the runner with its arguments and returns the output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runner = newRunner(0, "800 600");
    const tools = runner.runner();

    const result = try exec(arena.allocator(), std.testing.io, tools, "magick identify -format \"%w %h\" \"/tmp/a b.jpg\"");
    try std.testing.expectEqualStrings("800 600", result.stdout);
    try std.testing.expectEqual(@as(u32, 1), runner.calls);
    try std.testing.expectEqualStrings("magick", runner.tool);
    try std.testing.expectEqual(@as(usize, 4), runner.arguments.len);
    try std.testing.expectEqualStrings("identify", runner.arguments[0]);
    try std.testing.expectEqualStrings("%w %h", runner.arguments[2]);
    try std.testing.expectEqualStrings("/tmp/a b.jpg", runner.arguments[3]);
}

test "exec gives ffprobe and ffmpeg commands to the runner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runner = newRunner(0, "{}");
    const tools = runner.runner();

    _ = try exec(arena.allocator(), std.testing.io, tools, "ffprobe -version");
    try std.testing.expectEqualStrings("ffprobe", runner.tool);
    _ = try exec(arena.allocator(), std.testing.io, tools, "ffmpeg -i \"x.mp4\" -y \"y.jpg\"");
    try std.testing.expectEqualStrings("ffmpeg", runner.tool);
    try std.testing.expectEqual(@as(u32, 2), runner.calls);
}

test "exec fails with the output when the runner's tool ends with a non-zero code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runner = newRunner(1, "no decode delegate");
    const tools = runner.runner();

    try std.testing.expectError(error.Thrown, exec(arena.allocator(), std.testing.io, tools, "magick \"x.heic\" -resize 10x10 \"y.jpg\""));
}

test "exec leaves a command for another program to the shell even with a runner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var runner = newRunner(0, "");
    const tools = runner.runner();

    const result = try exec(arena.allocator(), std.testing.io, tools, "echo hello");
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "hello"));
    try std.testing.expectEqual(@as(u32, 0), runner.calls);
}

test "tryRun leaves a command for a tool the runner does not handle to the caller" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var recorder = newRunner(0, "ignored");
    recorder.refused_tool = "ffmpeg";
    try std.testing.expect((try in_process_tools.tryRun(arena.allocator(), std.testing.io, recorder.runner(), "ffmpeg -version")) == null);
    try std.testing.expectEqual(@as(u32, 0), recorder.calls);
    const result = (try in_process_tools.tryRun(arena.allocator(), std.testing.io, recorder.runner(), "magick -version")).?;
    try std.testing.expectEqualStrings("ignored", result.stdout);
    try std.testing.expectEqual(@as(u32, 1), recorder.calls);
}
