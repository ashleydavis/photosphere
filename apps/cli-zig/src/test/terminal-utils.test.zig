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
// Runs the write-progress scenario of the test driver (writeProgress then clearProgressMessage) with a
// pseudo-terminal as stdout, and returns what reached the terminal.
//
fn writeProgressOnTerminal(allocator: std.mem.Allocator, message: []const u8, verbose: []const u8) ![]const u8 {
    const io = std.testing.io;
    const terminal = try openPseudoTerminal(allocator);
    defer terminal.master.close(io);
    const resultDir = try helpers.makeTempDir(allocator, "terminal-utils");
    defer std.Io.Dir.cwd().deleteTree(io, resultDir) catch {};
    var environment = std.process.Environ.Map.init(allocator);
    var child = std.process.spawn(io, .{
        .argv = &.{ helpers.test_driver_path, try std.fs.path.join(allocator, &.{ resultDir, "result.json" }), "write-progress", message, verbose },
        .environ_map = &environment,
        .stdin = .ignore,
        .stdout = .{ .file = terminal.slave },
        .stderr = .inherit,
    }) catch |err| {
        terminal.slave.close(io);
        return err;
    };
    terminal.slave.close(io);
    const term = try child.wait(io);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, term);

    // With the slave closed everywhere, reading the master gives what was written, then fails with EIO.
    var output: std.ArrayList(u8) = .empty;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = terminal.master.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.InputOutput, error.EndOfStream => break,
            else => return err,
        };
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

    const output = try writeProgressOnTerminal(arena.allocator(), "Copying files...", "false");

    try std.testing.expectEqualStrings("\x1b[2K\x1b[1GCopying files...\x1b[2K\x1b[1G", output);
}

test "writeProgress writes nothing when stdout is not a TTY" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var environment = std.process.Environ.Map.init(allocator);

    const result = try helpers.runTestDriver(allocator, &.{ "write-progress", "Copying files...", "false" }, &.{}, &environment);

    try std.testing.expectEqualStrings("", result.stdout);
}

test "writeProgress writes nothing when verbose logging is enabled" {
    if (builtin.os.tag == .windows) {
        // A Windows console cannot be given to a child and read back by a test.
        return error.SkipZigTest;
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const output = try writeProgressOnTerminal(arena.allocator(), "Copying files...", "true");

    try std.testing.expectEqualStrings("", output);
}
