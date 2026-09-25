const std = @import("std");
const builtin = @import("builtin");
const vault_zig = @import("vault-zig");
const utils = @import("utils-zig");
const keychain_types = vault_zig.keychain_types;
const errors = utils.errors;

test "KEYCHAIN_PREFIX is psi-" {
    try std.testing.expectEqualStrings("psi-", keychain_types.KEYCHAIN_PREFIX);
}

test "toKeychainName prepends the psi- prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("psi-my:key", try keychain_types.toKeychainName(arena.allocator(), "my:key"));
}

test "fromKeychainName strips the psi- prefix" {
    try std.testing.expectEqualStrings("my:key", keychain_types.fromKeychainName("psi-my:key"));
    try std.testing.expectEqualStrings("", keychain_types.fromKeychainName("ps"));
}

test "runCommand resolves with trimmed stdout" {
    if (builtin.os.tag == .windows) {
        return;
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const stdout = try keychain_types.runCommand(arena.allocator(), std.testing.io, &.{ "sh", "-c", "echo '  hello world  '" });
    try std.testing.expectEqualStrings("hello world", stdout);
}

test "runCommand rejects with the exit code and trimmed stderr" {
    if (builtin.os.tag == .windows) {
        return;
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = keychain_types.runCommand(arena.allocator(), std.testing.io, &.{ "sh", "-c", "echo oops >&2; exit 3" });
    try std.testing.expectError(error.Thrown, result);
    try std.testing.expectEqualStrings("Command \"sh -c echo oops >&2; exit 3\" exited with code 3. stderr: oops", errors.lastErrorMessage());
}

test "runCommand rejects when the program does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = keychain_types.runCommand(arena.allocator(), std.testing.io, &.{"photosphere-no-such-program"});
    try std.testing.expectError(error.Thrown, result);
    try std.testing.expectEqualStrings("spawn photosphere-no-such-program ENOENT", errors.lastErrorMessage());
}

test "spawn pipes stdin to the child process" {
    if (builtin.os.tag == .windows) {
        return;
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try keychain_types.spawn(arena.allocator(), std.testing.io, &.{"cat"}, "line one\nline two");
    try std.testing.expectEqual(@as(?u8, 0), result.code);
    try std.testing.expectEqualStrings("line one\nline two", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

//
// A fake spawn function that always succeeds with a fixed stdout.
//
fn fixedSpawn(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdinData: ?[]const u8) anyerror!keychain_types.ISpawnResult {
    _ = allocator;
    _ = io;
    _ = args;
    _ = stdinData;
    return .{ .code = 0, .stdout = "fake\n", .stderr = "" };
}

test "setSpawnFunction replaces and restores the spawn function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    keychain_types.setSpawnFunction(fixedSpawn);
    defer keychain_types.setSpawnFunction(null);
    try std.testing.expectEqualStrings("fake", try keychain_types.runCommand(arena.allocator(), std.testing.io, &.{"anything"}));
    keychain_types.setSpawnFunction(null);
    try std.testing.expectError(error.Thrown, keychain_types.runCommand(arena.allocator(), std.testing.io, &.{"photosphere-no-such-program"}));
}
