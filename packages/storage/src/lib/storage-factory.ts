import { IStorage } from './storage';
import { FileStorage } from './file-storage';
import { CloudStorage, IS3Credentials } from './cloud-storage';
import { EncryptedStorage } from './encrypted-storage';
import { StoragePrefixWrapper } from './storage-prefix-wrapper';
import type { IStorageOptions } from 'encryption';
import path from 'node:path';

//
// Join paths.
//
export function pathJoin(...paths: string[]): string {
    let result = paths.filter(path => path.length > 0).join('/').replace(/\/+$/, '');

    // Filter out double forward slashes.
    result = result.replace(/\/{2,}/g, '/');    

    return result;
}

//
// Result of creating a storage instance.
//
export interface ICreateStorageResult {
    //
    // The storage instance, wrapped with encryption if keys were provided.
    //
    storage: IStorage;

    //
    // The raw (unencrypted) storage instance, for writing files that must be readable without a key.
    //
    rawStorage: IStorage;

    //
    // The normalized path used as the storage root prefix.
    //
    normalizedPath: string;

    //
    // The storage type identifier (e.g. "fs", "s3", "encrypted-fs").
    //
    type: string;
}

//
// Creates the appropriate storage implementation based on the prefix in the path.
//
export function createStorage(rootPath: string, s3Config?: IS3Credentials, options?: IStorageOptions): ICreateStorageResult {
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
        storage = new CloudStorage(`s3:`, s3Config);
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

    const rawStorage = new StoragePrefixWrapper(storage, normalizedPath);

    // Wrap with encryption if keys are provided
    if (options?.decryptionKeyMap && options.encryptionPublicKey) {
        storage = new EncryptedStorage(storage.location, storage, options.decryptionKeyMap, options.encryptionPublicKey);
        type = `encrypted-${type}`;
    }

    storage = new StoragePrefixWrapper(storage, normalizedPath);

    return { storage, rawStorage, normalizedPath, type };
}