const std = @import("std");
const builtin = @import("builtin");
const vault_zig = @import("vault-zig");
const utils = @import("utils-zig");
const linux_keychain_vault = vault_zig.linux_keychain_vault;
const LinuxKeychainVault = linux_keychain_vault.LinuxKeychainVault;
const IStandIns = @import("stand-ins.zig").IStandIns;
const ISecret = vault_zig.vault.ISecret;
const errors = utils.errors;

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
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    var vault = LinuxKeychainVault.init();

    const result = try vault.get(arena.allocator(), std.testing.io, "missing");
    try std.testing.expect(result == null);
}

test "get: returns the secret after set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
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
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
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
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    var vault = LinuxKeychainVault.init();

    const multilineValue = "-----BEGIN PRIVATE KEY-----\nMIIEvgIBADANBg==\n-----END PRIVATE KEY-----";
    try vault.set(allocator, io, .{ .name = "pem-key", .type = "encryption-key", .value = multilineValue });
    const result = (try vault.get(allocator, io, "pem-key")).?;
    try std.testing.expectEqualStrings(multilineValue, result.value);
}

test "list: returns empty array when no secrets exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    var vault = LinuxKeychainVault.init();

    const result = try vault.list(arena.allocator(), std.testing.io);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "list: returns all stored secrets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
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
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    var vault = LinuxKeychainVault.init();

    try vault.set(allocator, io, .{ .name = "key1", .type = "api-key", .value = "v1" });
    try vault.set(allocator, io, .{ .name = "key2", .type = "encryption-key", .value = "v2" });
    const result = try vault.list(allocator, io);
    std.mem.sort(ISecret, result, {}, secretNameLessThan);
    try std.testing.expectEqualStrings("api-key", result[0].type);
    try std.testing.expectEqualStrings("encryption-key", result[1].type);
}

test "delete: removes the secret (subsequent get returns undefined)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    var vault = LinuxKeychainVault.init();

    try vault.set(allocator, io, .{ .name = "temp", .type = "plain", .value = "val" });
    try vault.delete(allocator, io, "temp");
    const result = try vault.get(allocator, io, "temp");
    try std.testing.expect(result == null);
}

test "delete: does nothing when the secret does not exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    var vault = LinuxKeychainVault.init();

    try vault.delete(arena.allocator(), std.testing.io, "nonexistent");
}

test "psi- prefix: adds psi- prefix on write and strips it on read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    var vault = LinuxKeychainVault.init();

    try vault.set(allocator, io, .{ .name = "mykey", .type = "plain", .value = "v" });
    try std.testing.expect((try standIns.readStore()).contains("psi-mykey"));
    const result = (try vault.get(allocator, io, "mykey")).?;
    try std.testing.expectEqualStrings("mykey", result.name);
}

test "special characters: handles names with colons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
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
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    var vault = LinuxKeychainVault.init();

    try vault.set(arena.allocator(), std.testing.io, .{ .name = "k", .type = "t", .value = "the value" });
    const expected = [_][]const u8{ "secret-tool", "store", "--label=psi-k", "service", "photosphere", "account", "psi-k", "secrettype", "t" };
    const recordedArgs = (try standIns.readRecordedArgs("last-store-args")).?;
    try std.testing.expectEqual(expected.len, recordedArgs.len);
    for (expected, recordedArgs) |expected_arg, actual_arg| {
        try std.testing.expectEqualStrings(expected_arg, actual_arg);
    }
    try std.testing.expectEqualStrings("the value", (try standIns.readStateFile("last-store-stdin")).?);
}

test "set reports a failing secret-tool store with its exit code and stderr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    try standIns.setMode("failing-store");
    var vault = LinuxKeychainVault.init();

    try std.testing.expectError(error.Thrown, vault.set(arena.allocator(), std.testing.io, .{ .name = "k", .type = "t", .value = "v" }));
    try std.testing.expectEqualStrings("secret-tool store exited with code 2. stderr: no daemon", errors.lastErrorMessage());
}

test "the IVault interface reaches every operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    var linuxVault = LinuxKeychainVault.init();
    const vault = linuxVault.vault();

    try vault.set(allocator, std.testing.io, .{ .name = "k", .type = "api-key", .value = "v" });
    try expectSecretEqual(.{ .name = "k", .type = "api-key", .value = "v" }, try vault.get(allocator, std.testing.io, "k"));
    try std.testing.expectEqual(@as(usize, 1), (try vault.list(allocator, std.testing.io)).len);
    try vault.delete(allocator, std.testing.io, "k");
    try std.testing.expect((try vault.get(allocator, std.testing.io, "k")) == null);
}

test "get throws when secret-tool search fails, with its exit code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    var vault = LinuxKeychainVault.init();
    try vault.set(allocator, std.testing.io, .{ .name = "k", .type = "t", .value = "v" });

    try standIns.setMode("failing-search:3");
    try std.testing.expectError(error.Thrown, vault.get(allocator, std.testing.io, "k"));
    try std.testing.expectEqualStrings("secret-tool search exited with code 3", errors.lastErrorMessage());

    // A search killed by a signal has no exit code. A Windows process always has one, so this part runs on the
    // other platforms only.
    if (builtin.os.tag != .windows) {
        try standIns.setMode("failing-search:signal");
        try std.testing.expectError(error.Thrown, vault.get(allocator, std.testing.io, "k"));
        try std.testing.expectEqualStrings("secret-tool search exited with code null", errors.lastErrorMessage());
    }
}

test "list: returns nothing when secret-tool search fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    var vault = LinuxKeychainVault.init();
    try vault.set(allocator, std.testing.io, .{ .name = "k", .type = "t", .value = "v" });
    try standIns.setMode("failing-search:3");
    try std.testing.expectEqual(@as(usize, 0), (try vault.list(allocator, std.testing.io)).len);

    // A search killed by a signal has no exit code. A Windows process always has one, so this part runs on the
    // other platforms only.
    if (builtin.os.tag != .windows) {
        try standIns.setMode("failing-search:signal");
        try std.testing.expectEqual(@as(usize, 0), (try vault.list(allocator, std.testing.io)).len);
    }
}

test "get and list skip secrets whose value is empty or cannot be read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    var vault = LinuxKeychainVault.init();
    try vault.set(allocator, std.testing.io, .{ .name = "empty", .type = "t", .value = "x" });
    try vault.set(allocator, std.testing.io, .{ .name = "broken", .type = "t", .value = "x" });
    try vault.set(allocator, std.testing.io, .{ .name = "good", .type = "t", .value = "x" });
    try standIns.setMode("unreadable-lookup");

    try std.testing.expect((try vault.get(allocator, std.testing.io, "empty")) == null);
    try std.testing.expect((try vault.get(allocator, std.testing.io, "broken")) == null);
    const secrets = try vault.list(allocator, std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), secrets.len);
    try std.testing.expectEqualStrings("good", secrets[0].name);
}

test "parseSearchOutput trims lines and values as String.prototype.trim does, Unicode spaces included" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const output = "\u{00A0}attribute.account = psi-one\u{3000}\n\u{FEFF}attribute.secrettype = api-key\u{00A0}\n";
    const entries = try linux_keychain_vault.parseSearchOutput(arena.allocator(), output);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("psi-one", entries[0].account);
    try std.testing.expectEqualStrings("api-key", entries[0].secretType);
}
