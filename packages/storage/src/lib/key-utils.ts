import { generateKeyPairSync, createPrivateKey, createPublicKey, KeyObject } from 'node:crypto';
import * as fs from 'fs-extra';
import * as path from 'path';

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

    const dirname = path.dirname(keyFilePath);
    await fs.ensureDir(dirname);

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
        if (await fs.pathExists(keyFilePath)) {
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
        if (await fs.pathExists(keyFilePath)) {
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