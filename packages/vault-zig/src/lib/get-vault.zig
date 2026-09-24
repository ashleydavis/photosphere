const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const IVault = @import("vault.zig").IVault;
const PlaintextVault = @import("plaintext-vault.zig").PlaintextVault;
const DEFAULT_VAULT_DIR = @import("plaintext-vault.zig").DEFAULT_VAULT_DIR;
const MacOSKeychainVault = @import("macos-keychain-vault.zig").MacOSKeychainVault;
const LinuxKeychainVault = @import("linux-keychain-vault.zig").LinuxKeychainVault;
const WindowsKeychainVault = @import("windows-keychain-vault.zig").WindowsKeychainVault;
const errors = utils.errors;
const process_env = node_utils.process_env;

//
// Allocator for the cached vault instances, which live for the rest of the process (like the
// TypeScript module-level Map). It is thread-safe because worker threads call getVault too.
//
const instance_allocator = std.heap.smp_allocator;

//
// Cache of vault instances keyed by type string.
// getVault always returns the same instance for the same type.
//
var vaultInstances: std.StringHashMapUnmanaged(IVault) = .empty;

//
// Guards vaultInstances (TypeScript runs on one thread; Zig worker threads share the cache).
//
var vaultInstancesMutex: std.Io.Mutex = .init;

//
// Returns the default vault type from the PHOTOSPHERE_VAULT_TYPE environment
// variable, falling back to "keychain" when the variable is not set.
//
pub fn getDefaultVaultType() []const u8 {
    return process_env.getEnv("PHOTOSPHERE_VAULT_TYPE") orelse "keychain";
}

//
// Locks vaultInstancesMutex without an Io (getVault has no Io parameter, like the TypeScript function).
//
fn lockVaultInstances() void {
    while (!vaultInstancesMutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

//
// Unlocks vaultInstancesMutex (it is only ever locked with tryLock, so there are no waiters to wake).
//
fn unlockVaultInstances() void {
    vaultInstancesMutex.state.store(.unlocked, .release);
}

//
// Returns the vault instance for the given type string, creating it on first
// call and reusing it on subsequent calls.
//
// Supported types:
//   "keychain"  - stores secrets in the OS keychain (macOS, Linux, Windows)
//   "plaintext" - stores secrets as plain-text JSON files under ~/.config/vault
//
// Throws if the type is not recognised.
//
pub fn getVault(@"type": []const u8) !IVault {
    lockVaultInstances();
    defer unlockVaultInstances();

    if (vaultInstances.get(@"type")) |existing| {
        return existing;
    }

    const vault = try instantiateVault(@"type");
    try vaultInstances.put(instance_allocator, try instance_allocator.dupe(u8, @"type"), vault);
    return vault;
}

//
// The name Node gives the current platform (`process.platform`).
//
fn processPlatform() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "darwin",
        .windows => "win32",
        else => @tagName(builtin.os.tag),
    };
}

//
// Creates a new vault instance for the given type.
//
pub fn instantiateVault(@"type": []const u8) !IVault {
    if (std.mem.eql(u8, @"type", "plaintext")) {
        const vaultDir = process_env.getEnv("PHOTOSPHERE_VAULT_DIR");
        const instance = try instance_allocator.create(PlaintextVault);
        if (vaultDir != null and vaultDir.?.len > 0) {
            instance.* = PlaintextVault.init(try instance_allocator.dupe(u8, vaultDir.?));
        }
        else {
            instance.* = PlaintextVault.init(try DEFAULT_VAULT_DIR(instance_allocator));
        }
        return instance.vault();
    }
    if (std.mem.eql(u8, @"type", "keychain")) {
        if (builtin.os.tag == .macos) {
            const instance = try instance_allocator.create(MacOSKeychainVault);
            instance.* = MacOSKeychainVault.init();
            return instance.vault();
        }
        if (builtin.os.tag == .linux) {
            const instance = try instance_allocator.create(LinuxKeychainVault);
            instance.* = LinuxKeychainVault.init();
            return instance.vault();
        }
        if (builtin.os.tag == .windows) {
            const instance = try instance_allocator.create(WindowsKeychainVault);
            instance.* = WindowsKeychainVault.init();
            return instance.vault();
        }
        return errors.throwError("Keychain vault is not supported on platform \"{s}\".", .{processPlatform()});
    }
    return errors.throwError("Unknown vault type: \"{s}\". Supported types: \"keychain\", \"plaintext\".", .{@"type"});
}
