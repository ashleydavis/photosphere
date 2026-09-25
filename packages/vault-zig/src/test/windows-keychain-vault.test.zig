const std = @import("std");
const vault_zig = @import("vault-zig");
const utils = @import("utils-zig");
const windows_keychain_vault = vault_zig.windows_keychain_vault;
const WindowsKeychainVault = windows_keychain_vault.WindowsKeychainVault;
const keychain_types = vault_zig.keychain_types;
const ISecret = vault_zig.vault.ISecret;
const errors = utils.errors;

//
// In-memory map used as the fake Windows Credential Vault backend (account name to JSON payload).
// Reset by each test with resetStore.
//
var store: std.StringArrayHashMapUnmanaged([]const u8) = .empty;

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
    windows_keychain_vault.resetToolChecked();
}

//
// Restores the real spawn function (the afterEach of the TypeScript tests).
//
fn restoreSpawn() void {
    keychain_types.setSpawnFunction(null);
}

//
// Parses the single-quoted PowerShell string arguments that follow `prefix` in the script
// (unescaping ''), e.g. the three arguments of `PasswordCredential('a', 'b', 'c')`.
//
fn quotedArgsAfter(allocator: std.mem.Allocator, script: []const u8, prefix: []const u8) ![]const []const u8 {
    var quoted_args: std.ArrayList([]const u8) = .empty;
    const start = (std.mem.indexOf(u8, script, prefix) orelse return quoted_args.items) + prefix.len;
    var index = start;
    while (index < script.len and script[index] != ')') {
        if (script[index] != '\'') {
            index += 1;
            continue;
        }
        index += 1;
        var value: std.ArrayList(u8) = .empty;
        while (index < script.len) {
            if (script[index] == '\'') {
                if (index + 1 < script.len and script[index + 1] == '\'') {
                    try value.append(allocator, '\'');
                    index += 2;
                    continue;
                }
                index += 1;
                break;
            }
            try value.append(allocator, script[index]);
            index += 1;
        }
        try quoted_args.append(allocator, value.items);
    }
    return quoted_args.items;
}

//
// A fake runCommand backend that simulates the PowerShell PasswordVault calls with the in-memory store.
//
fn fakeSpawn(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdinData: ?[]const u8) anyerror!keychain_types.ISpawnResult {
    _ = io;
    _ = stdinData;
    const store_allocator = store_arena.allocator();
    if (!std.mem.eql(u8, args[0], "powershell")) {
        return errors.throwError("Unexpected command: {s}", .{args[0]});
    }

    const script = args[args.len - 1];

    if (std.mem.indexOf(u8, script, "PSVersionTable") != null) {
        return .{ .code = 0, .stdout = "5.1.0", .stderr = "" };
    }

    if (std.mem.indexOf(u8, script, "Retrieve(") != null and std.mem.indexOf(u8, script, "Write-Output $cred.Password") != null) {
        // get
        const quoted_args = try quotedArgsAfter(allocator, script, "Retrieve(");
        if (store.get(quoted_args[1])) |raw| {
            return .{ .code = 0, .stdout = raw, .stderr = "" };
        }
        return .{ .code = 1, .stdout = "", .stderr = "Object reference not set to an instance of an object." };
    }

    if (std.mem.indexOf(u8, script, "PasswordCredential(") != null) {
        // set
        const quoted_args = try quotedArgsAfter(allocator, script, "PasswordCredential(");
        try store.put(store_allocator, try store_allocator.dupe(u8, quoted_args[1]), try store_allocator.dupe(u8, quoted_args[2]));
        return .{ .code = 0, .stdout = "", .stderr = "" };
    }

    if (std.mem.indexOf(u8, script, "FindAllByResource(") != null and std.mem.indexOf(u8, script, "Write-Output $cred.UserName") != null) {
        // list
        const joined = try std.mem.join(allocator, "\n", store.keys());
        return .{ .code = 0, .stdout = joined, .stderr = "" };
    }

    return errors.throwError("Unrecognised PowerShell script: {s}", .{script});
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
    var vault = WindowsKeychainVault.init();

    try std.testing.expect((try vault.get(arena.allocator(), std.testing.io, "missing")) == null);
}

test "get: returns the secret after set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    resetStore();
    defer restoreSpawn();
    var vault = WindowsKeychainVault.init();

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
    var vault = WindowsKeychainVault.init();

    try vault.set(allocator, io, .{ .name = "s3key", .type = "s3-credentials", .value = "creds" });
    const result = (try vault.get(allocator, io, "s3key")).?;
    try std.testing.expectEqualStrings("s3key", result.name);
    try std.testing.expectEqualStrings("s3-credentials", result.type);
    try std.testing.expectEqualStrings("creds", result.value);
}

test "set: escapes single quotes in the payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    resetStore();
    defer restoreSpawn();
    var vault = WindowsKeychainVault.init();

    const secret: ISecret = .{ .name = "it's", .type = "plain", .value = "don't" };
    try vault.set(allocator, io, secret);
    try std.testing.expectEqualStrings("{\"type\":\"plain\",\"value\":\"don't\"}", store.get("psi-it's").?);
    try expectSecretEqual(secret, try vault.get(allocator, io, "it's"));
}

test "list: returns empty array when no secrets exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    resetStore();
    defer restoreSpawn();
    var vault = WindowsKeychainVault.init();

    try std.testing.expectEqual(@as(usize, 0), (try vault.list(arena.allocator(), std.testing.io)).len);
}

test "list: returns all stored secrets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    resetStore();
    defer restoreSpawn();
    var vault = WindowsKeychainVault.init();

    try vault.set(allocator, io, .{ .name = "a", .type = "plain", .value = "1" });
    try vault.set(allocator, io, .{ .name = "b", .type = "plain", .value = "2" });
    const result = try vault.list(allocator, io);
    std.mem.sort(ISecret, result, {}, secretNameLessThan);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("a", result[0].name);
    try std.testing.expectEqualStrings("b", result[1].name);
}

// Not ported: "delete" tests (WindowsKeychainVault.delete is not ported: not used by psi replicate or psi verify).

test "psi- prefix: adds psi- prefix on write and strips it on read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    resetStore();
    defer restoreSpawn();
    var vault = WindowsKeychainVault.init();

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
    var vault = WindowsKeychainVault.init();

    const secret: ISecret = .{ .name = "my:s3test01", .type = "s3-credentials", .value = "data" };
    try vault.set(allocator, io, secret);
    try expectSecretEqual(secret, try vault.get(allocator, io, "my:s3test01"));
}

test "get runs the same PowerShell script as TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    resetStore();
    defer restoreSpawn();
    keychain_types.setSpawnFunction(recordingSpawn);
    recorded_script = null;
    var vault = WindowsKeychainVault.init();

    _ = try vault.get(arena.allocator(), std.testing.io, "k");
    const expected = "[void][Windows.Security.Credentials.PasswordVault,Windows.Security.Credentials,ContentType=WindowsRuntime];" ++
        "[void][Windows.Security.Credentials.PasswordCredential,Windows.Security.Credentials,ContentType=WindowsRuntime];" ++
        "$vault = New-Object Windows.Security.Credentials.PasswordVault;\n" ++
        "try {\n" ++
        "    $cred = $vault.Retrieve('photosphere', 'psi-k');\n" ++
        "    $cred.RetrievePassword();\n" ++
        "    Write-Output $cred.Password\n" ++
        "} catch {\n" ++
        "    exit 1\n" ++
        "}";
    try std.testing.expectEqualStrings(expected, recorded_script.?);
}

//
// The script of the last PowerShell `Retrieve` seen by recordingSpawn.
//
var recorded_script: ?[]const u8 = null;

//
// A fake spawn that records the script passed to PowerShell for a get.
//
fn recordingSpawn(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdinData: ?[]const u8) anyerror!keychain_types.ISpawnResult {
    const script = args[args.len - 1];
    if (std.mem.indexOf(u8, script, "Write-Output $cred.Password") != null) {
        try std.testing.expectEqualStrings("powershell", args[0]);
        try std.testing.expectEqualStrings("-NoProfile", args[1]);
        try std.testing.expectEqualStrings("-Command", args[2]);
        recorded_script = try allocator.dupe(u8, script);
    }
    return fakeSpawn(allocator, io, args, stdinData);
}
