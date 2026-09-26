//
// Constants for the encrypted file format (tag, version, type, key hash length).
// Used by encrypt-buffer and encrypt-stream to build the file header.
//

// 4-byte magic tag that marks a file as encrypted with the new format.
pub const ENCRYPTION_TAG = "PSEN";

// Format version of the encryption code (uint32). Version 1 = new header format.
pub const ENCRYPTION_FORMAT_VERSION: u32 = 1;

// 4-byte encryption type identifier (e.g. AES-256-CBC + RSA).
pub const ENCRYPTION_TYPE = "A2CB";

// Length in bytes of the public key hash (SHA-256) stored in the header.
pub const PUBLIC_KEY_HASH_LENGTH = 32;

//
// Length in bytes of the RSA-wrapped AES key that every encrypted file carries.
//
// It is a fixed number rather than something read out of the file, and every reader slices at it, so
// it is also the only RSA key size that can be read back: 512 bytes is an RSA-4096 block. A smaller
// key wraps into fewer bytes, and the readers then slice in the wrong place, which is why writing
// with one is refused rather than producing a file nothing can decrypt.
//
pub const WRAPPED_KEY_LENGTH = 512;

// Length in bytes of the legacy payload header (encryptedKey + iv).
pub const LEGACY_HEADER_LENGTH = WRAPPED_KEY_LENGTH + 16;

// Length in bytes of the new-format file header (tag + version + type + keyHash).
pub const NEW_FORMAT_HEADER_LENGTH = 4 + 4 + 4 + PUBLIC_KEY_HASH_LENGTH;

// Offset in bytes at which ciphertext starts in a new-format file (header + legacy header).
pub const NEW_FORMAT_PAYLOAD_OFFSET = NEW_FORMAT_HEADER_LENGTH + LEGACY_HEADER_LENGTH;

// Format version values that are supported for decryption.
pub const SUPPORTED_VERSIONS = [_]u32{1};

// Encryption type values that are supported for decryption.
pub const SUPPORTED_TYPES = [_][]const u8{"A2CB"};
