//
// An environment whose plaintext vault is a directory that belongs to this test program.
//
// getVault keeps the first plaintext vault it makes for the rest of the program, so a test that asks for one while the environment names
// no directory would make the vault of the user's own configuration folder the vault of every test that follows, and a test program running
// beside another would share it. A test that asks for the cached vault runs with this environment.
//

const std = @import("std");

//
// Makes the environment: PHOTOSPHERE_VAULT_DIR names a directory under the program's cache folder, with a name nothing else has. The
// directory is made when something is written to it. The map is allocated with the allocator.
//
pub fn environmentWithIsolatedVault(allocator: std.mem.Allocator, io: std.Io) !*std.process.Environ.Map {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const current_path = try std.process.currentPathAlloc(io, allocator);
    const directory = try std.fs.path.join(allocator, &.{
        current_path,
        ".zig-cache",
        "tmp-tests",
        try std.fmt.allocPrint(allocator, "vault-zig-{s}", .{&std.fmt.bytesToHex(random_bytes, .lower)}),
    });
    const map = try allocator.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(allocator);
    try map.put("PHOTOSPHERE_VAULT_DIR", directory);
    return map;
}
