const std = @import("std");
const vault_zig = @import("vault-zig");
const utils = @import("utils-zig");
const windows_keychain_vault = vault_zig.windows_keychain_vault;
const WindowsKeychainVault = windows_keychain_vault.WindowsKeychainVault;
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
    var vault = WindowsKeychainVault.init();

    try std.testing.expect((try vault.get(arena.allocator(), std.testing.io, "missing")) == null);
}

test "get: returns the secret after set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
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
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
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
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    var vault = WindowsKeychainVault.init();

    const secret: ISecret = .{ .name = "it's", .type = "plain", .value = "don't" };
    try vault.set(allocator, io, secret);
    try std.testing.expectEqualStrings("{\"type\":\"plain\",\"value\":\"don't\"}", (try standIns.readStore()).get("psi-it's").?.string);
    try expectSecretEqual(secret, try vault.get(allocator, io, "it's"));
}

test "list: returns empty array when no secrets exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    var vault = WindowsKeychainVault.init();

    try std.testing.expectEqual(@as(usize, 0), (try vault.list(arena.allocator(), std.testing.io)).len);
}

test "list: returns all stored secrets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    var vault = WindowsKeychainVault.init();

    try vault.set(allocator, io, .{ .name = "a", .type = "plain", .value = "1" });
    try vault.set(allocator, io, .{ .name = "b", .type = "plain", .value = "2" });
    const result = try vault.list(allocator, io);
    std.mem.sort(ISecret, result, {}, secretNameLessThan);
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("a", result[0].name);
    try std.testing.expectEqualStrings("b", result[1].name);
}

test "delete: removes the secret (subsequent get returns undefined)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    var vault = WindowsKeychainVault.init();

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
    var vault = WindowsKeychainVault.init();

    try vault.delete(arena.allocator(), std.testing.io, "nonexistent");
}

test "psi- prefix: adds psi- prefix on write and strips it on read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    var vault = WindowsKeychainVault.init();

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
    var vault = WindowsKeychainVault.init();

    const secret: ISecret = .{ .name = "my:s3test01", .type = "s3-credentials", .value = "data" };
    try vault.set(allocator, io, secret);
    try expectSecretEqual(secret, try vault.get(allocator, io, "my:s3test01"));
}

test "get runs the same PowerShell script as TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
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
    const recordedArgs = (try standIns.readRecordedArgs("last-get-args")).?;
    try std.testing.expectEqual(@as(usize, 4), recordedArgs.len);
    try std.testing.expectEqualStrings("powershell", recordedArgs[0]);
    try std.testing.expectEqualStrings("-NoProfile", recordedArgs[1]);
    try std.testing.expectEqualStrings("-Command", recordedArgs[2]);
    try std.testing.expectEqualStrings(expected, recordedArgs[3]);
}

test "the IVault interface reaches every operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    var windowsVault = WindowsKeychainVault.init();
    const vault = windowsVault.vault();

    try std.testing.expect((try vault.checkPrereqs(allocator, std.testing.io)).ok);
    try vault.set(allocator, std.testing.io, .{ .name = "k", .type = "api-key", .value = "v" });
    try expectSecretEqual(.{ .name = "k", .type = "api-key", .value = "v" }, try vault.get(allocator, std.testing.io, "k"));
    try std.testing.expectEqual(@as(usize, 1), (try vault.list(allocator, std.testing.io)).len);
    try vault.delete(allocator, std.testing.io, "k");
    try std.testing.expect((try vault.get(allocator, std.testing.io, "k")) == null);
}

test "get: a payload with a repeated key is read with its last value, as JSON.parse reads it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    var store: std.json.ObjectMap = .empty;
    try store.put(allocator, "psi-repeated", .{
        .string = "{\"type\":\"plain\",\"value\":\"first\",\"value\":\"second\"}",
    });
    try standIns.writeStore(store);
    var vault = WindowsKeychainVault.init();

    const secret = try vault.get(allocator, std.testing.io, "repeated");
    try std.testing.expectEqualStrings("second", secret.?.value);
}
