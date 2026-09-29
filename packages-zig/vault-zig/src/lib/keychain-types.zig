const std = @import("std");
const builtin = @import("builtin");
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
// This type has no TypeScript counterpart: it is the type of the spawn function the macOS vault tests replace
// through setSpawnFunction (the TypeScript tests use jest.spyOn on runCommand for the same reason).
//
pub const SpawnFunction = *const fn (allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdinData: ?[]const u8) anyerror!ISpawnResult;

//
// The function used by spawn in a test program (replaced by the macOS vault tests through setSpawnFunction).
// Outside a test program spawn always runs spawnChildProcess.
//
var spawn_function: SpawnFunction = spawnChildProcess;

//
// TEST-ONLY HOOK, pending the user's approval under CLAUDE.md (which bans test-only scaffolding in app code without
// it). It exists only because the macOS vault runs its tool by the absolute path /usr/bin/security (as the
// TypeScript vault does), so the macOS vault tests cannot put a stand-in in its place on PATH the way the Linux and
// Windows vault tests do, and on a Mac the real tool would touch the real keychain. It is used only by
// src/test/macos-keychain-vault.test.zig, and it is not reachable from a program that is not a test program: referring
// to it there is a compile error, and spawn ignores spawn_function there.
//
// Replaces the function used to spawn child processes. Pass null to restore the default.
//
pub fn setSpawnFunction(function: ?SpawnFunction) void {
    if (!builtin.is_test) {
        @compileError("setSpawnFunction is only for the macOS vault tests");
    }
    spawn_function = function orelse spawnChildProcess;
}

//
// Spawns a child process (the equivalent of `spawn(cmd, cmdArgs, { stdio: ["pipe", "pipe", "pipe"] })`)
// and waits for it to exit. `args[0]` is the program. When stdinData is set it is written to stdin;
// stdin is then closed.
//
pub fn spawn(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdinData: ?[]const u8) anyerror!ISpawnResult {
    if (builtin.is_test) {
        return spawn_function(allocator, io, args, stdinData);
    }
    return spawnChildProcess(allocator, io, args, stdinData);
}

//
// TODO: closes the child's stdin, where the TypeScript runCommand leaves the pipe open.
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
        // TypeScript attaches no error listener to child.stdin, so a failed write (EPIPE when the child exits
        // without reading its input) is not ignored there either: it fails the command.
        try child.stdin.?.writeStreamingAll(io, data);
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
// Spawns a child process with the given arguments, resolves with trimmed
// stdout on success, or rejects with an error including stderr on non-zero exit.
//
pub fn runCommand(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) ![]const u8 {
    const result = try spawn(allocator, io, args, null);
    const stdout = utils.js_string.trim(result.stdout);
    const stderr = utils.js_string.trim(result.stderr);
    if (result.code) |code| {
        if (code == 0) {
            return stdout;
        }
    }
    const joined_args = try std.mem.join(allocator, " ", args);
    const code_text = if (result.code) |code| try std.fmt.allocPrint(allocator, "{d}", .{code}) else "null";
    return errors.throwError("Command \"{s}\" exited with code {s}. stderr: {s}", .{ joined_args, code_text, stderr });
}
