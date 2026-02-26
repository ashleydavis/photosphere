//
// Constants for the encrypted file format (tag, version, type, key hash length).
// Used by encrypt-buffer and encrypt-stream to build the file header.
//

/** 4-byte magic tag that marks a file as encrypted with the new format. */
export const ENCRYPTION_TAG = 'PSEN';

/** Format version of the encryption code (uint32). Version 1 = new header format. */
export const ENCRYPTION_FORMAT_VERSION = 1;

/** 4-byte encryption type identifier (e.g. AES-256-CBC + RSA). */
export const ENCRYPTION_TYPE = 'A2CB';

/** Length in bytes of the public key hash (SHA-256) stored in the header. */
export const PUBLIC_KEY_HASH_LENGTH = 32;

/** Length in bytes of the legacy payload header (encryptedKey + iv). */
export const LEGACY_HEADER_LENGTH = 512 + 16;

/** Length in bytes of the new-format file header (tag + version + type + keyHash). */
export const NEW_FORMAT_HEADER_LENGTH = 4 + 4 + 4 + PUBLIC_KEY_HASH_LENGTH;

/** Offset in bytes at which ciphertext starts in a new-format file (header + legacy header). */
export const NEW_FORMAT_PAYLOAD_OFFSET = NEW_FORMAT_HEADER_LENGTH + LEGACY_HEADER_LENGTH;

/** Format version values that are supported for decryption. */
export const SUPPORTED_VERSIONS: readonly number[] = [1];

/** Encryption type values that are supported for decryption. */
export const SUPPORTED_TYPES: readonly string[] = ["A2CB"];
