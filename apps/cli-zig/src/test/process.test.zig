const std = @import("std");
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
