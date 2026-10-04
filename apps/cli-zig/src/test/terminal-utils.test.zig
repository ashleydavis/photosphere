const std = @import("std");
const builtin = @import("builtin");
const helpers = @import("test-helpers.zig");

//
// A pseudo-terminal: the child writes to the slave side, which is a TTY, and the test reads the master side.
//
const PseudoTerminal = struct {
    // The master side, read by the test.
    master: std.Io.File,

    // The slave side, given to the child as stdout.
    slave: std.Io.File,
};

//
// Opens a pseudo-terminal (POSIX posix_openpt, grantpt, unlockpt and ptsname, from libc on macOS).
//
extern "c" fn posix_openpt(flags: c_int) c_int;

//
// Grants access to the slave side of a pseudo-terminal (libc).
//
extern "c" fn grantpt(fd: c_int) c_int;

//
// Unlocks the slave side of a pseudo-terminal (libc).
//
extern "c" fn unlockpt(fd: c_int) c_int;

//
// Gets the path of the slave side of a pseudo-terminal (libc).
//
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;

//
// Opens a pseudo-terminal (on Linux through /dev/ptmx, on macOS through libc).
//
fn openPseudoTerminal(allocator: std.mem.Allocator) !PseudoTerminal {
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const master = try cwd.openFile(io, "/dev/ptmx", .{ .mode = .read_write });
        errdefer master.close(io);
        var unlock: c_int = 0;
        if (linux.errno(linux.ioctl(master.handle, linux.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS) {
            return error.PseudoTerminalUnlockFailed;
        }
        var number: c_uint = 0;
        if (linux.errno(linux.ioctl(master.handle, linux.T.IOCGPTN, @intFromPtr(&number))) != .SUCCESS) {
            return error.PseudoTerminalNumberUnavailable;
        }
        const slave = try cwd.openFile(io, try std.fmt.allocPrint(allocator, "/dev/pts/{d}", .{number}), .{ .mode = .read_write });
        return .{ .master = master, .slave = slave };
    }
    else {
        return openPseudoTerminalWithLibc(io);
    }
}

//
// Opens a pseudo-terminal through libc (macOS and other POSIX systems).
//
fn openPseudoTerminalWithLibc(io: std.Io) !PseudoTerminal {
    const cwd = std.Io.Dir.cwd();
    const masterFd = posix_openpt(@bitCast(std.posix.O{ .ACCMODE = .RDWR, .NOCTTY = true }));
    if (masterFd < 0) {
        return error.PseudoTerminalOpenFailed;
    }
    const master: std.Io.File = .{ .handle = masterFd, .flags = .{ .nonblocking = false } };
    errdefer master.close(io);
    if (grantpt(masterFd) != 0 or unlockpt(masterFd) != 0) {
        return error.PseudoTerminalUnlockFailed;
    }
    const slavePath = ptsname(masterFd) orelse return error.PseudoTerminalNumberUnavailable;
    const slave = try cwd.openFile(io, std.mem.span(slavePath), .{ .mode = .read_write });
    return .{ .master = master, .slave = slave };
}

//
// The directories `psi check` is run on: a database made by `psi init`, an empty directory to search for files in, and
// the environment variables that keep psi's configuration and temporary files in a directory of the test's own.
//
const ICheckSetup = struct {
    // The directory that holds everything, deleted by the test.
    root: []const u8,

    // The arguments of `psi check` on the database and the empty directory.
    arguments: []const []const u8,

    // The environment variables psi runs with.
    environment: *const std.process.Environ.Map,

    // The absolute path of psi.
    psiPath: []const u8,
};

//
// Makes a database and an empty directory for `psi check`. The first thing `psi check` writes is the progress message
// "Searching for files...", and with nothing in the directory it writes no other until it clears the line.
//
fn setUpCheck(allocator: std.mem.Allocator, verbose: bool) !ICheckSetup {
    const io = std.testing.io;
    const root = try helpers.makeTempDir(allocator, "terminal-utils");
    const environment = try helpers.cliEnvironment(allocator, root);
    const psiPath = try helpers.absolutePsiPath(allocator);
    const database = try std.fs.path.join(allocator, &.{ root, "db" });
    const searched = try std.fs.path.join(allocator, &.{ root, "empty" });
    try std.Io.Dir.cwd().createDirPath(io, searched);
    const created = try helpers.runCli(allocator, &.{ psiPath, "init", "--db", database, "--yes" }, environment);
    try std.testing.expectEqual(@as(u8, 0), created.exitCode);
    var arguments: std.ArrayList([]const u8) = .empty;
    try arguments.appendSlice(allocator, &.{ "check", "--db", database, searched, "--yes" });
    if (verbose) {
        try arguments.append(allocator, "--verbose");
    }
    return .{ .root = root, .arguments = arguments.items, .environment = environment, .psiPath = psiPath };
}

//
// Runs `psi check` (see setUpCheck) with a pseudo-terminal as stdout, and returns what reached the terminal.
//
fn checkOnTerminal(allocator: std.mem.Allocator, verbose: bool) ![]const u8 {
    const io = std.testing.io;
    const terminal = try openPseudoTerminal(allocator);
    defer terminal.master.close(io);
    const setup = try setUpCheck(allocator, verbose);
    defer std.Io.Dir.cwd().deleteTree(io, setup.root) catch {};
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, setup.psiPath);
    try argv.appendSlice(allocator, setup.arguments);
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = setup.environment,
        .stdin = .ignore,
        .stdout = .{ .file = terminal.slave },
        .stderr = .inherit,
    }) catch |err| {
        terminal.slave.close(io);
        return err;
    };

    // The slave stays open here until the master has been read: macOS discards what is waiting on the master
    // once the last slave descriptor is closed (Linux keeps it). With the child gone, everything it wrote is
    // already waiting, so the master is read until nothing more is ready.
    defer terminal.slave.close(io);
    const term = try child.wait(io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);

    var output: std.ArrayList(u8) = .empty;
    var buffer: [4096]u8 = undefined;
    while (true) {
        var pollFds = [1]std.posix.pollfd{.{
            .fd = terminal.master.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&pollFds, 0) == 0) {
            break;
        }
        const count = try terminal.master.readStreaming(io, &.{&buffer});
        if (count == 0) {
            break;
        }
        try output.appendSlice(allocator, buffer[0..count]);
    }
    return output.items;
}

test "writeProgress clears the line and writes the message on a TTY" {
    if (builtin.os.tag == .windows) {
        // A Windows console cannot be given to a child and read back by a test.
        return error.SkipZigTest;
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const output = try checkOnTerminal(arena.allocator(), false);

    // The line is cleared, the message written, and the line cleared again.
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[2K\x1b[1GSearching for files...\x1b[2K\x1b[1G") != null);
}

test "writeProgress writes nothing when stdout is not a TTY" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const setup = try setUpCheck(allocator, false);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, setup.root) catch {};
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, setup.psiPath);
    try argv.appendSlice(allocator, setup.arguments);

    const result = try helpers.runCli(allocator, argv.items, setup.environment);

    try std.testing.expectEqual(@as(u8, 0), result.exitCode);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Searching for files...") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\x1b[2K") == null);
}

test "writeProgress writes nothing when verbose logging is enabled" {
    if (builtin.os.tag == .windows) {
        // A Windows console cannot be given to a child and read back by a test.
        return error.SkipZigTest;
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const output = try checkOnTerminal(arena.allocator(), true);

    try std.testing.expect(std.mem.indexOf(u8, output, "Searching for files...") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[2K") == null);
}
