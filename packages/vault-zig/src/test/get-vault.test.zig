const std = @import("std");
const builtin = @import("builtin");
const vault_zig = @import("vault-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const get_vault = vault_zig.get_vault;
const getVault = get_vault.getVault;
const getDefaultVaultType = get_vault.getDefaultVaultType;
const PlaintextVault = vault_zig.plaintext_vault.PlaintextVault;
const errors = utils.errors;
const process_env = node_utils.process_env;

test "getVault: returns a PlaintextVault for type \"plaintext\"" {
    const vault = try getVault("plaintext");
    try std.testing.expect(vault.vtable == &PlaintextVault.vtable);
}

test "getVault: returns the same instance on repeated calls for the same type" {
    const first = try getVault("plaintext");
    const second = try getVault("plaintext");
    try std.testing.expect(first.ptr == second.ptr);
}

test "getVault: throws for an unknown vault type" {
    try std.testing.expectError(error.Thrown, getVault("bitwarden"));
    try std.testing.expect(std.mem.indexOf(u8, errors.lastErrorMessage(), "Unknown vault type") != null);
}

test "getVault: error message includes the unrecognised type name" {
    try std.testing.expectError(error.Thrown, getVault("1password"));
    try std.testing.expectEqualStrings("Unknown vault type: \"1password\". Supported types: \"keychain\", \"plaintext\".", errors.lastErrorMessage());
}

test "instantiateVault: plaintext uses PHOTOSPHERE_VAULT_DIR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var environ_map = std.process.Environ.Map.init(allocator);
    try environ_map.put("PHOTOSPHERE_VAULT_DIR", "src/test/fixtures/ts-vault");
    process_env.setEnvironMap(&environ_map);
    defer process_env.setEnvironMap(null);

    const vault = try get_vault.instantiateVault("plaintext");
    try std.testing.expect(vault.vtable == &PlaintextVault.vtable);
    const secret = (try vault.get(allocator, io, "my secret")).?;
    try std.testing.expectEqualStrings("spaced", secret.value);
}

test "getDefaultVaultType: returns \"keychain\" when env var is not set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(arena.allocator());
    process_env.setEnvironMap(&environ_map);
    defer process_env.setEnvironMap(null);

    try std.testing.expectEqualStrings("keychain", getDefaultVaultType());
}

test "getDefaultVaultType: returns \"plaintext\" when env var is set to plaintext" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(arena.allocator());
    try environ_map.put("PHOTOSPHERE_VAULT_TYPE", "plaintext");
    process_env.setEnvironMap(&environ_map);
    defer process_env.setEnvironMap(null);

    try std.testing.expectEqualStrings("plaintext", getDefaultVaultType());
}

test "getDefaultVaultType: returns the env var value verbatim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(arena.allocator());
    try environ_map.put("PHOTOSPHERE_VAULT_TYPE", "custom-type");
    process_env.setEnvironMap(&environ_map);
    defer process_env.setEnvironMap(null);

    try std.testing.expectEqualStrings("custom-type", getDefaultVaultType());
}

test "getVault(\"keychain\"): returns the correct platform vault instance" {
    const expected_vtable: ?*const vault_zig.vault.IVault.VTable = switch (builtin.os.tag) {
        .macos => &vault_zig.macos_keychain_vault.MacOSKeychainVault.vtable,
        .linux => &vault_zig.linux_keychain_vault.LinuxKeychainVault.vtable,
        .windows => &vault_zig.windows_keychain_vault.WindowsKeychainVault.vtable,
        else => null,
    };
    if (expected_vtable) |vtable| {
        const vault = try getVault("keychain");
        try std.testing.expect(vault.vtable == vtable);
    }
    else {
        try std.testing.expectError(error.Thrown, getVault("keychain"));
    }
}
