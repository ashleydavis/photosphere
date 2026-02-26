//
// Constants for the encrypted file format (tag, version, type, key hash length).
// Used by encrypt-buffer and encrypt-stream to build the file header.
//

/** 4-byte magic tag that marks a file as encrypted with the new format. */
export const ENCRYPTION_TAG = Buffer.from('PSEN', 'ascii');

/** Format version of the encryption code (uint32). Version 1 = new header format. */
export const ENCRYPTION_FORMAT_VERSION = 1;

/** 4-byte encryption type identifier (e.g. AES-256-CBC + RSA). */
export const ENCRYPTION_TYPE = 'A2CB';

/** Length in bytes of the public key hash (SHA-256) stored in the header. */
export const PUBLIC_KEY_HASH_LENGTH = 32;
