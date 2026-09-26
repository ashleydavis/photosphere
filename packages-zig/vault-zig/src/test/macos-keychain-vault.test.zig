const std = @import("std");
const vault_zig = @import("vault-zig");
const utils = @import("utils-zig");
const macos_keychain_vault = vault_zig.macos_keychain_vault;
const MacOSKeychainVault = macos_keychain_vault.MacOSKeychainVault;
const keychain_types = vault_zig.keychain_types;
const ISecret = vault_zig.vault.ISecret;
const errors = utils.errors;

//
// In-memory map used as the fake macOS security-tool backend (account name to JSON payload).
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
}

//
// Restores the real spawn function (the afterEach of the TypeScript tests).
//
fn restoreSpawn() void {
    keychain_types.setSpawnFunction(null);
}

//
// Returns the argument after the first argument equal to `name`.
//
fn argAfter(args: []const []const u8, name: []const u8) []const u8 {
    for (args, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, name)) {
            return args[index + 1];
        }
    }
    return "";
}

//
// A fake runCommand backend for /usr/bin/security backed by the in-memory store.
// The dump-keychain subcommand emits output in the real security(1) format so
// that parseKeychainDump() exercises the same code path as production.
//
fn fakeSpawn(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdinData: ?[]const u8) anyerror!keychain_types.ISpawnResult {
    _ = io;
    _ = stdinData;
    const store_allocator = store_arena.allocator();
    if (!std.mem.eql(u8, args[0], "/usr/bin/security")) {
        return errors.throwError("Unexpected command: {s}", .{args[0]});
    }

    const subcommand = args[1];

    if (std.mem.eql(u8, subcommand, "version")) {
        return .{ .code = 0, .stdout = "security-2375 (SecureTransport-59754.140.13)", .stderr = "" };
    }

    if (std.mem.eql(u8, subcommand, "add-generic-password")) {
        // args: security add-generic-password -U -s photosphere -a <name> -w <json>
        const keychainName = argAfter(args, "-a");
        const json = argAfter(args, "-w");
        try store.put(store_allocator, try store_allocator.dupe(u8, keychainName), try store_allocator.dupe(u8, json));
        return .{ .code = 0, .stdout = "", .stderr = "" };
    }

    if (std.mem.eql(u8, subcommand, "find-generic-password")) {
        // args: security find-generic-password -s photosphere -a <name> -w
        const keychainName = argAfter(args, "-a");
        if (store.get(keychainName)) |raw| {
            return .{ .code = 0, .stdout = raw, .stderr = "" };
        }
        return .{ .code = 44, .stdout = "", .stderr = "SecKeychainSearchCopyNext: The specified item could not be found in the keychain." };
    }

    if (std.mem.eql(u8, subcommand, "dump-keychain")) {
        // Emit one block per store entry in real security dump-keychain format.
        var output: std.ArrayList(u8) = .empty;
        for (store.keys(), 0..) |keychainName, index| {
            if (index > 0) {
                try output.append(allocator, '\n');
            }
            try output.print(allocator, "keychain: \"/Users/test/Library/Keychains/login.keychain-db\"\n" ++
                "version: 512\n" ++
                "class: \"genp\"\n" ++
                "attributes:\n" ++
                "    \"acct\"<blob>=\"{s}\"\n" ++
                "    \"svce\"<blob>=\"photosphere\"\n", .{keychainName});
        }
        return .{ .code = 0, .stdout = output.items, .stderr = "" };
    }

    return errors.throwError("Unexpected security subcommand: {s}", .{subcommand});
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
    var vault = MacOSKeychainVault.init();

    try std.testing.expect((try vault.get(arena.allocator(), std.testing.io, "missing")) == null);
}

test "get: returns the secret after set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    resetStore();
    defer restoreSpawn();
    var vault = MacOSKeychainVault.init();

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
    var vault = MacOSKeychainVault.init();

    try vault.set(allocator, io, .{ .name = "s3key", .type = "s3-credentials", .value = "creds" });
    const result = (try vault.get(allocator, io, "s3key")).?;
    try std.testing.expectEqualStrings("s3key", result.name);
    try std.testing.expectEqualStrings("s3-credentials", result.type);
    try std.testing.expectEqualStrings("creds", result.value);
}

test "set: does not duplicate entry on overwrite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    resetStore();
    defer restoreSpawn();
    var vault = MacOSKeychainVault.init();

    try vault.set(allocator, io, .{ .name = "dup", .type = "plain", .value = "v1" });
    try vault.set(allocator, io, .{ .name = "dup", .type = "plain", .value = "v2" });
    const secrets = try vault.list(allocator, io);
    var dup_count: usize = 0;
    for (secrets) |secret| {
        if (std.mem.eql(u8, secret.name, "dup")) {
            dup_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), dup_count);
}

test "set: stores the payload as compact JSON like JSON.stringify" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    resetStore();
    defer restoreSpawn();
    var vault = MacOSKeychainVault.init();

    try vault.set(arena.allocator(), std.testing.io, .{ .name = "k", .type = "plain", .value = "a \"quoted\"\nline" });
    try std.testing.expectEqualStrings("{\"type\":\"plain\",\"value\":\"a \\\"quoted\\\"\\nline\"}", store.get("psi-k").?);
}

test "list: returns empty array when no secrets exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    resetStore();
    defer restoreSpawn();
    var vault = MacOSKeychainVault.init();

    try std.testing.expectEqual(@as(usize, 0), (try vault.list(arena.allocator(), std.testing.io)).len);
}

test "list: returns all stored secrets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    resetStore();
    defer restoreSpawn();
    var vault = MacOSKeychainVault.init();

    try vault.set(allocator, io, .{ .name = "a", .type = "plain", .value = "1" });
    try vault.set(allocator, io, .{ .name = "b", .type = "plain", .value = "2" });
    const result = try vault.list(allocator, io);
    std.mem.sort(ISecret, result, {}, secretNameLessThan);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("a", result[0].name);
    try std.testing.expectEqualStrings("b", result[1].name);
}

test "list: excludes entries from other services" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    resetStore();
    defer restoreSpawn();
    var vault = MacOSKeychainVault.init();

    // Inject a non-photosphere entry directly into the raw store so dump-keychain would
    // surface it; list() must ignore it.
    try store.put(store_arena.allocator(), "other-service-key", "{\"type\":\"plain\",\"value\":\"x\"}");
    try std.testing.expectEqual(@as(usize, 0), (try vault.list(arena.allocator(), std.testing.io)).len);
}

// Not ported: "delete" tests (MacOSKeychainVault.delete is not ported: not used by psi replicate or psi verify).

test "psi- prefix: adds psi- prefix on write and strips it on read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    resetStore();
    defer restoreSpawn();
    var vault = MacOSKeychainVault.init();

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
    var vault = MacOSKeychainVault.init();

    const secret: ISecret = .{ .name = "my:s3test01", .type = "s3-credentials", .value = "data" };
    try vault.set(allocator, io, secret);
    try expectSecretEqual(secret, try vault.get(allocator, io, "my:s3test01"));
}

test "special characters: handles names with slashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    resetStore();
    defer restoreSpawn();
    var vault = MacOSKeychainVault.init();

    const secret: ISecret = .{ .name = "cli/key/one", .type = "plain", .value = "x" };
    try vault.set(allocator, io, secret);
    try expectSecretEqual(secret, try vault.get(allocator, io, "cli/key/one"));
}

test "checkPrereqs reports a missing security tool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    keychain_types.setSpawnFunction(missingToolSpawn);
    defer restoreSpawn();
    var vault = MacOSKeychainVault.init();

    const result = vault.checkPrereqs(arena.allocator(), std.testing.io);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("macOS Keychain tool not found at /usr/bin/security. This tool is bundled with macOS and should always be present.", result.message.?);

    // get() throws the prerequisite message on first use.
    try std.testing.expectError(error.Thrown, vault.get(arena.allocator(), std.testing.io, "any"));
    try std.testing.expectEqualStrings(result.message.?, errors.lastErrorMessage());
}

test "parseKeychainDump matches the service and psi- account of each block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const output =
        \\keychain: "/login.keychain-db"
        \\attributes:
        \\    "acct"<blob>="psi-one"
        \\    "svce"<blob>="photosphere"
        \\keychain: "/login.keychain-db"
        \\attributes:
        \\    "acct"<blob>="psi-two"
        \\    "svce"<blob>="other"
        \\keychain: "/login.keychain-db"
        \\attributes:
        \\    "acct"<blob>=""
        \\    "acct"<blob>="psi-three"
        \\    "svce"<blob>="photosphere"
        \\keychain: "/login.keychain-db"
        \\    "acct"<blob>="not-psi"
        \\    "svce"<blob>="photosphere"
    ;
    const names = try macos_keychain_vault.parseKeychainDump(arena.allocator(), output);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("psi-one", names[0]);
    try std.testing.expectEqualStrings("psi-three", names[1]);
}

//
// A fake spawn where /usr/bin/security does not exist.
//
fn missingToolSpawn(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, stdinData: ?[]const u8) anyerror!keychain_types.ISpawnResult {
    _ = allocator;
    _ = io;
    _ = stdinData;
    return errors.throwError("spawn {s} ENOENT", .{args[0]});
}
