import { KeyObject } from 'node:crypto';
import { IStorage } from './storage';
import { FileStorage } from './file-storage';
import { CloudStorage } from './cloud-storage';
import { EncryptedStorage } from './encrypted-storage';
import { StoragePrefixWrapper } from './storage-prefix-wrapper';
import path from 'node:path';

//
// Join paths.
//
export function pathJoin(...paths: string[]): string {
    return paths.join('/').replace(/\/+$/, '');
}

/**
 * Options for creating storage
 */
export interface IStorageOptions {
    /**
     * Public key for encryption (if using encryption)
     */
    publicKey?: KeyObject;
    
    /**
     * Private key for decryption (if using encryption)
     */
    privateKey?: KeyObject;
}

/**
 * Creates the appropriate storage implementation based on the prefix in the path
 * @param rootPath Path with storage prefix (e.g. "fs:/path" or "s3:bucket/path")
 * @param options Options for storage creation including encryption keys
 * @returns The corresponding storage implementation and normalized path
 */
export function createStorage(
    rootPath: string, 
    options: IStorageOptions = {}
): { storage: IStorage, normalizedPath: string, type: string } {
    if (!rootPath) {
        throw new Error('Path is required');
    }

    let storage: IStorage;
    let normalizedPath: string;
    let type: string;

    // Check for storage prefix
    if (rootPath.startsWith('fs:')) {
        storage = new FileStorage(`fs:`);
        normalizedPath = path.resolve(rootPath.substring('fs:'.length));
        type = 'fs';
    } 
    else if (rootPath.startsWith('s3:')) {
        // For S3, we keep the bucket:key format that CloudStorage expects
        const s3Path = rootPath.substring('s3:'.length);
        storage = new CloudStorage(`s3:`, true);
        normalizedPath = s3Path;
        type = 's3';
    } 
    else {
        // Assume local file system for backward compatibility
        storage = new FileStorage(`fs:`);
        normalizedPath = path.resolve(rootPath);
        type = 'fs';
    }

    normalizedPath = normalizedPath.replace(/\\/g, '/'); // Convert backslashes to forward slashes for consistency.

    // Wrap with encryption if keys are provided
    if (options.privateKey) {
        storage = new EncryptedStorage(rootPath, storage, options.publicKey || options.privateKey, options.privateKey);
        console.log(`Loading encrypted storage for path: ${rootPath}`);
        type = `encrypted-${type}`;
    }

    storage = new StoragePrefixWrapper(storage, normalizedPath);

    return { storage, normalizedPath, type };
}