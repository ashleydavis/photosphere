const std = @import("std");
const utils = @import("utils-zig");
const vault_zig = @import("vault-zig");
const index = @import("index.zig");

//
// Names used from other files (the equivalent of the TypeScript imports).
//
const getVault = vault_zig.get_vault.getVault;
const getDefaultVaultType = vault_zig.get_vault.getDefaultVaultType;
const ISecretSharePayload = index.ISecretSharePayload;
const errors = utils.errors;

// Not ported: resolveDatabaseSharePayload (the database share of psi dbs send, not used by psi secrets).

//
// Builds a secret share payload by reading a vault entry by name
// and wrapping it in the share payload format.
//
pub fn resolveSecretSharePayload(allocator: std.mem.Allocator, io: std.Io, secretName: []const u8) !ISecretSharePayload {
    const vault = try getVault(getDefaultVaultType());
    const secret = try vault.get(allocator, io, secretName) orelse {
        return errors.throwError("Secret \"{s}\" not found in vault.", .{secretName});
    };

    return .{
        .type = "secret",
        .name = secretName,
        .secretType = secret.type,
        .value = secret.value,
    };
}
