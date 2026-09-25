const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli-zig");

test "userArgs skips the executable" {
    cli.process_argv.setArgv(&.{ "psi", "verify", "--db", "x" });
    defer cli.process_argv.setArgv(&.{});
    try std.testing.expectEqual(@as(usize, 4), cli.process_argv.getArgv().len);
    const userArgs = cli.process_argv.userArgs();
    try std.testing.expectEqual(@as(usize, 3), userArgs.len);
    try std.testing.expectEqualStrings("verify", userArgs[0]);
    cli.process_argv.setArgv(&.{"psi"});
    try std.testing.expectEqual(@as(usize, 0), cli.process_argv.userArgs().len);
}

test "a pipe is not a TTY and has no size" {
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }
    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.pipe(&fds));
    defer _ = std.os.linux.close(fds[0]);
    defer _ = std.os.linux.close(fds[1]);
    try std.testing.expect(!cli.tty.isatty(fds[0]));
    try std.testing.expect(cli.tty.columns(fds[1]) == null);
    try std.testing.expect(cli.tty.rows(fds[1]) == null);
    try std.testing.expectError(error.NotATerminal, cli.tty.enableRawMode(fds[0]));
}

test "config holds the development version" {
    try std.testing.expectEqualStrings("dev", cli.config.version);
    try std.testing.expectEqualStrings("dev", cli.config.buildMetadata.commitHash);
    try std.testing.expect(!cli.config.buildMetadata.isNightly);
}

test "initConsole leaves the terminal alone outside Windows" {
    if (builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }
    cli.tty.initConsole();
    try std.testing.expect(cli.tty.stdin_fd == 0);
    try std.testing.expect(cli.tty.stdout_fd == 1);
}

test "waitForConsoleInput reports no input when there is no Windows console" {
    if (builtin.os.tag == .windows) {
        return error.SkipZigTest;
    }
    try std.testing.expect(!cli.tty.waitForConsoleInput(cli.tty.stdin_fd, 10));
}

//
// The color depth tty.getColorDepth reports for an environment given as name/value pairs.
//
fn colorDepthFor(pairs: []const [2][]const u8) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    for (pairs) |pair| {
        try environment.put(pair[0], pair[1]);
    }
    return cli.tty.getColorDepth(&environment);
}

test "getColorDepth reads the environment like Node's getColorDepth" {
    try std.testing.expectEqual(@as(u8, 4), try colorDepthFor(&.{.{ "FORCE_COLOR", "" }}));
    try std.testing.expectEqual(@as(u8, 4), try colorDepthFor(&.{.{ "FORCE_COLOR", "true" }}));
    try std.testing.expectEqual(@as(u8, 8), try colorDepthFor(&.{.{ "FORCE_COLOR", "2" }}));
    try std.testing.expectEqual(@as(u8, 24), try colorDepthFor(&.{.{ "FORCE_COLOR", "3" }}));
    try std.testing.expectEqual(@as(u8, 1), try colorDepthFor(&.{.{ "FORCE_COLOR", "0" }}));
    try std.testing.expectEqual(@as(u8, 1), try colorDepthFor(&.{.{ "NO_COLOR", "" }}));
    try std.testing.expectEqual(@as(u8, 1), try colorDepthFor(&.{.{ "NODE_DISABLE_COLORS", "1" }}));
    try std.testing.expectEqual(@as(u8, 1), try colorDepthFor(&.{.{ "TERM", "dumb" }}));
    try std.testing.expectEqual(@as(u8, 1), cli.tty.getColorDepth(null));
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(@as(u8, 24), try colorDepthFor(&.{}));
        return;
    }
    try std.testing.expectEqual(@as(u8, 1), try colorDepthFor(&.{}));
    try std.testing.expectEqual(@as(u8, 24), try colorDepthFor(&.{.{ "TMUX", "1" }}));
    try std.testing.expectEqual(@as(u8, 24), try colorDepthFor(&.{ .{ "CI", "true" }, .{ "GITHUB_ACTIONS", "true" } }));
    try std.testing.expectEqual(@as(u8, 8), try colorDepthFor(&.{ .{ "CI", "true" }, .{ "CI_NAME", "codeship" } }));
    try std.testing.expectEqual(@as(u8, 1), try colorDepthFor(&.{.{ "CI", "true" }}));
    try std.testing.expectEqual(@as(u8, 4), try colorDepthFor(&.{.{ "TEAMCITY_VERSION", "9.1.0" }}));
    try std.testing.expectEqual(@as(u8, 4), try colorDepthFor(&.{.{ "TEAMCITY_VERSION", "2023.05" }}));
    try std.testing.expectEqual(@as(u8, 1), try colorDepthFor(&.{.{ "TEAMCITY_VERSION", "9.0.1" }}));
    try std.testing.expectEqual(@as(u8, 1), try colorDepthFor(&.{.{ "TEAMCITY_VERSION", "8.1.0" }}));
    try std.testing.expectEqual(@as(u8, 8), try colorDepthFor(&.{.{ "TERM_PROGRAM", "iTerm.app" }}));
    try std.testing.expectEqual(@as(u8, 8), try colorDepthFor(&.{ .{ "TERM_PROGRAM", "iTerm.app" }, .{ "TERM_PROGRAM_VERSION", "2.9" } }));
    try std.testing.expectEqual(@as(u8, 24), try colorDepthFor(&.{ .{ "TERM_PROGRAM", "iTerm.app" }, .{ "TERM_PROGRAM_VERSION", "3.4" } }));
    try std.testing.expectEqual(@as(u8, 24), try colorDepthFor(&.{.{ "TERM_PROGRAM", "HyperTerm" }}));
    try std.testing.expectEqual(@as(u8, 8), try colorDepthFor(&.{.{ "TERM_PROGRAM", "Apple_Terminal" }}));
    try std.testing.expectEqual(@as(u8, 1), try colorDepthFor(&.{.{ "TERM_PROGRAM", "other" }}));
    try std.testing.expectEqual(@as(u8, 24), try colorDepthFor(&.{.{ "COLORTERM", "truecolor" }}));
    try std.testing.expectEqual(@as(u8, 24), try colorDepthFor(&.{.{ "TERM", "xterm-truecolor" }}));
    try std.testing.expectEqual(@as(u8, 8), try colorDepthFor(&.{.{ "TERM", "xterm-256color" }}));
    try std.testing.expectEqual(@as(u8, 24), try colorDepthFor(&.{.{ "TERM", "XTERM-KITTY" }}));
    try std.testing.expectEqual(@as(u8, 4), try colorDepthFor(&.{.{ "TERM", "cons25" }}));
    try std.testing.expectEqual(@as(u8, 4), try colorDepthFor(&.{.{ "TERM", "xterm" }}));
    try std.testing.expectEqual(@as(u8, 4), try colorDepthFor(&.{.{ "TERM", "screen" }}));
    try std.testing.expectEqual(@as(u8, 4), try colorDepthFor(&.{.{ "TERM", "linux" }}));
    try std.testing.expectEqual(@as(u8, 4), try colorDepthFor(&.{.{ "TERM", "con132x25" }}));
    try std.testing.expectEqual(@as(u8, 1), try colorDepthFor(&.{.{ "TERM", "conx" }}));
    try std.testing.expectEqual(@as(u8, 1), try colorDepthFor(&.{.{ "TERM", "unknown" }}));
    try std.testing.expectEqual(@as(u8, 4), try colorDepthFor(&.{ .{ "TERM", "unknown" }, .{ "COLORTERM", "yes" } }));
}

test "hasColors compares the count with the color depth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environment = std.process.Environ.Map.init(arena.allocator());
    try environment.put("FORCE_COLOR", "1");
    try std.testing.expect(cli.tty.hasColors(16, &environment));
    try std.testing.expect(!cli.tty.hasColors(256, &environment));
    try std.testing.expect(cli.tty.hasColors(2, null));
    try std.testing.expect(!cli.tty.hasColors(16, null) or builtin.os.tag == .windows);
}
