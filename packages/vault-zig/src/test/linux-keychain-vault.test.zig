const std = @import("std");
const vault_zig = @import("vault-zig");
const utils = @import("utils-zig");
const linux_keychain_vault = vault_zig.linux_keychain_vault;
const LinuxKeychainVault = linux_keychain_vault.LinuxKeychainVault;
const keychain_types = vault_zig.keychain_types;
const ISecret = vault_zig.vault.ISecret;
const errors = utils.errors;

//
// An entry of the fake secret-tool backend: stores type and value separately.
//
const IStoreEntry = struct {
    //
    // The photosphere secret type (e.g. "api-key").
    //
    type: []const u8,

    //
    // The raw secret value.
    //
    value: []const u8,
};

//
// In-memory map used as the fake secret-tool backend.
// Keyed by keychain account name. Reset by each test with resetStore.
//
var store: std.StringArrayHashMapUnmanaged(IStoreEntry) = .empty;

//
// Allocator for the fake store's keys and values.
//
var store_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);

//
// Empties the fake store and installs the fake spawn function (the beforeEach of the TypeScript tests).
//
fn resetStore() void {
    store = .empty;
    _ = store_arena.reset(.free_all);
    keychain_types.setSpawnFunction(fakeSpawn);
    linux_keychain_vault.resetToolChecked();
}

//
// Restores the real spawn function (the afterEach of the TypeScript tests).
//
fn restoreSpawn() void {
    keychain_types.setSpawnFunction(null);
}

//
// Returns the index of the first argument equal to `name`, or null.
//
fn argIndex(args: []const []const u8, name: []const u8) ?usize {
    for (args, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, name)) {
            return index;
        }
    }
    return null;
}

//
// A fake child_process.spawn backed by the in-memory store: handles `which`, `secret-tool lookup`,
// `secret-tool store` (value from stdin) and `secret-tool search` (attribute lines on stderr).
//
fn fakeSpawn(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdinData: ?[]const u8) anyerror!keychain_types.ISpawnResult {
    _ = io;
    const store_allocator = store_arena.allocator();
    const tool = args[0];

    if (std.mem.eql(u8, tool, "which")) {
        return .{ .code = 0, .stdout = "/usr/bin/secret-tool\n", .stderr = "" };
    }

    if (!std.mem.eql(u8, tool, "secret-tool")) {
        return errors.throwError("Unexpected command: {s}", .{tool});
    }

    const subcommand = args[1];

    if (std.mem.eql(u8, subcommand, "lookup")) {
        // args: secret-tool lookup service photosphere account <keychainName>
        const keychainName = args[5];
        if (store.get(keychainName)) |entry| {
            return .{ .code = 0, .stdout = entry.value, .stderr = "" };
        }
        return .{ .code = 1, .stdout = "", .stderr = "No such secret" };
    }

    if (std.mem.eql(u8, subcommand, "store")) {
        // Args: store --label=<name> service photosphere account <name> secrettype <type>
        var keychainName: []const u8 = "";
        for (args) |arg| {
            if (std.mem.startsWith(u8, arg, "--label=")) {
                keychainName = arg["--label=".len..];
            }
        }
        const secretType = if (argIndex(args, "secrettype")) |index| args[index + 1] else "plain";
        try store.put(store_allocator, try store_allocator.dupe(u8, keychainName), .{
            .type = try store_allocator.dupe(u8, secretType),
            .value = try store_allocator.dupe(u8, stdinData orelse ""),
        });
        return .{ .code = 0, .stdout = "", .stderr = "" };
    }

    if (std.mem.eql(u8, subcommand, "search")) {
        // Emit attribute lines via stderr for matching entries.
        // If an "account" filter arg is present, emit only that entry.
        const accountFilter = if (argIndex(args, "account")) |index| args[index + 1] else null;
        var stderr: std.ArrayList(u8) = .empty;
        var iterator = store.iterator();
        while (iterator.next()) |store_entry| {
            if (accountFilter != null and !std.mem.eql(u8, store_entry.key_ptr.*, accountFilter.?)) {
                continue;
            }
            try stderr.print(allocator, "attribute.service = photosphere\n", .{});
            try stderr.print(allocator, "attribute.account = {s}\n", .{store_entry.key_ptr.*});
            try stderr.print(allocator, "attribute.secrettype = {s}\n", .{store_entry.value_ptr.type});
            try stderr.print(allocator, "\n", .{});
        }
        return .{ .code = 0, .stdout = "", .stderr = stderr.items };
    }

    return errors.throwError("Unexpected secret-tool subcommand: {s}", .{subcommand});
}

//
// Orders secrets by name.
//
fn secretNameLessThan(context: void, left: ISecret, right: ISecret) bool {
    _ = context;
    return std.mem.order(u8, left.name, right.name) == .lt;
}

//
// Asserts that two secrets are equal (the toEqual of the TypeScript tests).
//
fn expectSecretEqual(expected: ISecret, actual: ?ISecret) !void {
    try std.testing.expect(actual != null);
    try std.testing.expectEqualStrings(expected.name, actual.?.name);
    try std.testing.expectEqualStrings(expected.type, actual.?.type);
    try std.testing.expectEqualStrings(expected.value, actual.?.value);
}

test "get: returns undefined for a missing secret" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    resetStore();
    defer restoreSpawn();
    var vault = LinuxKeychainVault.init();

    const result = try vault.get(arena.allocator(), std.testing.io, "missing");
    try std.testing.expect(result == null);
}

test "get: returns the secret after set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    resetStore();
    defer restoreSpawn();
    var vault = LinuxKeychainVault.init();

    const secret: ISecret = .{ .name = "my-key", .type = "api-key", .value = "abc123" };
    try vault.set(allocator, io, secret);
    try expectSecretEqual(secret, try vault.get(allocator, io, "my-key"));
}

test "set: stores name, type, and value correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    resetStore();
    defer restoreSpawn();
    var vault = LinuxKeychainVault.init();

    try vault.set(allocator, io, .{ .name = "s3key", .type = "s3-credentials", .value = "creds" });
    const result = (try vault.get(allocator, io, "s3key")).?;
    try std.testing.expectEqualStrings("s3key", result.name);
    try std.testing.expectEqualStrings("s3-credentials", result.type);
    try std.testing.expectEqualStrings("creds", result.value);
}

test "set: stores multiline values without truncation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    resetStore();
    defer restoreSpawn();
    var vault = LinuxKeychainVault.init();

    const multilineValue = "-----BEGIN PRIVATE KEY-----\nMIIEvgIBADANBg==\n-----END PRIVATE KEY-----";
    try vault.set(allocator, io, .{ .name = "pem-key", .type = "encryption-key", .value = multilineValue });
    const result = (try vault.get(allocator, io, "pem-key")).?;
    try std.testing.expectEqualStrings(multilineValue, result.value);
}

test "list: returns empty array when no secrets exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    resetStore();
    defer restoreSpawn();
    var vault = LinuxKeychainVault.init();

    const result = try vault.list(arena.allocator(), std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "list: returns all stored secrets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    resetStore();
    defer restoreSpawn();
    var vault = LinuxKeychainVault.init();

    try vault.set(allocator, io, .{ .name = "a", .type = "plain", .value = "1" });
    try vault.set(allocator, io, .{ .name = "b", .type = "plain", .value = "2" });
    const result = try vault.list(allocator, io);
    std.mem.sort(ISecret, result, {}, secretNameLessThan);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("a", result[0].name);
    try std.testing.expectEqualStrings("b", result[1].name);
}

test "list: returns correct types for each secret" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    resetStore();
    defer restoreSpawn();
    var vault = LinuxKeychainVault.init();

    try vault.set(allocator, io, .{ .name = "key1", .type = "api-key", .value = "v1" });
    try vault.set(allocator, io, .{ .name = "key2", .type = "encryption-key", .value = "v2" });
    const result = try vault.list(allocator, io);
    std.mem.sort(ISecret, result, {}, secretNameLessThan);
    try std.testing.expectEqualStrings("api-key", result[0].type);
    try std.testing.expectEqualStrings("encryption-key", result[1].type);
}

// Not ported: "delete" tests (LinuxKeychainVault.delete is not ported: not used by psi replicate or psi verify).

test "psi- prefix: adds psi- prefix on write and strips it on read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    resetStore();
    defer restoreSpawn();
    var vault = LinuxKeychainVault.init();

    try vault.set(allocator, io, .{ .name = "mykey", .type = "plain", .value = "v" });
    try std.testing.expect(store.contains("psi-mykey"));
    const result = (try vault.get(allocator, io, "mykey")).?;
    try std.testing.expectEqualStrings("mykey", result.name);
}

test "special characters: handles names with colons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    resetStore();
    defer restoreSpawn();
    var vault = LinuxKeychainVault.init();

    const secret: ISecret = .{ .name = "my:s3test01", .type = "s3-credentials", .value = "data" };
    try vault.set(allocator, io, secret);
    try expectSecretEqual(secret, try vault.get(allocator, io, "my:s3test01"));
}

test "parseSearchOutput keeps only psi- entries and defaults the type to plain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const output =
        \\[/org/freedesktop/secrets/collection/login/1]
        \\label = psi-one
        \\attribute.service = photosphere
        \\attribute.account = psi-one
        \\attribute.secrettype = api-key
        \\
        \\attribute.account = other
        \\attribute.secrettype = plain
        \\
        \\   attribute.account = psi-two
        \\attribute.service = photosphere
    ;
    const entries = try linux_keychain_vault.parseSearchOutput(arena.allocator(), output);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("psi-one", entries[0].account);
    try std.testing.expectEqualStrings("api-key", entries[0].secretType);
    try std.testing.expectEqualStrings("psi-two", entries[1].account);
    try std.testing.expectEqualStrings("plain", entries[1].secretType);
}

test "set passes the same secret-tool arguments as TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    resetStore();
    defer restoreSpawn();
    keychain_types.setSpawnFunction(recordingSpawn);
    recorded_args = null;
    recorded_stdin = null;
    var vault = LinuxKeychainVault.init();

    try vault.set(arena.allocator(), std.testing.io, .{ .name = "k", .type = "t", .value = "the value" });
    const expected = [_][]const u8{ "secret-tool", "store", "--label=psi-k", "service", "photosphere", "account", "psi-k", "secrettype", "t" };
    try std.testing.expectEqual(expected.len, recorded_args.?.len);
    for (expected, recorded_args.?) |expected_arg, actual_arg| {
        try std.testing.expectEqualStrings(expected_arg, actual_arg);
    }
    try std.testing.expectEqualStrings("the value", recorded_stdin.?);
}

test "set reports a failing secret-tool store with its exit code and stderr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    resetStore();
    defer restoreSpawn();
    keychain_types.setSpawnFunction(failingStoreSpawn);
    var vault = LinuxKeychainVault.init();

    try std.testing.expectError(error.Thrown, vault.set(arena.allocator(), std.testing.io, .{ .name = "k", .type = "t", .value = "v" }));
    try std.testing.expectEqualStrings("secret-tool store exited with code 2. stderr: no daemon", errors.lastErrorMessage());
}

//
// The arguments of the last `secret-tool store` seen by recordingSpawn.
//
var recorded_args: ?[]const []const u8 = null;

//
// The stdin data of the last `secret-tool store` seen by recordingSpawn.
//
var recorded_stdin: ?[]const u8 = null;

//
// A fake spawn that records the arguments and stdin of `secret-tool store`.
//
fn recordingSpawn(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdinData: ?[]const u8) anyerror!keychain_types.ISpawnResult {
    if (args.len > 1 and std.mem.eql(u8, args[1], "store")) {
        const copied_args = try allocator.alloc([]const u8, args.len);
        for (args, 0..) |arg, index| {
            copied_args[index] = try allocator.dupe(u8, arg);
        }
        recorded_args = copied_args;
        recorded_stdin = try allocator.dupe(u8, stdinData orelse "");
    }
    return fakeSpawn(allocator, io, args, stdinData);
}

//
// A fake spawn whose `secret-tool store` fails with exit code 2.
//
fn failingStoreSpawn(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdinData: ?[]const u8) anyerror!keychain_types.ISpawnResult {
    if (args.len > 1 and std.mem.eql(u8, args[1], "store")) {
        return .{ .code = 2, .stdout = "", .stderr = "no daemon\n" };
    }
    return fakeSpawn(allocator, io, args, stdinData);
}
