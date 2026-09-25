const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const errors = utils.errors;
const process_env = node_utils.process_env;

//
// JSON envelope stored as the keychain "password" value.
// Wraps the secret type and value so both can be retrieved from a single
// keychain entry.
//
pub const IKeychainPayload = struct {
    //
    // Caller-defined category string for the secret (e.g. "api-key").
    //
    type: []const u8,

    //
    // The secret value as a plain string.
    //
    value: []const u8,
};

//
// Prefix applied to every secret name stored in the OS keychain.
// Makes photosphere entries clearly identifiable in the keychain UI.
//
pub const KEYCHAIN_PREFIX = "psi-";

//
// Returns the keychain account name for a given user-facing secret name
// by prepending the psi- prefix.
//
pub fn toKeychainName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.mem.concat(allocator, u8, &.{ KEYCHAIN_PREFIX, name });
}

//
// Strips the psi- prefix from a keychain account name to obtain the
// user-facing secret name.
//
pub fn fromKeychainName(keychainName: []const u8) []const u8 {
    if (keychainName.len < KEYCHAIN_PREFIX.len) {
        return "";
    }
    return keychainName[KEYCHAIN_PREFIX.len..];
}

//
// The outcome of a child process that ran to completion: what the TypeScript code collects from
// the "data" events of stdout and stderr and the "close" event of a spawned process.
// This type has no TypeScript counterpart.
//
pub const ISpawnResult = struct {
    // The exit code, or null when the process was terminated by a signal (Node passes null to "close").
    code: ?u8,

    // Everything the process wrote to stdout.
    stdout: []const u8,

    // Everything the process wrote to stderr.
    stderr: []const u8,
};

//
// A function that spawns a child process with piped stdio, writes `stdinData` (if any) to its stdin,
// closes stdin and waits for the process to exit.
// This type has no TypeScript counterpart: it stands in for child_process.spawn so that tests can replace
// it (the TypeScript tests use jest.spyOn on runCommand and child_process.spawn).
//
pub const SpawnFunction = *const fn (allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdinData: ?[]const u8) anyerror!ISpawnResult;

//
// The function used by spawn (replaced by tests through setSpawnFunction).
//
var spawn_function: SpawnFunction = spawnChildProcess;

//
// Replaces the function used to spawn child processes (tests only). Pass null to restore the default.
//
pub fn setSpawnFunction(function: ?SpawnFunction) void {
    spawn_function = function orelse spawnChildProcess;
}

//
// Spawns a child process (the equivalent of `spawn(cmd, cmdArgs, { stdio: ["pipe", "pipe", "pipe"] })`)
// and waits for it to exit. `args[0]` is the program. When stdinData is set it is written to stdin;
// stdin is then closed.
//
pub fn spawn(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdinData: ?[]const u8) anyerror!ISpawnResult {
    return spawn_function(allocator, io, args, stdinData);
}

//
// The default SpawnFunction: runs the process with std.process.spawn, inheriting `process.env`.
// A program that cannot be found fails like Node's spawn ("spawn <cmd> ENOENT").
//
fn spawnChildProcess(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdinData: ?[]const u8) anyerror!ISpawnResult {
    var child = std.process.spawn(io, .{
        .argv = args,
        .environ_map = process_env.getEnvironMap(),
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        if (err == error.FileNotFound) {
            return errors.throwError("spawn {s} ENOENT", .{args[0]});
        }
        return err;
    };
    defer child.kill(io);

    if (stdinData) |data| {
        // Like Node, a child that exits without reading its input does not fail the command.
        child.stdin.?.writeStreamingAll(io, data) catch {};
    }
    child.stdin.?.close(io);
    child.stdin = null;

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    while (true) {
        multi_reader.fill(64, .none) catch |err| {
            if (err == error.EndOfStream) {
                break;
            }
            return err;
        };
    }
    try multi_reader.checkAnyError();

    const term = try child.wait(io);
    const stdout = try multi_reader.toOwnedSlice(0);
    const stderr = try multi_reader.toOwnedSlice(1);
    const code: ?u8 = switch (term) {
        .exited => |exit_code| exit_code,
        else => null,
    };
    return .{ .code = code, .stdout = stdout, .stderr = stderr };
}

//
// The whitespace removed by JavaScript's String.prototype.trim (the ASCII subset).
//
pub const whitespace = " \t\n\r\x0b\x0c";

//
// Spawns a child process with the given arguments, resolves with trimmed
// stdout on success, or rejects with an error including stderr on non-zero exit.
//
pub fn runCommand(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) ![]const u8 {
    const result = try spawn(allocator, io, args, null);
    const stdout = std.mem.trim(u8, result.stdout, whitespace);
    const stderr = std.mem.trim(u8, result.stderr, whitespace);
    if (result.code) |code| {
        if (code == 0) {
            return stdout;
        }
    }
    const joined_args = try std.mem.join(allocator, " ", args);
    const code_text = if (result.code) |code| try std.fmt.allocPrint(allocator, "{d}", .{code}) else "null";
    return errors.throwError("Command \"{s}\" exited with code {s}. stderr: {s}", .{ joined_args, code_text, stderr });
}
