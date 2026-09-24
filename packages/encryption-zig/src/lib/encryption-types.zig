const std = @import("std");
const crypto = @import("node-crypto.zig");

//
// Map of key identifier to private key for decryption.
// Use "default" for old-format files (no header). Use hex-encoded SHA-256 of
// the public key for new-format files (header contains key hash).
// (TypeScript: Record<string, KeyObject>. Keys are looked up with get() and added with put().)
//
pub const IPrivateKeyMap = std.StringArrayHashMapUnmanaged(*const crypto.PrivateKey);

//
// Options for creating storage with encryption.
//
pub const IStorageOptions = struct {
    //
    // Public key used when writing new encrypted data.
    // Must correspond to the "default" private key in decryptionKeyMap.
    //
    encryptionPublicKey: ?*const crypto.PublicKey = null,

    //
    // Map of key identifier to private key for decryption.
    // The "default" entry is used for old-format files (no header).
    //
    decryptionKeyMap: ?IPrivateKeyMap = null,
};
