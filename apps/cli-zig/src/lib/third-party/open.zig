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
const node_utils = @import("node-utils-zig");
const getEnv = node_utils.process_env.getEnv;

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
// Opens the target (a URL here) with the platform's opener and returns without waiting for it. The opener runs
// detached in a process group of its own with its output ignored, so it does not hold the CLI's terminal (the
// package's `stdio: 'ignore', detached: true`). Fails when the opener cannot be started.
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
    if (builtin.os.tag != .windows) {
        spawnOptions.pgid = 0;
    }
    _ = try std.process.spawn(io, spawnOptions);

    // `subprocess.unref()`: the opener is not waited for.
}
