const std = @import("std");
const vault_zig = @import("vault-zig");
const utils = @import("utils-zig");
const WindowsKeychainVault = vault_zig.windows_keychain_vault.WindowsKeychainVault;
const IStandIns = @import("stand-ins.zig").IStandIns;
const errors = utils.errors;

//
// These tests run in a test program of their own (see build.zig), because the Windows vault checks for PowerShell
// once per process, as the TypeScript vault does once per module: in the test program that runs the other vault tests
// the check has already been made.
//

test "checkPrereqs and every operation report a missing PowerShell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    try standIns.setMode("broken-powershell");
    var windowsVault = WindowsKeychainVault.init();
    const vault = windowsVault.vault();

    const result = try vault.checkPrereqs(allocator, std.testing.io);
    try std.testing.expect(!result.ok);
    try std.testing.expectEqualStrings("PowerShell is not available. PowerShell is required to use the Windows Credential Vault. Install PowerShell from https://aka.ms/powershell", result.message.?);
    try std.testing.expectError(error.Thrown, vault.get(allocator, std.testing.io, "any"));
    try std.testing.expectEqualStrings(result.message.?, errors.lastErrorMessage());
}

