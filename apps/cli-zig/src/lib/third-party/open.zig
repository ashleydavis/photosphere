//
// Port of the parts of the third-party `open` package (v10) used by `psi bug`: `open(target)` with no options
// (this file has no TypeScript counterpart in the repo). It starts the platform's opener for the target and
// returns without waiting for it (`wait: false`).
//
// Not ported: the `app` and `wait` options, the default-browser lookup, and the WSL branch (under WSL the
// package runs the Windows PowerShell from the WSL mount; here Linux always runs xdg-open).
// The package's own bundled `xdg-open` is not ported: the compiled TypeScript CLI cannot reach it either
// (it is not inside the compiled binary), so it runs the system `xdg-open`, as this port does.
//

const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const log = &utils.log.log;
const getEnv = node_utils.process_env.getEnv;
const windows = std.os.windows;

//
// The program `open` runs for a target, with its arguments.
//
pub const IOpenCommand = struct {
    // The program to run.
    command: []const u8,

    // Its arguments.
    cliArguments: []const []const u8,
};

//
// The path of Windows PowerShell (`powerShellPath()` of the `wsl-utils` package, outside WSL).
//
pub fn powerShellPath(allocator: std.mem.Allocator) ![]const u8 {
    const systemRoot = nonEmptyEnv("SYSTEMROOT") orelse nonEmptyEnv("windir") orelse "C:\\Windows";
    return std.fmt.allocPrint(allocator, "{s}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", .{systemRoot});
}

//
// An environment variable, or null when it is not set or empty (`process.env.NAME || ...`).
//
fn nonEmptyEnv(name: []const u8) ?[]const u8 {
    const value = getEnv(name) orelse return null;
    if (value.len == 0) {
        return null;
    }
    return value;
}

//
// Works out the program and arguments that open the target on this platform: `open` on macOS, PowerShell's
// `Start` on Windows (as a base64 UTF-16LE -EncodedCommand) and `xdg-open` everywhere else.
//
pub fn openCommand(allocator: std.mem.Allocator, target: []const u8) !IOpenCommand {
    if (builtin.os.tag == .macos) {
        const cliArguments = try allocator.alloc([]const u8, 1);
        cliArguments[0] = target;
        return .{ .command = "open", .cliArguments = cliArguments };
    }
    if (builtin.os.tag == .windows) {
        const encodedArguments = try std.fmt.allocPrint(allocator, "Start \"{s}\"", .{target});
        const utf16 = try std.unicode.utf8ToUtf16LeAlloc(allocator, encodedArguments);
        const utf16Bytes = std.mem.sliceAsBytes(utf16);
        const encoder = std.base64.standard.Encoder;
        const encodedCommand = try allocator.alloc(u8, encoder.calcSize(utf16Bytes.len));
        _ = encoder.encode(encodedCommand, utf16Bytes);
        const cliArguments = try allocator.alloc([]const u8, 6);
        cliArguments[0] = "-NoProfile";
        cliArguments[1] = "-NonInteractive";
        cliArguments[2] = "-ExecutionPolicy";
        cliArguments[3] = "Bypass";
        cliArguments[4] = "-EncodedCommand";
        cliArguments[5] = encodedCommand;
        return .{ .command = try powerShellPath(allocator), .cliArguments = cliArguments };
    }
    const cliArguments = try allocator.alloc([]const u8, 1);
    cliArguments[0] = target;
    return .{ .command = "xdg-open", .cliArguments = cliArguments };
}

//
// Opens the target (a URL here) with the platform's opener and returns without waiting for it. Outside Windows the
// opener runs detached in a process group of its own with its output ignored, so it does not hold the CLI's
// terminal (the package's `stdio: 'ignore', detached: true`). On Windows the package gives `spawn` no options but
// `windowsVerbatimArguments`, so PowerShell is started attached, with pipes for its standard streams (see
// `startAttachedToThisProcess`). Fails only when the command cannot be built.
//
pub fn open(allocator: std.mem.Allocator, io: std.Io, target: []const u8) !void {
    const openerCommand = try openCommand(allocator, target);
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, openerCommand.command);
    try argv.appendSlice(allocator, openerCommand.cliArguments);
    var spawnOptions: std.process.SpawnOptions = .{
        .argv = argv.items,
        .environ_map = node_utils.process_env.getEnvironMap(),
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    };
    if (builtin.os.tag == .windows) {
        spawnOptions.stdin = .pipe;
        spawnOptions.stdout = .pipe;
        spawnOptions.stderr = .pipe;
    }
    else {
        spawnOptions.pgid = 0;
    }
    // An opener that cannot be started (not installed, not executable) is not a failure of `open`: the package's
    // `childProcess.spawn` reports it later, as an 'error' event on the child that nothing listens for, so its
    // promise has already resolved. The compiled TypeScript CLI says "Bug report opened in browser!" on a machine
    // without xdg-open, and so does this. The error is still logged, with --verbose, rather than lost.
    const opener = std.process.spawn(io, spawnOptions) catch |err| {
        log.verbose(try std.fmt.allocPrint(allocator, "Failed to start {s}: {s}", .{ openerCommand.command, @errorName(err) }));
        return;
    };

    if (builtin.os.tag == .windows) {
        _ = startAttachedToThisProcess(allocator, opener.id.?);
    }

    // `subprocess.unref()`: the opener is not waited for.
}

//
// Windows: puts the opener in a job object that kills it when this process exits, as libuv (under Bun) does for
// every child that is not `detached`: it assigns it to a job with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, whose handle
// closes when the process exits. The job handle is never closed here, so it lives until the CLI exits. Like libuv,
// a process that cannot be assigned (this process is in a job that forbids it) is left to run, with the failure
// logged with --verbose. Returns the job the process was put in, or null when it was not.
//
// TODO: the TypeScript `psi bug` (apps/cli/src/cmd/bug.ts) exits straight after `open()`, and the `open` package
// starts PowerShell on Windows without `detached`, so PowerShell is killed as psi exits, usually before it has
// started the browser: on Windows `psi bug` opens no browser. This mirrors that TypeScript bug on purpose, to stay
// faithful to it. Fix it in both (start the opener detached, or wait for it) once the TypeScript is fixed.
//
pub fn startAttachedToThisProcess(allocator: std.mem.Allocator, process: windows.HANDLE) ?windows.HANDLE {
    const job = killOnCloseJob() orelse {
        log.verbose(std.fmt.allocPrint(allocator, "Failed to create the job object of the opener: error {d}", .{@intFromEnum(windows.GetLastError())}) catch return null);
        return null;
    };
    if (!AssignProcessToJobObject(job, process).toBool()) {
        log.verbose(std.fmt.allocPrint(allocator, "Failed to put the opener in its job object: error {d}", .{@intFromEnum(windows.GetLastError())}) catch return null);
        return null;
    }
    return job;
}

//
// Windows: creates a job object with the limits libuv gives the job of a child that is not detached
// (uv__init_global_job_handle): its processes are killed when its last handle closes, may break away from it, and
// die on an unhandled exception. Null when the job cannot be created or its limits set.
//
fn killOnCloseJob() ?windows.HANDLE {
    const job = CreateJobObjectW(null, null) orelse return null;
    var limits = std.mem.zeroes(JobObjectExtendedLimitInformation);
    limits.BasicLimitInformation.LimitFlags = job_object_limit_breakaway_ok | job_object_limit_silent_breakaway_ok | job_object_limit_die_on_unhandled_exception | job_object_limit_kill_on_job_close;
    if (!SetInformationJobObject(job, job_object_extended_limit_information, &limits, @sizeOf(JobObjectExtendedLimitInformation)).toBool()) {
        windows.CloseHandle(job);
        return null;
    }
    return job;
}

//
// JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION: a process of the job that has an unhandled exception ends at once.
//
const job_object_limit_die_on_unhandled_exception: windows.DWORD = 0x400;

//
// JOB_OBJECT_LIMIT_BREAKAWAY_OK: a process of the job may start a child outside the job.
//
const job_object_limit_breakaway_ok: windows.DWORD = 0x800;

//
// JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK: the children of the job's processes are not put in the job.
//
const job_object_limit_silent_breakaway_ok: windows.DWORD = 0x1000;

//
// JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: the job's processes are killed when its last handle closes.
//
const job_object_limit_kill_on_job_close: windows.DWORD = 0x2000;

//
// JobObjectExtendedLimitInformation, the JOBOBJECTINFOCLASS of JobObjectExtendedLimitInformation.
//
const job_object_extended_limit_information: c_int = 9;

//
// JOBOBJECT_BASIC_LIMIT_INFORMATION: the basic limits of a job; only LimitFlags is set here.
//
const JobObjectBasicLimitInformation = extern struct {
    // The user-mode time limit of each process.
    PerProcessUserTimeLimit: i64,

    // The user-mode time limit of the job.
    PerJobUserTimeLimit: i64,

    // The JOB_OBJECT_LIMIT_ flags in force.
    LimitFlags: windows.DWORD,

    // The minimum working set of each process.
    MinimumWorkingSetSize: usize,

    // The maximum working set of each process.
    MaximumWorkingSetSize: usize,

    // The most processes the job may hold at once.
    ActiveProcessLimit: windows.DWORD,

    // The processors the job's processes may run on.
    Affinity: usize,

    // The priority class of the job's processes.
    PriorityClass: windows.DWORD,

    // The scheduling class of the job's processes.
    SchedulingClass: windows.DWORD,
};

//
// IO_COUNTERS: the I/O the job's processes have done (read back only; unused here).
//
const IoCounters = extern struct {
    // The number of read operations.
    ReadOperationCount: u64,

    // The number of write operations.
    WriteOperationCount: u64,

    // The number of other operations.
    OtherOperationCount: u64,

    // The number of bytes read.
    ReadTransferCount: u64,

    // The number of bytes written.
    WriteTransferCount: u64,

    // The number of bytes of other operations.
    OtherTransferCount: u64,
};

//
// JOBOBJECT_EXTENDED_LIMIT_INFORMATION: the limits of a job, set with SetInformationJobObject.
//
const JobObjectExtendedLimitInformation = extern struct {
    // The basic limits, holding the JOB_OBJECT_LIMIT_ flags.
    BasicLimitInformation: JobObjectBasicLimitInformation,

    // The I/O counters (ignored when setting).
    IoInfo: IoCounters,

    // The committed memory limit of each process.
    ProcessMemoryLimit: usize,

    // The committed memory limit of the job.
    JobMemoryLimit: usize,

    // The most memory any process of the job has committed.
    PeakProcessMemoryUsed: usize,

    // The most memory the job has committed.
    PeakJobMemoryUsed: usize,
};

//
// Creates a job object (kernel32).
//
extern "kernel32" fn CreateJobObjectW(lpJobAttributes: ?*anyopaque, lpName: ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;

//
// Sets the limits of a job object (kernel32).
//
extern "kernel32" fn SetInformationJobObject(hJob: windows.HANDLE, JobObjectInformationClass: c_int, lpJobObjectInformation: *anyopaque, cbJobObjectInformationLength: windows.DWORD) callconv(.winapi) windows.BOOL;

//
// Puts a process in a job object (kernel32).
//
extern "kernel32" fn AssignProcessToJobObject(hJob: windows.HANDLE, hProcess: windows.HANDLE) callconv(.winapi) windows.BOOL;
