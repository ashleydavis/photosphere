const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const ziggy = @import("ziggy");
const IVault = @import("vault.zig").IVault;
const PlaintextVault = @import("plaintext-vault.zig").PlaintextVault;
const DEFAULT_VAULT_DIR = @import("plaintext-vault.zig").DEFAULT_VAULT_DIR;
const MacOSKeychainVault = @import("macos-keychain-vault.zig").MacOSKeychainVault;
const LinuxKeychainVault = @import("linux-keychain-vault.zig").LinuxKeychainVault;
const WindowsKeychainVault = @import("windows-keychain-vault.zig").WindowsKeychainVault;
const PhoneVault = @import("phone-vault.zig").PhoneVault;
const INativeCaller = utils.native_caller.INativeCaller;
const errors = utils.errors;
const process_env = node_utils.process_env;

//
// The allocator of the calling thread's cached vault instances, which live as long as the thread. Each thread has its own, as it has
// its own vaultInstances, so no allocator is used by two threads.
//
threadlocal var instance_allocator_state: ziggy.thread_allocator.ThreadAllocator = .init;

//
// Cache of vault instances keyed by type string, one for each thread: a task runs on a thread of its own, and its vaults are its
// own. getVault always returns the same instance for the same type on a thread.
//
threadlocal var vaultInstances: std.StringHashMapUnmanaged(IVault) = .empty;

//
// Returns the default vault type from the PHOTOSPHERE_VAULT_TYPE environment
// variable, falling back to "phone" on Android and iOS, where the keychain is the phone's (as the mobile worker's vault always
// reads the device keychain), and to "keychain" elsewhere.
//
pub fn getDefaultVaultType() []const u8 {
    return process_env.getEnv("PHOTOSPHERE_VAULT_TYPE") orelse if (builtin.abi.isAndroid() or builtin.os.tag == .ios) "phone" else "keychain";
}

//
// Returns the vault for the given type like getVault, and for the type "phone" a vault that keeps its secrets in the phone's keychain
// by asking the host through the given requester. The phone vault is made with the allocator for the caller to use, because the
// requester belongs to the caller (the task running), and it is not cached. A phone vault with no requester is an error.
//
pub fn getVaultWithHost(allocator: std.mem.Allocator, @"type": []const u8, host: ?INativeCaller) !IVault {
    if (!std.mem.eql(u8, @"type", "phone")) {
        return getVault(@"type");
    }
    const requester = host orelse {
        return errors.throwError("The phone vault needs the phone's shell to keep the secrets, and this program has none.", .{});
    };
    const instance = try allocator.create(PhoneVault);
    instance.* = PhoneVault.init(requester);
    return instance.vault();
}

//
// Returns the vault instance for the given type string, creating it on first
// call and reusing it on subsequent calls.
//
// Supported types:
//   "keychain"  - stores secrets in the OS keychain (macOS, Linux, Windows)
//   "plaintext" - stores secrets as plain-text JSON files under ~/.config/vault
//   "phone"     - stores secrets in the phone's keychain (getVaultWithHost only)
//
// Throws if the type is not recognised.
//
pub fn getVault(@"type": []const u8) !IVault {
    const instance_allocator = instance_allocator_state.allocator();
    if (vaultInstances.get(@"type")) |existing| {
        return existing;
    }

    const vault = try instantiateVault(@"type");
    try vaultInstances.put(instance_allocator, try instance_allocator.dupe(u8, @"type"), vault);
    return vault;
}

//
// The name of the current platform as the keychain error message words it ("darwin", "win32", "linux").
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
    const instance_allocator = instance_allocator_state.allocator();
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
