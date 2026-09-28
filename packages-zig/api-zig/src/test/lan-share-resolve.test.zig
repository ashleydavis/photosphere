const std = @import("std");
const api = @import("api-zig");
const utils = @import("utils-zig");
const vault_zig = @import("vault-zig");
const test_vault = @import("lan-share-test-vault.zig");

const resolveSecretSharePayload = api.lan_share_resolve.resolveSecretSharePayload;
const getVault = vault_zig.get_vault.getVault;
const errors = utils.errors;

// Not ported: the resolveDatabaseSharePayload tests (resolveDatabaseSharePayload is not ported: not used by psi
// secrets).

test "resolves secret share payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    try test_vault.useTestVault();
    defer test_vault.useRealEnvironment();
    const vault = try getVault("plaintext");
    try vault.set(allocator, io, .{
        .name = "abc12345",
        .type = "s3-credentials",
        .value = "{\"region\":\"us-east-1\",\"accessKeyId\":\"AKID\",\"secretAccessKey\":\"SECRET\"}",
    });

    const payload = try resolveSecretSharePayload(allocator, io, "abc12345");

    try std.testing.expectEqualStrings("secret", payload.type);
    try std.testing.expectEqualStrings("s3-credentials", payload.secretType);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, payload.value, .{});
    try std.testing.expectEqualStrings("us-east-1", parsed.object.get("region").?.string);
}

test "resolves secret share payload throws when secret not found" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try test_vault.useTestVault();
    defer test_vault.useRealEnvironment();

    try std.testing.expectError(error.Thrown, resolveSecretSharePayload(arena.allocator(), std.testing.io, "nonexistent"));
    try std.testing.expectEqualStrings("Secret \"nonexistent\" not found in vault.", errors.lastErrorMessage());
}
