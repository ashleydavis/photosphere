const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const media_tools = @import("media-tools-zig");

const MediaTools = media_tools.MediaTools;
const ImageMagick = media_tools.ImageMagick;
const tool_run = media_tools.tool_run;

//
// The path of a file in a test's temporary directory.
//
fn tempFilePath(allocator: std.mem.Allocator, tmp_dir: std.testing.TmpDir, name: []const u8) ![]const u8 {
    const current_path = try std.process.currentPathAlloc(std.testing.io, allocator);
    return try std.fs.path.join(allocator, &.{ current_path, ".zig-cache", "tmp", &tmp_dir.sub_path, name });
}

test "runChecked hands the arguments to the tool unchanged and returns what it printed" {
    // The goal is to show that no argument is quoted, split or changed on its way to the tool. The method is to copy the checked in
    // test.png (100x90) to a file whose name holds a space, `$`, a backtick and a quote, and have the real ImageMagick read its size
    // from that name: a name changed on the way would name no file. Windows allows no `"` in a file name, so a `'` stands in there.
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var tools = try MediaTools.init();
    defer tools.deinit();
    const name = if (builtin.os.tag == .windows) "a $b `c` 'd'.png" else "a $b `c` \"d\".png";
    try std.Io.Dir.cwd().copyFile("../test/test.png", tmp_dir.dir, name, std.testing.io, .{});
    const path = try tempFilePath(allocator, tmp_dir, name);

    const output = try tool_run.runChecked(allocator, std.testing.io, log, .magick, &.{ "identify", "-format", "%w %h", path });
    try std.testing.expectEqualStrings("100 90", output);
}

test "runChecked fails with the tool, its arguments and what the tool printed when the tool ends with a non-zero code" {
    // The goal is to show that a failing tool is reported loudly with what was run and what it printed. The method is to have the
    // real ImageMagick resize a file that does not exist, and to compare the error with the command and the messages the same
    // command hands back when it is run on its own.
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var tools = try MediaTools.init();
    defer tools.deinit();
    const missing = try tempFilePath(allocator, tmp_dir, "x.heic");
    const output = try tempFilePath(allocator, tmp_dir, "y.jpg");
    const arguments = [_][]const u8{ missing, "-resize", "10x10", output };

    const failed = try ImageMagick.runMagick(std.testing.io, log, allocator, &arguments);
    try std.testing.expectEqual(@as(i32, 1), failed.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, failed.output, missing) != null);

    try std.testing.expectError(error.Thrown, tool_run.runChecked(allocator, std.testing.io, log, .magick, &arguments));
    const expected = try std.fmt.allocPrint(allocator, "Command failed: magick {s} -resize 10x10 {s}\n{s}", .{ missing, output, failed.output });
    try std.testing.expectEqualStrings(expected, utils.errors.lastErrorMessage());
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

test "runLogged logs the command at verbose and returns what the tool printed when the tool works and the validation passes" {
    // The goal is to show that runLogged logs the command it runs at verbose. The method is the real ImageMagick reading the size of
    // the checked in test.png (100x90) and a memory log with verbose on.
    const memory = try utils.memory_log.MemoryLog.init(std.testing.allocator, .{
        .verbose = true,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tools = try MediaTools.init();
    defer tools.deinit();

    const output = try tool_run.runLogged(arena.allocator(), std.testing.io, memory.log, .magick, &.{ "identify", "-format", "%w %h", "../test/test.png" }, null);
    try std.testing.expectEqualStrings("100 90", output);
    try std.testing.expect(std.mem.indexOf(u8, memory.stdout(), "Executing magick with command: \"magick identify -format %w %h ../test/test.png\"") != null);
}

test "runLogged reports a failed validation as a failure to execute the command" {
    // The goal is to show that a failed validation is logged as an error and thrown as a failure to execute the command. The method
    // is the real ImageMagick running a command that works and a validation that always fails.
    const memory = try utils.memory_log.MemoryLog.init(std.testing.allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tools = try MediaTools.init();
    defer tools.deinit();
    var unused: u8 = 0;
    const description = "magick identify -format %w ../test/test.png";

    try std.testing.expectError(error.Thrown, tool_run.runLogged(arena.allocator(), std.testing.io, memory.log, .magick, &.{ "identify", "-format", "%w", "../test/test.png" }, .{
        .context = &unused,
        .function = failValidation,
    }));
    try std.testing.expectEqualStrings("Failed to execute command: " ++ description, utils.errors.lastErrorMessage());
    try std.testing.expect(std.mem.indexOf(u8, memory.stderr(), "Validation failed for command: " ++ description ++ "\nReason: no output file") != null);
    try std.testing.expect(std.mem.indexOf(u8, memory.stdout(), "===\nCommand: " ++ description ++ "\nCommand stdout:\n100\n") != null);
}

test "runLogged reports a tool that fails as a failure to execute the command" {
    // The goal is to show that a failing tool is logged and thrown as a failure to execute the command. The method is the real
    // ImageMagick converting a file that does not exist.
    const memory = try utils.memory_log.MemoryLog.init(std.testing.allocator, .{
        .verbose = false,
        .debug = false,
        .tools = false,
    });
    defer memory.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var tools = try MediaTools.init();
    defer tools.deinit();
    const missing = try tempFilePath(allocator, tmp_dir, "x.heic");
    const output = try tempFilePath(allocator, tmp_dir, "y.jpg");
    const description = try std.fmt.allocPrint(allocator, "magick {s} {s}", .{ missing, output });

    try std.testing.expectError(error.Thrown, tool_run.runLogged(allocator, std.testing.io, memory.log, .magick, &.{ missing, output }, null));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "Failed to execute command: {s}", .{description}), utils.errors.lastErrorMessage());
    try std.testing.expect(std.mem.indexOf(u8, memory.stderr(), try std.fmt.allocPrint(allocator, "Failed to execute command: {s}", .{description})) != null);
}

test "runChecked runs ffprobe and ffmpeg" {
    // The goal is to show that ffprobe and ffmpeg are reached by name. The method is the real ffprobe and ffmpeg giving their versions.
    const log = utils.mute_log.MuteLog.init();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tools = try MediaTools.init();
    defer tools.deinit();
    try std.testing.expect(std.mem.startsWith(u8, try tool_run.runChecked(arena.allocator(), std.testing.io, log, .ffprobe, &.{"-version"}), "ffprobe version "));
    try std.testing.expect(std.mem.startsWith(u8, try tool_run.runChecked(arena.allocator(), std.testing.io, log, .ffmpeg, &.{"-version"}), "ffmpeg version "));
}
