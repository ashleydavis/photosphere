const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const errors = utils.errors;
const process_env = @import("process-env.zig");

//
// The output of a command run with exec (TypeScript: `{ stdout: string; stderr: string }`).
//
pub const ExecResult = struct {
    // Everything the command wrote to stdout.
    stdout: []const u8,

    // Everything the command wrote to stderr.
    stderr: []const u8,
};

//
// Executes a command using the specified tool.
// Like Node's `child_process.exec`, the command runs in the shell (/bin/sh -c, or cmd.exe on Windows)
// with the environment of `process.env` (see process-env.zig), and fails when the command cannot be
// started or exits with a non-zero code. The error message is Node's: "Command failed: <command>\n<stderr>".
//
pub fn exec(allocator: std.mem.Allocator, io: std.Io, command: []const u8) !ExecResult {
    if (builtin.os.tag == .windows) {
        return execWindows(allocator, command);
    }
    const argv: []const []const u8 = &.{ "/bin/sh", "-c", command };
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = process_env.getEnvironMap(),
    }) catch |err| {
        return errors.throwError("Command failed: {s}\n{s}", .{ command, @errorName(err) });
    };
    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) {
        return errors.throwError("Command failed: {s}\n{s}", .{ command, result.stderr });
    }
    return .{ .stdout = result.stdout, .stderr = result.stderr };
}

//
// The Windows version of exec. Node's exec runs `cmd.exe /d /s /c "<command>"` with that command line
// passed verbatim (libuv's windowsVerbatimArguments), so the quotes inside the command reach cmd.exe
// untouched. std.process quotes each argument instead, turning those quotes into \", so the process is
// created here with CreateProcessW.
//
fn execWindows(allocator: std.mem.Allocator, command: []const u8) !ExecResult {
    const result = runCmdExe(allocator, command) catch |err| {
        return errors.throwError("Command failed: {s}\n{s}", .{ command, @errorName(err) });
    };
    if (result.exitCode != 0) {
        return errors.throwError("Command failed: {s}\n{s}", .{ command, result.stderr });
    }
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

//
// The Windows API functions runCmdExe calls that std.os.windows does not declare.
//
const kernel32 = struct {
    // Creates an anonymous pipe.
    extern "kernel32" fn CreatePipe(
        hReadPipe: *std.os.windows.HANDLE,
        hWritePipe: *std.os.windows.HANDLE,
        lpPipeAttributes: ?*std.os.windows.SECURITY_ATTRIBUTES,
        nSize: std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.BOOL;

    // Sets the properties of a handle, here whether child processes inherit it.
    extern "kernel32" fn SetHandleInformation(
        hObject: std.os.windows.HANDLE,
        dwMask: std.os.windows.DWORD,
        dwFlags: std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.BOOL;

    // Reads from a file or a pipe.
    extern "kernel32" fn ReadFile(
        hFile: std.os.windows.HANDLE,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: std.os.windows.DWORD,
        lpNumberOfBytesRead: ?*std.os.windows.DWORD,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) std.os.windows.BOOL;

    // Waits until the object (here a process) is signaled.
    extern "kernel32" fn WaitForSingleObject(
        hHandle: std.os.windows.HANDLE,
        dwMilliseconds: std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.DWORD;

    // Gets the exit code of a process.
    extern "kernel32" fn GetExitCodeProcess(
        hProcess: std.os.windows.HANDLE,
        lpExitCode: *std.os.windows.DWORD,
    ) callconv(.winapi) std.os.windows.BOOL;

    // The flag of SetHandleInformation that makes a handle inherited by child processes.
    const HANDLE_FLAG_INHERIT: std.os.windows.DWORD = 0x00000001;

    // The timeout of WaitForSingleObject that waits for ever.
    const INFINITE: std.os.windows.DWORD = 0xFFFFFFFF;

    // The value WaitForSingleObject returns when it fails.
    const WAIT_FAILED: std.os.windows.DWORD = 0xFFFFFFFF;
};

//
// The output and the exit code of a command run by runCmdExe.
//
const ICmdExeResult = struct {
    // Everything the command wrote to stdout.
    stdout: []const u8,

    // Everything the command wrote to stderr.
    stderr: []const u8,

    // The exit code of cmd.exe.
    exitCode: std.os.windows.DWORD,
};

//
// A pipe between this process and a child process.
//
const IChildPipe = struct {
    // The end this process keeps, which the child process does not inherit.
    parentEnd: std.os.windows.HANDLE,

    // The end the child process inherits.
    childEnd: std.os.windows.HANDLE,
};

//
// Creates a pipe for a stdio stream of a child process: the child reads from it when childReads is true
// (stdin) and writes to it otherwise (stdout and stderr).
//
fn createChildPipe(childReads: bool) !IChildPipe {
    const windows = std.os.windows;
    var inheritable: windows.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = .TRUE,
    };
    var readEnd: windows.HANDLE = undefined;
    var writeEnd: windows.HANDLE = undefined;
    if (kernel32.CreatePipe(&readEnd, &writeEnd, &inheritable, 0) == .FALSE) {
        return windows.unexpectedError(windows.GetLastError());
    }
    const pipe: IChildPipe = if (childReads)
        .{
            .parentEnd = writeEnd,
            .childEnd = readEnd,
        }
    else
        .{
            .parentEnd = readEnd,
            .childEnd = writeEnd,
        };
    if (kernel32.SetHandleInformation(pipe.parentEnd, kernel32.HANDLE_FLAG_INHERIT, 0) == .FALSE) {
        return windows.unexpectedError(windows.GetLastError());
    }
    return pipe;
}

//
// Reads a pipe to its end (when the child process has closed its end), appending what it reads to output.
// The output grows with std.heap.smp_allocator since two pipes are read at the same time on two threads.
//
fn readPipe(handle: std.os.windows.HANDLE, output: *std.ArrayList(u8)) !void {
    const windows = std.os.windows;
    var buffer: [4096]u8 = undefined;
    while (true) {
        var bytesRead: windows.DWORD = 0;
        if (kernel32.ReadFile(handle, &buffer, buffer.len, &bytesRead, null) == .FALSE) {
            const lastError = windows.GetLastError();
            if (lastError == .BROKEN_PIPE) {
                return;
            }
            return windows.unexpectedError(lastError);
        }
        try output.appendSlice(std.heap.smp_allocator, buffer[0..bytesRead]);
    }
}

//
// Reads a pipe to its end on a thread of its own, so the stdout and the stderr of a command are read at
// the same time: a command that fills one pipe while the other is being read would otherwise never finish.
//
const IPipeReader = struct {
    // The end of the pipe this process reads.
    handle: std.os.windows.HANDLE,

    // Everything read from the pipe.
    output: std.ArrayList(u8),

    // The error that stopped the reading, or null when the pipe was read to its end.
    failure: ?anyerror,

    // The function the thread runs.
    fn run(self: *IPipeReader) void {
        readPipe(self.handle, &self.output) catch |err| {
            self.failure = err;
        };
    }
};

//
// Runs `cmd.exe /d /s /c "<command>"` with the environment of `process.env`, stdin reading nothing and
// stdout and stderr read to their ends, then waits for it to exit.
//
fn runCmdExe(allocator: std.mem.Allocator, command: []const u8) !ICmdExeResult {
    const windows = std.os.windows;
    const commandLine = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, try std.fmt.allocPrint(allocator, "cmd.exe /d /s /c \"{s}\"", .{command}));
    const environmentBlock: ?[*:0]const u16 = if (process_env.getEnvironMap()) |environMap|
        (try environMap.createWindowsBlock(allocator, .{})).slice.ptr
    else
        null;

    const stdinPipe = try createChildPipe(true);
    const stdoutPipe = try createChildPipe(false);
    const stderrPipe = try createChildPipe(false);
    var startupInfo: windows.STARTUPINFOW = .{
        .cb = @sizeOf(windows.STARTUPINFOW),
        .lpReserved = null,
        .lpDesktop = null,
        .lpTitle = null,
        .dwX = 0,
        .dwY = 0,
        .dwXSize = 0,
        .dwYSize = 0,
        .dwXCountChars = 0,
        .dwYCountChars = 0,
        .dwFillAttribute = 0,
        .dwFlags = windows.STARTF_USESTDHANDLES,
        .wShowWindow = 0,
        .cbReserved2 = 0,
        .lpReserved2 = null,
        .hStdInput = stdinPipe.childEnd,
        .hStdOutput = stdoutPipe.childEnd,
        .hStdError = stderrPipe.childEnd,
    };
    var processInformation: windows.PROCESS.INFORMATION = undefined;
    const created = windows.kernel32.CreateProcessW(
        null,
        commandLine.ptr,
        null,
        null,
        .TRUE,
        .{
            .create_unicode_environment = true,
            .create_no_window = true,
        },
        environmentBlock,
        null,
        &startupInfo,
        &processInformation,
    );
    const createError = windows.GetLastError();

    // The child process has its own copies of its ends of the pipes, and stdin is closed so it reads nothing.
    windows.CloseHandle(stdinPipe.childEnd);
    windows.CloseHandle(stdoutPipe.childEnd);
    windows.CloseHandle(stderrPipe.childEnd);
    windows.CloseHandle(stdinPipe.parentEnd);
    defer windows.CloseHandle(stdoutPipe.parentEnd);
    defer windows.CloseHandle(stderrPipe.parentEnd);
    if (created == .FALSE) {
        return windows.unexpectedError(createError);
    }
    windows.CloseHandle(processInformation.hThread);
    defer windows.CloseHandle(processInformation.hProcess);

    var stderrReader: IPipeReader = .{
        .handle = stderrPipe.parentEnd,
        .output = .empty,
        .failure = null,
    };
    defer stderrReader.output.deinit(std.heap.smp_allocator);
    const stderrThread = try std.Thread.spawn(.{}, IPipeReader.run, .{&stderrReader});
    var stdoutOutput: std.ArrayList(u8) = .empty;
    defer stdoutOutput.deinit(std.heap.smp_allocator);
    const stdoutRead = readPipe(stdoutPipe.parentEnd, &stdoutOutput);
    stderrThread.join();
    try stdoutRead;
    if (stderrReader.failure) |err| {
        return err;
    }

    if (kernel32.WaitForSingleObject(processInformation.hProcess, kernel32.INFINITE) == kernel32.WAIT_FAILED) {
        return windows.unexpectedError(windows.GetLastError());
    }
    var exitCode: windows.DWORD = 0;
    if (kernel32.GetExitCodeProcess(processInformation.hProcess, &exitCode) == .FALSE) {
        return windows.unexpectedError(windows.GetLastError());
    }
    return .{
        .stdout = try allocator.dupe(u8, stdoutOutput.items),
        .stderr = try allocator.dupe(u8, stderrReader.output.items),
        .exitCode = exitCode,
    };
}

//
// Checks the result of a command run with execLogged: returns the reason it failed, or null when it did not
// (TypeScript: the optional `validate` callback, `() => Promise<string | undefined>`).
//
pub const IValidate = struct {
    // The state the check reads.
    context: *anyopaque,

    // The check.
    function: *const fn (context: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!?[]const u8,
};

//
// Runs the command and adds logging for the tool used.
//
pub fn execLogged(allocator: std.mem.Allocator, io: std.Io, tool: []const u8, command: []const u8, validate: ?IValidate) !ExecResult {
    const log = &utils.log.log;
    log.verbose(try std.fmt.allocPrint(allocator, "Executing {s} with command: \"{s}\"", .{ tool, command }));
    return execLoggedInner(allocator, io, tool, command, validate) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "Failed to execute command: {s}", .{command});
        log.exception(msg, err);
        return errors.throwError("{s}", .{msg});
    };
}

//
// The body of the try block of execLogged.
//
fn execLoggedInner(allocator: std.mem.Allocator, io: std.Io, tool: []const u8, command: []const u8, validate: ?IValidate) !ExecResult {
    const log = &utils.log.log;
    const result = try exec(allocator, io, command);
    log.tool(tool, .{ .stdout = result.stdout, .stderr = result.stderr });
    if (validate) |check| {
        const validationFailedReason = try check.function(check.context, allocator, io);
        if (validationFailedReason) |reason| {
            const msg = try std.fmt.allocPrint(allocator, "Validation failed for command: {s}\nReason: {s}", .{ command, reason });
            log.@"error"(msg);
            log.info(try std.fmt.allocPrint(allocator, "===\nCommand: {s}\nCommand stdout:\n{s}\nCommand stderr:\n{s}\n===", .{
                command,
                if (result.stdout.len > 0) result.stdout else "No output",
                if (result.stderr.len > 0) result.stderr else "No error",
            }));
            return errors.throwError("{s}", .{msg});
        }
    }
    return result;
}
