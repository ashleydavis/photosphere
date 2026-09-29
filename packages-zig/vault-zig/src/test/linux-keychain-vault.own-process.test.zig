const std = @import("std");
const vault_zig = @import("vault-zig");
const utils = @import("utils-zig");
const LinuxKeychainVault = vault_zig.linux_keychain_vault.LinuxKeychainVault;
const IStandIns = @import("stand-ins.zig").IStandIns;
const errors = utils.errors;

//
// These tests run in a test program of their own (see build.zig), because the Linux vault checks for secret-tool once
// per process, as the TypeScript vault does once per module: in the test program that runs the other vault tests the
// check has already been made.
//

test "checkPrereqs and every operation report a missing secret-tool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var standIns = try IStandIns.setUp(arena.allocator(), std.testing.io);
    defer standIns.tearDown();
    try standIns.setMode("missing-secret-tool");
    var linuxVault = LinuxKeychainVault.init();
    const vault = linuxVault.vault();

    const prereqs = try vault.checkPrereqs(allocator, std.testing.io);
    try std.testing.expect(!prereqs.ok);
    try std.testing.expectEqualStrings("secret-tool is not installed. Install it with: sudo apt install libsecret-tools", prereqs.message.?);

    try std.testing.expectError(error.Thrown, vault.get(allocator, std.testing.io, "k"));
    try std.testing.expectEqualStrings("secret-tool is not installed. Install it with: sudo apt install libsecret-tools", errors.lastErrorMessage());

    // checkPrereqs checks again each time.
    try standIns.setMode("");
    try std.testing.expect((try vault.checkPrereqs(allocator, std.testing.io)).ok);
}

