//
// Stand-in for the parts of `node:tty` used by the CLI (this file has no TypeScript counterpart):
// `isTTY`, `columns`, `rows` and `setRawMode`.
//

const std = @import("std");
const builtin = @import("builtin");

//
// The file descriptor of stdin.
//
pub const stdin_fd: std.posix.fd_t = 0;

//
// The file descriptor of stdout.
//
pub const stdout_fd: std.posix.fd_t = 1;

//
// True when the file descriptor refers to a terminal (`stream.isTTY`).
//
pub fn isatty(fd: std.posix.fd_t) bool {
    if (builtin.os.tag == .windows) {
        return false;
    }
    _ = std.posix.tcgetattr(fd) catch return false;
    return true;
}

//
// Gets the terminal size of the file descriptor, or null when it is not a terminal.
//
fn windowSize(fd: std.posix.fd_t) ?std.posix.winsize {
    if (builtin.os.tag != .linux) {
        return null;
    }
    var size: std.posix.winsize = undefined;
    const handle: usize = @bitCast(@as(isize, fd));
    const result = std.os.linux.syscall3(.ioctl, handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&size));
    if (std.os.linux.errno(result) != .SUCCESS) {
        return null;
    }
    return size;
}

//
// The number of columns of the terminal (`stream.columns`), or null when it is not a terminal.
//
pub fn columns(fd: std.posix.fd_t) ?usize {
    if (!isatty(fd)) {
        return null;
    }
    const size = windowSize(fd) orelse return null;
    if (size.col == 0) {
        return null;
    }
    return size.col;
}

//
// The number of rows of the terminal (`stream.rows`), or null when it is not a terminal.
//
pub fn rows(fd: std.posix.fd_t) ?usize {
    if (!isatty(fd)) {
        return null;
    }
    const size = windowSize(fd) orelse return null;
    if (size.row == 0) {
        return null;
    }
    return size.row;
}

//
// Switches a terminal to raw mode (as libuv's UV_TTY_MODE_RAW does) or restores the given original mode.
// Returns the mode that was active before switching to raw mode.
//
pub fn enableRawMode(fd: std.posix.fd_t) !std.posix.termios {
    const original = try std.posix.tcgetattr(fd);
    var raw = original;
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    raw.oflag.ONLCR = true;
    raw.cflag.CSIZE = .CS8;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(fd, .FLUSH, raw);
    return original;
}

//
// Restores a terminal mode saved by enableRawMode.
//
pub fn restoreMode(fd: std.posix.fd_t, mode: std.posix.termios) void {
    std.posix.tcsetattr(fd, .FLUSH, mode) catch {};
}
