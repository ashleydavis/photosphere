import type { KeyObject } from "node:crypto";

/**
 * Map of key identifier to private key for decryption.
 * Use "default" for old-format files (no header). Use hex-encoded SHA-256 of
 * the public key for new-format files (header contains key hash).
 */
export type IPrivateKeyMap = Record<string, KeyObject>;
