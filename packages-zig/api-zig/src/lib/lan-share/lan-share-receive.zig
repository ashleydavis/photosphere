const std = @import("std");
const vault_zig = @import("vault-zig");
const lan_share_core = @import("lan-share-core-zig");
const index = @import("index.zig");

//
// Names used from other files (the equivalent of the TypeScript imports).
//
const getVault = vault_zig.get_vault.getVault;
const getDefaultVaultType = vault_zig.get_vault.getDefaultVaultType;
const importShareSecrets = lan_share_core.importShareSecrets;
const IShareSecretStore = lan_share_core.IShareSecretStore;
const ISecretSharePayload = index.ISecretSharePayload;
const IDatabaseSharePayload = index.IDatabaseSharePayload;
const IShareDatabaseConfig = index.IShareDatabaseConfig;
const ConflictResolver = index.ConflictResolver;

//
// The state of the store vaultSecretStore returns: the Io the vault is used with.
//
const IVaultSecretStoreContext = struct {
    // The Io the vault calls are made with.
    io: std.Io,
};

//
// The `has` of vaultSecretStore: whether the vault holds a secret with the name.
//
fn vaultHas(context: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!bool {
    const storeContext: *IVaultSecretStoreContext = @ptrCast(@alignCast(context.?));
    const vault = try getVault(getDefaultVaultType());
    return (try vault.get(allocator, storeContext.io, name)) != null;
}

//
// The `write` of vaultSecretStore: creates or overwrites a secret in the vault.
//
fn vaultWrite(context: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8, secretType: []const u8, value: []const u8) anyerror!void {
    const storeContext: *IVaultSecretStoreContext = @ptrCast(@alignCast(context.?));
    const vault = try getVault(getDefaultVaultType());
    try vault.set(allocator, storeContext.io, .{
        .name = name,
        .type = secretType,
        .value = value,
    });
}

//
// Adapts the OS vault to the IShareSecretStore the shared importer writes through. `has` reports
// whether a secret exists (to detect a conflict); `write` creates or overwrites one.
//
fn vaultSecretStore(allocator: std.mem.Allocator, io: std.Io) !IShareSecretStore {
    const storeContext = try allocator.create(IVaultSecretStoreContext);
    storeContext.* = .{
        .io = io,
    };
    return .{
        .context = storeContext,
        .has = vaultHas,
        .write = vaultWrite,
    };
}

//
// Imports a database share payload by creating vault entries for each
// included secret and returning a database config ready to be saved.
// The caller is responsible for calling addDatabaseEntry with the result.
// onConflict is called whenever an incoming secret name already exists in
// the vault, allowing the caller to choose how to resolve it. The per-secret
// resolve-and-write loop is shared with mobile via lan-share-core.
//
pub fn importDatabasePayload(allocator: std.mem.Allocator, io: std.Io, payload: IDatabaseSharePayload, onConflict: ConflictResolver) !IShareDatabaseConfig {
    const resolvedKeys = try importShareSecrets(allocator, payload, try vaultSecretStore(allocator, io), onConflict);
    return .{
        .name = payload.name,
        .description = payload.description,
        .path = payload.path,
        .origin = payload.origin,
        .s3Key = resolvedKeys.s3Key,
        .encryptionKey = resolvedKeys.encryptionKey,
        .geocodingKey = resolvedKeys.geocodingKey,
    };
}

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
