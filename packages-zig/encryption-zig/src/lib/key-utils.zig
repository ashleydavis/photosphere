const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const crypto = @import("node-crypto.zig");
const encryption_types = @import("encryption-types.zig");

//
// Names used from other files.
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
// The result of loadEncryptionKeysFromPem: the storage options and whether the storage is encrypted.
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

//
// Save a key pair to files: the private key at keyFilePath and the public key beside it at keyFilePath plus ".pub".
//
// @param keyPair The key pair to save
// @param keyFilePath Path to save the private key
//
pub fn saveKeyPair(allocator: std.mem.Allocator, io: std.Io, keyPair: IKeyPair, keyFilePath: []const u8) !void {
    const privateKeyPem = try crypto.exportPrivateKey(allocator, keyPair.privateKey, .pem);
    const publicKeyPem = try crypto.exportPublicKey(allocator, keyPair.publicKey, .pem);

    try node_utils.fs.ensureFileDir(io, keyFilePath);

    try node_utils.node_fs.writeFile(io, keyFilePath, privateKeyPem);

    const publicKeyPath = try std.mem.concat(allocator, u8, &.{ keyFilePath, ".pub" });
    try node_utils.node_fs.writeFile(io, publicKeyPath, publicKeyPem);
}

//
// Load a private key from a file
//
// @param keyFilePath Path to the private key file
// @returns The loaded private key or null if the file doesn't exist
//
pub fn loadPrivateKey(allocator: std.mem.Allocator, io: std.Io, keyFilePath: []const u8) ?*const crypto.PrivateKey {
    if (!node_utils.fs.pathExists(io, keyFilePath)) {
        return null;
    }

    const privateKeyPem = node_utils.node_fs.readFile(allocator, io, keyFilePath) catch |err| {
        utils.console.errorFormat("Error loading private key from {s}: {s}: {s}", .{ keyFilePath, utils.errors.errorName(err), utils.errors.errorMessage(err) });
        return null;
    };
    return crypto.createPrivateKey(allocator, privateKeyPem) catch |err| {
        utils.console.errorFormat("Error loading private key from {s}: {s}: {s}", .{ keyFilePath, utils.errors.errorName(err), utils.errors.errorMessage(err) });
        return null;
    };
}

//
// Load a public key from a file
//
// @param keyFilePath Path to the public key file (typically ends with .pub)
// @returns The loaded public key or null if the file doesn't exist
//
pub fn loadPublicKey(allocator: std.mem.Allocator, io: std.Io, keyFilePath: []const u8) ?*const crypto.PublicKey {
    if (!node_utils.fs.pathExists(io, keyFilePath)) {
        return null;
    }

    const publicKeyPem = node_utils.node_fs.readFile(allocator, io, keyFilePath) catch |err| {
        utils.console.errorFormat("Error loading public key from {s}: {s}: {s}", .{ keyFilePath, utils.errors.errorName(err), utils.errors.errorMessage(err) });
        return null;
    };
    return crypto.createPublicKey(allocator, publicKeyPem) catch |err| {
        utils.console.errorFormat("Error loading public key from {s}: {s}: {s}", .{ keyFilePath, utils.errors.errorName(err), utils.errors.errorMessage(err) });
        return null;
    };
}

//
// Loads or generates a key pair
//
// @param keyFilePath Path to the private key file
// @param generate Whether to generate a new key pair if none exists
// @returns The key pair or null if no keys exist and generation is disabled
//
pub fn loadOrGenerateKeyPair(allocator: std.mem.Allocator, io: std.Io, keyFilePath: []const u8, generate: bool) !?IKeyPair {
    const privateKey = loadPrivateKey(allocator, io, keyFilePath);
    const publicKeyPath = try std.mem.concat(allocator, u8, &.{ keyFilePath, ".pub" });
    const publicKey = loadPublicKey(allocator, io, publicKeyPath);

    if (privateKey != null and publicKey != null) {
        return IKeyPair{
            .privateKey = privateKey.?,
            .publicKey = publicKey.?,
        };
    }

    if (generate) {
        const keyPair = try generateKeyPair(allocator, io);
        try saveKeyPair(allocator, io, keyPair, keyFilePath);
        return keyPair;
    }

    return null;
}

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
        return ILoadedEncryptionKeys{
            .options = .{},
            .isEncrypted = false,
        };
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
        return ILoadedEncryptionKeys{
            .options = .{},
            .isEncrypted = false,
        };
    }

    return ILoadedEncryptionKeys{
        .options = .{
            .decryptionKeyMap = decryptionKeyMap,
            .encryptionPublicKey = encryptionPublicKey,
        },
        .isEncrypted = true,
    };
}

//
// Load encryption keys for storage
//
// @param keyPaths Array of paths to key files (first is default/write key)
// @param generateKey Whether to generate a key if it doesn't exist
// @returns Storage options with encryption keys, or empty object if no key provided
//
pub fn loadEncryptionKeys(allocator: std.mem.Allocator, io: std.Io, keyPaths: []const []const u8, generateKey: bool) !ILoadedEncryptionKeys {
    if (keyPaths.len == 0) {
        return ILoadedEncryptionKeys{
            .options = .{},
            .isEncrypted = false,
        };
    }

    var decryptionKeyMap: IPrivateKeyMap = .empty;
    var encryptionPublicKey: ?*const crypto.PublicKey = null;

    for (keyPaths, 0..) |keyPath, index| {
        if (generateKey) {
            const keyPair = (try loadOrGenerateKeyPair(allocator, io, keyPath, true)) orelse {
                return utils.errors.throwError("Failed to generate key pair at {s}", .{keyPath});
            };

            const keyHash = try hashPublicKey(allocator, keyPair.publicKey);
            const keyHashHex = try allocator.dupe(u8, &std.fmt.bytesToHex(keyHash, .lower));
            try decryptionKeyMap.put(allocator, keyHashHex, keyPair.privateKey);

            if (index == 0) {
                try decryptionKeyMap.put(allocator, "default", keyPair.privateKey);
                encryptionPublicKey = keyPair.publicKey;
            }
        }
        else {
            const privateKey = loadPrivateKey(allocator, io, keyPath) orelse {
                return utils.errors.throwFatalError("Private key not found: {s}\nUse --generate-key to create a new key or specify an existing key file either in the current directory or in the ~/.config/photosphere/keys directory.", .{keyPath});
            };

            const publicKeyPath = try std.mem.concat(allocator, u8, &.{ keyPath, ".pub" });
            const publicKey = loadPublicKey(allocator, io, publicKeyPath) orelse crypto.createPublicKeyFromPrivateKey(privateKey);

            const keyHash = try hashPublicKey(allocator, publicKey);
            const keyHashHex = try allocator.dupe(u8, &std.fmt.bytesToHex(keyHash, .lower));
            try decryptionKeyMap.put(allocator, keyHashHex, privateKey);

            if (index == 0) {
                try decryptionKeyMap.put(allocator, "default", privateKey);
                encryptionPublicKey = publicKey;
            }
        }
    }

    if (encryptionPublicKey == null or decryptionKeyMap.get("default") == null) {
        return ILoadedEncryptionKeys{
            .options = .{},
            .isEncrypted = false,
        };
    }

    return ILoadedEncryptionKeys{
        .options = .{
            .decryptionKeyMap = decryptionKeyMap,
            .encryptionPublicKey = encryptionPublicKey,
        },
        .isEncrypted = true,
    };
}
