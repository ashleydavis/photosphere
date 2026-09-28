const std = @import("std");
const builtin = @import("builtin");

//
// This file has no TypeScript counterpart: it stands in for the streams behind `process.stdin`,
// `process.stdout` and `process.stderr`.
//
// On Windows, std.Io.File.stdin(), stdout() and stderr() always describe the handle as opened for
// synchronous I/O. A handle inherited from the parent can be asynchronous (overlapped) instead: the pipes
// that MSYS2 and Cygwin shells (Git Bash, which the CI uses) create for `a | b` are. Writing to one of those
// through a File that says synchronous is fine while the pipe has room, but as soon as the reader falls
// behind, NtWriteFile answers STATUS_PENDING, which the synchronous path of std treats as unreachable, and
// the process panics part way through its output.
//
// The functions here ask Windows how each handle was really opened and describe it that way, so std waits
// for the pending write to complete instead.
//

//
// Returns `file` with its nonblocking flag set from how its handle was actually opened (on Windows,
// nonblocking means opened for asynchronous I/O). Anything whose mode cannot be read, such as a missing
// standard handle, is returned unchanged, and so is every file on other platforms.
//
pub fn withActualMode(file: std.Io.File) std.Io.File {
    if (builtin.os.tag != .windows) {
        return file;
    }

    const windows = std.os.windows;
    var io_status_block: windows.IO_STATUS_BLOCK = undefined;
    var mode_information: windows.FILE.MODE.INFORMATION = undefined;
    const status = windows.ntdll.NtQueryInformationFile(
        file.handle,
        &io_status_block,
        &mode_information,
        @sizeOf(windows.FILE.MODE.INFORMATION),
        .Mode,
    );
    if (status != .SUCCESS) {
        return file;
    }

    var result = file;
    result.flags.nonblocking = mode_information.Mode.IO == .ASYNCHRONOUS;
    return result;
}

//
// The standard input of the process (`process.stdin`).
//
pub fn stdin() std.Io.File {
    return withActualMode(std.Io.File.stdin());
}

//
// The standard output of the process (`process.stdout`).
//
pub fn stdout() std.Io.File {
    return withActualMode(std.Io.File.stdout());
}

//
// The standard error of the process (`process.stderr`).
//
pub fn stderr() std.Io.File {
    return withActualMode(std.Io.File.stderr());
}
