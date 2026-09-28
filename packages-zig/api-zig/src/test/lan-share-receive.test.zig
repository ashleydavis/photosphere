const std = @import("std");
const api = @import("api-zig");
const vault_zig = @import("vault-zig");
const test_vault = @import("lan-share-test-vault.zig");

const importSecretPayload = api.lan_share_receive.importSecretPayload;
const ISecretSharePayload = api.lan_share.ISecretSharePayload;
const getVault = vault_zig.get_vault.getVault;

// Not ported: the importDatabasePayload tests (importDatabasePayload is not ported: not used by psi secrets).

test "imports secret payload" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    try test_vault.useTestVault();
    defer test_vault.useRealEnvironment();
    const payload: ISecretSharePayload = .{
        .type = "secret",
        .name = "s3:my-s3",
        .secretType = "s3-credentials",
        .value = "{\"region\":\"us-east-1\",\"accessKeyId\":\"AKID\",\"secretAccessKey\":\"SECRET\"}",
    };

    try importSecretPayload(allocator, io, payload, "imported1");

    const vault = try getVault("plaintext");
    const secret = (try vault.get(allocator, io, "imported1")).?;
    try std.testing.expectEqualStrings("imported1", secret.name);
    try std.testing.expectEqualStrings("s3-credentials", secret.type);
    try std.testing.expectEqualStrings(payload.value, secret.value);
    try std.testing.expect((try vault.get(allocator, io, "s3:my-s3")) == null);
}
