import { createHash, generateKeyPairSync, createPrivateKey, createPublicKey, KeyObject } from 'node:crypto';
import * as fs from 'fs/promises';
import { pathExists } from 'node-utils';
import { IStorageOptions } from './storage-factory';
import { ensureParentDirectoryExists } from 'node-utils';
import { FatalError } from 'utils';
import type { IPrivateKeyMap } from './encryption-types';

/**
 * Interface for key pair
 */
export interface IKeyPair {
    publicKey: KeyObject;
    privateKey: KeyObject;
}

/**
 * Generate a new RSA key pair
 * 
 * @returns A promise that resolves to the generated key pair
 */
export function generateKeyPair(): IKeyPair {
    const { publicKey, privateKey } = generateKeyPairSync('rsa', {
        modulusLength: 4096,
        publicKeyEncoding: {
            type: 'spki',
            format: 'pem'
        },
        privateKeyEncoding: {
            type: 'pkcs8',
            format: 'pem'
        }
    });

    return {
        publicKey: createPublicKey(publicKey),
        privateKey: createPrivateKey(privateKey)
    };
}

/**
 * Save a key pair to files
 * 
 * @param keyPair The key pair to save
 * @param keyFilePath Path to save the private key
 * @returns A promise that resolves when the keys are saved
 */
export async function saveKeyPair(keyPair: IKeyPair, keyFilePath: string): Promise<void> {
    const privateKeyPem = keyPair.privateKey.export({
        type: 'pkcs8',
        format: 'pem'
    });

    const publicKeyPem = keyPair.publicKey.export({
        type: 'spki',
        format: 'pem'
    });

    await ensureParentDirectoryExists(keyFilePath);

    // Save private key
    await fs.writeFile(keyFilePath, privateKeyPem);
    
    // Save public key alongside private key
    const publicKeyPath = `${keyFilePath}.pub`;
    await fs.writeFile(publicKeyPath, publicKeyPem);
}

/**
 * Load a private key from a file
 * 
 * @param keyFilePath Path to the private key file
 * @returns The loaded private key or null if the file doesn't exist
 */
export async function loadPrivateKey(keyFilePath: string): Promise<KeyObject | null> {
    try {
        if (await pathExists(keyFilePath)) {
            const privateKeyPem = await fs.readFile(keyFilePath, 'utf8');
            return createPrivateKey(privateKeyPem);
        }
        return null;
    } catch (error) {
        console.error(`Error loading private key from ${keyFilePath}:`, error);
        return null;
    }
}

/**
 * Load a public key from a file
 * 
 * @param keyFilePath Path to the public key file (typically ends with .pub)
 * @returns The loaded public key or null if the file doesn't exist
 */
export async function loadPublicKey(keyFilePath: string): Promise<KeyObject | null> {
    try {
        if (await pathExists(keyFilePath)) {
            const publicKeyPem = await fs.readFile(keyFilePath, 'utf8');
            return createPublicKey(publicKeyPem);
        }
        return null;
    } catch (error) {
        console.error(`Error loading public key from ${keyFilePath}:`, error);
        return null;
    }
}

/**
 * Loads or generates a key pair
 * 
 * @param keyFilePath Path to the private key file
 * @param generate Whether to generate a new key pair if none exists
 * @returns The key pair or null if no keys exist and generation is disabled
 */
export async function loadOrGenerateKeyPair(keyFilePath: string, generate = false): Promise<IKeyPair | null> {
    // First, try to load existing keys
    const privateKey = await loadPrivateKey(keyFilePath);
    const publicKey = await loadPublicKey(`${keyFilePath}.pub`);
    
    if (privateKey && publicKey) {
        return { privateKey, publicKey };
    }
    
    // If keys don't exist and generation is enabled, create new ones
    if (generate) {
        const keyPair = generateKeyPair();
        await saveKeyPair(keyPair, keyFilePath);
        return keyPair;
    }
    
    return null;
}

/**
 * Returns a 32-byte SHA-256 hash of the public key (SPKI format).
 * Used in the encrypted file header to identify which key encrypted the file.
 */
export function hashPublicKey(publicKey: KeyObject): Buffer {
    const spki = publicKey.export({ type: 'spki', format: 'der' }) as Buffer;
    return createHash('sha256').update(spki).digest();
}

/**
 * Load encryption keys for storage
 *
 * @param keyPaths Array of paths to key files (first is default/write key)
 * @param generateKey Whether to generate a key if it doesn't exist
 * @returns Storage options with encryption keys, or empty object if no key provided
 */
export async function loadEncryptionKeys(
    keyPaths: string[], 
    generateKey: boolean
): Promise<{ options: IStorageOptions, isEncrypted: boolean }> {
    if (!keyPaths || keyPaths.length === 0) {
        return { options: {}, isEncrypted: false };
    }
    
    const decryptionKeyMap: IPrivateKeyMap = {};
    let encryptionPublicKey: KeyObject | undefined = undefined;

    for (let index = 0; index < keyPaths.length; index++) {
        const keyPath = keyPaths[index];

        if (generateKey) {
            const keyPair = await loadOrGenerateKeyPair(keyPath, true);
            
            if (!keyPair) {
                throw new Error(`Failed to generate key pair at ${keyPath}`);
            }

            const keyHashHex = hashPublicKey(keyPair.publicKey).toString('hex');
            decryptionKeyMap[keyHashHex] = keyPair.privateKey;

            if (index === 0) {
                decryptionKeyMap.default = keyPair.privateKey;
                encryptionPublicKey = keyPair.publicKey;
            }
        } 
        else {
            const privateKey = await loadPrivateKey(keyPath);
            if (!privateKey) {
                throw new FatalError(`Private key not found: ${keyPath}\nUse --generate-key to create a new key or specify an existing key file either in the current directory or in the ~/.config/photosphere/keys directory.`);
            }
            
            let publicKey = await loadPublicKey(`${keyPath}.pub`);
            if (!publicKey) {
                publicKey = privateKey;
            }

            const keyHashHex = hashPublicKey(publicKey).toString('hex');
            decryptionKeyMap[keyHashHex] = privateKey;

            if (index === 0) {
                decryptionKeyMap.default = privateKey;
                encryptionPublicKey = publicKey;
            }
        }
    }

    if (!encryptionPublicKey || !decryptionKeyMap.default) {
        return { options: {}, isEncrypted: false };
    }

    return {
        options: {
            decryptionKeyMap,
            encryptionPublicKey
        },
        isEncrypted: true
    };
}
