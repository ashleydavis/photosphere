const std = @import("std");
const vault_zig = @import("vault-zig");
const index = @import("index.zig");

//
// Names used from other files (the equivalent of the TypeScript imports).
//
const getVault = vault_zig.get_vault.getVault;
const getDefaultVaultType = vault_zig.get_vault.getDefaultVaultType;
const ISecretSharePayload = index.ISecretSharePayload;

// Not ported: vaultSecretStore and importDatabasePayload (the database share of psi dbs receive, not used by psi
// secrets).

//
// Imports a secret share payload by creating a vault entry with the given name.
//
pub fn importSecretPayload(allocator: std.mem.Allocator, io: std.Io, payload: ISecretSharePayload, secretName: []const u8) !void {
    const vault = try getVault(getDefaultVaultType());
    try vault.set(allocator, io, .{
        .name = secretName,
        .type = payload.secretType,
        .value = payload.value,
    });
}
