const std = @import("std");
const encryption = @import("encryption-zig");
const fixture_dirs = @import("fixture-dirs.zig");

//
// Loads the TypeScript generated 4096 bit RSA key pair "ts" of encryption-zig instead of generating a
// key, which takes hundreds of milliseconds each time. (TypeScript: the test makes a fresh pair.)
//
pub fn loadFixtureKeyPair(allocator: std.mem.Allocator, io: std.Io) !encryption.key_utils.IKeyPair {
    const cwd = std.Io.Dir.cwd();
    const privateKeyPem = try cwd.readFileAlloc(io, fixture_dirs.KEYS_DIR ++ "/ts-private.pem", allocator, .unlimited);
    const publicKeyPem = try cwd.readFileAlloc(io, fixture_dirs.KEYS_DIR ++ "/ts-public.pem", allocator, .unlimited);
    const loaded = try encryption.key_utils.loadEncryptionKeysFromPem(allocator, &.{.{
        .privateKeyPem = privateKeyPem,
        .publicKeyPem = publicKeyPem,
    }});
    return .{
        .publicKey = loaded.options.encryptionPublicKey.?,
        .privateKey = loaded.options.decryptionKeyMap.?.get("default").?,
    };
}
