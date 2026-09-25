const std = @import("std");
const crypto = @import("node-crypto.zig");
const encryption_types = @import("encryption-types.zig");

//
// Names used from other files (the equivalent of the TypeScript imports).
//
const IStorageOptions = encryption_types.IStorageOptions;
const IPrivateKeyMap = encryption_types.IPrivateKeyMap;

//
// Interface for key pair
//
pub const IKeyPair = struct {
    // The public key.
    publicKey: *const crypto.PublicKey,

    // The private key.
    privateKey: *const crypto.PrivateKey,
};

//
// An RSA key pair stored as PEM strings.
//
pub const IEncryptionKeyPem = struct {
    // PEM-encoded PKCS#8 private key.
    privateKeyPem: []const u8,

    // PEM-encoded SPKI public key.
    publicKeyPem: []const u8,
};

//
// The result of loadEncryptionKeysFromPem (TypeScript: { options: IStorageOptions, isEncrypted: boolean }).
//
pub const ILoadedEncryptionKeys = struct {
    // Storage options with encryption keys (empty when not encrypted).
    options: IStorageOptions,

    // True when at least one key was loaded.
    isEncrypted: bool,
};

//
// Generate a new RSA key pair
//
// @returns The generated key pair
//
pub fn generateKeyPair(allocator: std.mem.Allocator, io: std.Io) !IKeyPair {
    const generated = try crypto.generateKeyPairSync(allocator, io, 4096);

    return IKeyPair{
        .publicKey = try crypto.createPublicKey(allocator, generated.publicKey),
        .privateKey = try crypto.createPrivateKey(allocator, generated.privateKey),
    };
}

// Not ported: saveKeyPair (not reached by replicate or verify)
// Not ported: loadPrivateKey (not reached by replicate or verify)
// Not ported: loadPublicKey (not reached by replicate or verify)
// Not ported: loadOrGenerateKeyPair (not reached by replicate or verify)

//
// Export a public key to SPKI PEM string (same format as .pub files and .db/encryption.pub).
//
pub fn exportPublicKeyToPem(allocator: std.mem.Allocator, publicKey: *const crypto.PublicKey) ![]u8 {
    return crypto.exportPublicKey(allocator, publicKey, .pem);
}

//
// Returns a 32-byte SHA-256 hash of the public key (SPKI format).
// Used in the encrypted file header to identify which key encrypted the file.
//
pub fn hashPublicKey(allocator: std.mem.Allocator, publicKey: *const crypto.PublicKey) ![32]u8 {
    const spki = try crypto.exportPublicKey(allocator, publicKey, .der);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(spki, &digest, .{});
    return digest;
}

//
// Load encryption keys from PEM strings without touching the filesystem.
// Accepts an array of { privateKeyPem, publicKeyPem } objects.
// The first entry becomes the default encryption (write) key.
//
// @param keyPems Array of PEM key pair objects
// @returns Storage options with encryption keys, or empty object if array is empty
//
pub fn loadEncryptionKeysFromPem(allocator: std.mem.Allocator, keyPems: []const IEncryptionKeyPem) !ILoadedEncryptionKeys {
    if (keyPems.len == 0) {
        return ILoadedEncryptionKeys{ .options = .{}, .isEncrypted = false };
    }

    var decryptionKeyMap: IPrivateKeyMap = .empty;
    var encryptionPublicKey: ?*const crypto.PublicKey = null;

    for (keyPems, 0..) |keyPem, index| {
        const privateKey = try crypto.createPrivateKey(allocator, keyPem.privateKeyPem);
        const publicKey = try crypto.createPublicKey(allocator, keyPem.publicKeyPem);

        const keyHash = try hashPublicKey(allocator, publicKey);
        const keyHashHex = try allocator.dupe(u8, &std.fmt.bytesToHex(keyHash, .lower));
        try decryptionKeyMap.put(allocator, keyHashHex, privateKey);

        if (index == 0) {
            try decryptionKeyMap.put(allocator, "default", privateKey);
            encryptionPublicKey = publicKey;
        }
    }

    if (encryptionPublicKey == null or decryptionKeyMap.get("default") == null) {
        return ILoadedEncryptionKeys{ .options = .{}, .isEncrypted = false };
    }

    return ILoadedEncryptionKeys{
        .options = .{
            .decryptionKeyMap = decryptionKeyMap,
            .encryptionPublicKey = encryptionPublicKey,
        },
        .isEncrypted = true,
    };
}

// Not ported: loadEncryptionKeys (not reached by replicate or verify; the CLI loads keys from the vault as PEM)
