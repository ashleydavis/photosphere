//
// Stand-in for the parts of `node:tty` used by the CLI (this file has no TypeScript counterpart):
// `isTTY`, `columns`, `rows` and `setRawMode`.
// On Windows it uses the console API like libuv does, and `initConsole` stands in for the console setup the
// Bun runtime does at startup (UTF-8 code pages and virtual terminal processing of the output).
//

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

//
// A terminal stream: a file descriptor, or on Windows a standard handle identifier (resolved with GetStdHandle).
//
pub const Fd = if (builtin.os.tag == .windows) windows.DWORD else std.posix.fd_t;

//
// The terminal mode saved by enableRawMode: the termios settings, or on Windows the console mode.
//
pub const Mode = if (builtin.os.tag == .windows) windows.DWORD else std.posix.termios;

//
// The file descriptor of stdin.
//
pub const stdin_fd: Fd = if (builtin.os.tag == .windows) std_input_handle else 0;

//
// The file descriptor of stdout.
//
pub const stdout_fd: Fd = if (builtin.os.tag == .windows) std_output_handle else 1;

//
// The Windows standard handle identifier of stdin (STD_INPUT_HANDLE).
//
const std_input_handle: windows.DWORD = @bitCast(@as(i32, -10));

//
// The Windows standard handle identifier of stdout (STD_OUTPUT_HANDLE).
//
const std_output_handle: windows.DWORD = @bitCast(@as(i32, -11));

//
// The Windows standard handle identifier of stderr (STD_ERROR_HANDLE).
//
const std_error_handle: windows.DWORD = @bitCast(@as(i32, -12));

//
// Windows console input mode flag: translates keys to virtual terminal sequences (ENABLE_VIRTUAL_TERMINAL_INPUT).
//
const enable_virtual_terminal_input: windows.DWORD = 0x0200;

//
// Windows console output mode flag: processes control characters (ENABLE_PROCESSED_OUTPUT).
//
const enable_processed_output: windows.DWORD = 0x0001;

//
// Windows console output mode flag: processes virtual terminal sequences (ENABLE_VIRTUAL_TERMINAL_PROCESSING).
//
const enable_virtual_terminal_processing: windows.DWORD = 0x0004;

//
// The UTF-8 code page identifier (CP_UTF8).
//
const cp_utf8: windows.UINT = 65001;

//
// The value WaitForSingleObject returns when the handle is signaled (WAIT_OBJECT_0).
//
const wait_object_0: windows.DWORD = 0;

//
// The event type of a keyboard input record (KEY_EVENT).
//
const key_event: windows.WORD = 0x0001;

//
// A Windows console coordinate (COORD).
//
const Coord = extern struct {
    // The column.
    X: i16,

    // The row.
    Y: i16,
};

//
// A Windows console rectangle (SMALL_RECT).
//
const SmallRect = extern struct {
    // The left column.
    Left: i16,

    // The top row.
    Top: i16,

    // The right column.
    Right: i16,

    // The bottom row.
    Bottom: i16,
};

//
// Information about a Windows console screen buffer (CONSOLE_SCREEN_BUFFER_INFO).
//
const ConsoleScreenBufferInfo = extern struct {
    // The size of the screen buffer.
    dwSize: Coord,

    // The cursor position.
    dwCursorPosition: Coord,

    // The character attributes.
    wAttributes: windows.WORD,

    // The visible window within the screen buffer.
    srWindow: SmallRect,

    // The maximum window size.
    dwMaximumWindowSize: Coord,
};

//
// A keyboard event of the Windows console (KEY_EVENT_RECORD).
//
const KeyEventRecord = extern struct {
    // True when the key is pressed, false when it is released.
    bKeyDown: windows.BOOL,

    // The repeat count.
    wRepeatCount: windows.WORD,

    // The virtual key code.
    wVirtualKeyCode: windows.WORD,

    // The virtual scan code.
    wVirtualScanCode: windows.WORD,

    // The character of the key (0 when the key produces no character).
    UnicodeChar: windows.WCHAR,

    // The state of the control keys.
    dwControlKeyState: windows.DWORD,
};

//
// An input event of the Windows console (INPUT_RECORD); only keyboard events are inspected.
//
const InputRecord = extern struct {
    // The type of the event.
    EventType: windows.WORD,

    // The event (a KeyEventRecord when EventType is key_event).
    Event: KeyEventRecord,
};

//
// Gets a standard handle (kernel32).
//
extern "kernel32" fn GetStdHandle(nStdHandle: windows.DWORD) callconv(.winapi) ?windows.HANDLE;

//
// Gets the mode of a console handle; fails when the handle is not a console (kernel32).
//
extern "kernel32" fn GetConsoleMode(hConsoleHandle: windows.HANDLE, lpMode: *windows.DWORD) callconv(.winapi) windows.BOOL;

//
// Sets the mode of a console handle (kernel32).
//
extern "kernel32" fn SetConsoleMode(hConsoleHandle: windows.HANDLE, dwMode: windows.DWORD) callconv(.winapi) windows.BOOL;

//
// Gets the size and window of a console screen buffer (kernel32).
//
extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: windows.HANDLE, lpConsoleScreenBufferInfo: *ConsoleScreenBufferInfo) callconv(.winapi) windows.BOOL;

//
// Sets the input code page of the console (kernel32).
//
extern "kernel32" fn SetConsoleCP(wCodePageID: windows.UINT) callconv(.winapi) windows.BOOL;

//
// Sets the output code page of the console (kernel32).
//
extern "kernel32" fn SetConsoleOutputCP(wCodePageID: windows.UINT) callconv(.winapi) windows.BOOL;

//
// Waits until a handle is signaled or the timeout elapses (kernel32).
//
extern "kernel32" fn WaitForSingleObject(hHandle: windows.HANDLE, dwMilliseconds: windows.DWORD) callconv(.winapi) windows.DWORD;

//
// Reads console input events without removing them from the input buffer (kernel32).
//
extern "kernel32" fn PeekConsoleInputW(hConsoleInput: windows.HANDLE, lpBuffer: *InputRecord, nLength: windows.DWORD, lpNumberOfEventsRead: *windows.DWORD) callconv(.winapi) windows.BOOL;

//
// Reads and removes console input events from the input buffer (kernel32).
//
extern "kernel32" fn ReadConsoleInputW(hConsoleInput: windows.HANDLE, lpBuffer: *InputRecord, nLength: windows.DWORD, lpNumberOfEventsRead: *windows.DWORD) callconv(.winapi) windows.BOOL;

//
// The number of milliseconds since the system started (kernel32).
//
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

//
// Gets the console mode of a Windows standard handle, or null when the handle is not a console.
//
fn consoleMode(fd: Fd) ?windows.DWORD {
    const handle = GetStdHandle(fd) orelse return null;
    var mode: windows.DWORD = 0;
    if (!GetConsoleMode(handle, &mode).toBool()) {
        return null;
    }
    return mode;
}

//
// Sets up the Windows console like the Bun runtime does at startup: UTF-8 input and output code pages and
// virtual terminal processing on stdout and stderr (so ANSI escape codes work). Does nothing on other platforms.
//
pub fn initConsole() void {
    if (builtin.os.tag != .windows) {
        return;
    }
    _ = SetConsoleCP(cp_utf8);
    _ = SetConsoleOutputCP(cp_utf8);
    const outputs = [_]Fd{ std_output_handle, std_error_handle };
    for (outputs) |output| {
        if (consoleMode(output)) |mode| {
            _ = SetConsoleMode(GetStdHandle(output).?, mode | enable_processed_output | enable_virtual_terminal_processing);
        }
    }
}

//
// True when the file descriptor refers to a terminal (`stream.isTTY`).
//
pub fn isatty(fd: Fd) bool {
    if (builtin.os.tag == .windows) {
        return consoleMode(fd) != null;
    }
    _ = std.posix.tcgetattr(fd) catch return false;
    return true;
}

//
// The size of a terminal.
//
const TerminalSize = struct {
    // The number of columns.
    col: usize,

    // The number of rows.
    row: usize,
};

//
// Gets the terminal size of the file descriptor, or null when it is not a terminal.
// On Windows it is the size of the visible console window (as libuv reports it).
//
fn windowSize(fd: Fd) ?TerminalSize {
    if (builtin.os.tag == .windows) {
        const handle = GetStdHandle(fd) orelse return null;
        var info: ConsoleScreenBufferInfo = undefined;
        if (!GetConsoleScreenBufferInfo(handle, &info).toBool()) {
            return null;
        }
        return .{
            .col = @intCast(@as(i32, info.srWindow.Right) - info.srWindow.Left + 1),
            .row = @intCast(@as(i32, info.srWindow.Bottom) - info.srWindow.Top + 1),
        };
    }
    if (builtin.os.tag != .linux) {
        return null;
    }
    var size: std.posix.winsize = undefined;
    const handle: usize = @bitCast(@as(isize, fd));
    const result = std.os.linux.syscall3(.ioctl, handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&size));
    if (std.os.linux.errno(result) != .SUCCESS) {
        return null;
    }
    return .{ .col = size.col, .row = size.row };
}

//
// The number of columns of the terminal (`stream.columns`), or null when it is not a terminal.
//
pub fn columns(fd: Fd) ?usize {
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
pub fn rows(fd: Fd) ?usize {
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
// On Windows the console input is switched to unbuffered, unechoed virtual terminal input, so keys arrive as the
// same byte sequences as on a POSIX terminal (Ctrl+C arrives as a byte instead of a signal).
//
pub fn enableRawMode(fd: Fd) !Mode {
    if (builtin.os.tag == .windows) {
        const windowsOriginal = consoleMode(fd) orelse return error.NotATerminal;
        if (!SetConsoleMode(GetStdHandle(fd).?, enable_virtual_terminal_input).toBool()) {
            return error.NotATerminal;
        }
        return windowsOriginal;
    }
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
pub fn restoreMode(fd: Fd, mode: Mode) void {
    if (builtin.os.tag == .windows) {
        if (GetStdHandle(fd)) |handle| {
            _ = SetConsoleMode(handle, mode);
        }
        return;
    }
    std.posix.tcsetattr(fd, .FLUSH, mode) catch {};
}

//
// Waits up to the given number of milliseconds for input that produces bytes (a key press with a character) on a
// Windows console, discarding other console events (key releases, focus changes). Returns true when such input
// is ready. Used on Windows in place of poll().
//
pub fn waitForConsoleInput(fd: Fd, timeoutMilliseconds: u64) bool {
    if (builtin.os.tag != .windows) {
        return false;
    }
    const handle = GetStdHandle(fd) orelse return false;
    const deadline = GetTickCount64() + timeoutMilliseconds;
    while (true) {
        const now = GetTickCount64();
        if (now >= deadline) {
            return false;
        }
        if (WaitForSingleObject(handle, @intCast(deadline - now)) != wait_object_0) {
            return false;
        }
        var record: InputRecord = undefined;
        var count: windows.DWORD = 0;
        if (!PeekConsoleInputW(handle, &record, 1, &count).toBool() or count == 0) {
            return false;
        }
        if (record.EventType == key_event and record.Event.bKeyDown.toBool() and record.Event.UnicodeChar != 0) {
            return true;
        }
        if (!ReadConsoleInputW(handle, &record, 1, &count).toBool()) {
            return false;
        }
    }
}
