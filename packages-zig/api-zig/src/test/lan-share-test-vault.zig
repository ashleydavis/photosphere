const std = @import("std");
const node_utils = @import("node-utils-zig");

//
// The environment the LAN share tests run the plaintext vault with (the `jest.mock("vault", ...)` of the TypeScript
// tests, which give getDefaultVaultType "plaintext"): PHOTOSPHERE_VAULT_TYPE=plaintext and a PHOTOSPHERE_VAULT_DIR
// of this test program's own, so the tests never touch the real vault. getVault keeps the first plaintext vault it
// makes, so every test shares the one directory and uses secret names of its own.
//
var environment: ?std.process.Environ.Map = null;

//
// The test program's vault directory: a temporary directory under the package's .zig-cache.
//
var vault_directory: ?std.testing.TmpDir = null;

//
// Points the vault at the test program's plaintext vault until useRealEnvironment is called.
//
pub fn useTestVault() !void {
    if (environment == null) {
        vault_directory = std.testing.tmpDir(.{});
        var map = std.process.Environ.Map.init(std.heap.smp_allocator);
        try map.put("PHOTOSPHERE_VAULT_TYPE", "plaintext");
        try map.put("PHOTOSPHERE_VAULT_DIR", try std.fmt.allocPrint(std.heap.smp_allocator, ".zig-cache/tmp/{s}", .{vault_directory.?.sub_path}));
        environment = map;
    }
    node_utils.process_env.setEnvironMap(&environment.?);
}

//
// Puts the environment back to none, as the other tests expect.
//
pub fn useRealEnvironment() void {
    node_utils.process_env.setEnvironMap(null);
}
