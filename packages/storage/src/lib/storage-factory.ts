import { KeyObject } from 'node:crypto';
import { IStorage } from './storage';
import { FileStorage } from './file-storage';
import { CloudStorage, IS3Credentials } from './cloud-storage';
import { EncryptedStorage } from './encrypted-storage';
import { StoragePrefixWrapper } from './storage-prefix-wrapper';
import path from 'node:path';

//
// Join paths.
//
export function pathJoin(...paths: string[]): string {
    let result = paths.join('/').replace(/\/+$/, '');

    // Filter out double forward slashes.
    result = result.replace(/\/{2,}/g, '/');    

    return result;
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
 * @param inputPath Path with storage prefix (e.g. "fs:/path" or "s3:bucket/path") - can be file or directory
 * @param s3Config S3 configuration if using S3 storage
 * @param options Options for storage creation including encryption keys
 * @returns The corresponding storage implementation and normalized path for use with storage operations
 */
export function createStorage(
    inputPath: string, 
    s3Config?: IS3Credentials,
    options?: IStorageOptions
): { storage: IStorage, normalizedPath: string, type: string } {
    if (!inputPath) {
        throw new Error('Path is required');
    }

    // Parse the input path to determine if it's a file or directory
    let directoryPath: string;
    let relativeFilePath: string;
    let isFilePath = false;

    // Detect if this looks like a file path (has an extension)
    // This is a heuristic - we assume paths with extensions are files
    if (inputPath.includes('.') && !inputPath.endsWith('/')) {
        // Check if the last segment after the last slash has an extension
        const lastSlashIndex = inputPath.lastIndexOf('/');
        const lastSegment = lastSlashIndex >= 0 ? inputPath.substring(lastSlashIndex + 1) : inputPath;
        
        // If the last segment has a dot and it's not at the beginning (hidden file), treat as file
        if (lastSegment.includes('.') && !lastSegment.startsWith('.')) {
            isFilePath = true;
        }
    }

    if (isFilePath) {
        // For file paths, create storage for the directory and return the filename as normalizedPath
        if (inputPath.startsWith('fs:') || inputPath.startsWith('s3:')) {
            // Handle prefixed paths
            const colonIndex = inputPath.indexOf(':');
            const prefix = inputPath.substring(0, colonIndex + 1);
            const actualPath = inputPath.substring(colonIndex + 1);
            const lastSlashIndex = actualPath.lastIndexOf('/');
            
            if (lastSlashIndex === -1) {
                // No directory separator, file is in root
                directoryPath = prefix;
                relativeFilePath = actualPath;
            } else {
                directoryPath = prefix + actualPath.substring(0, lastSlashIndex);
                relativeFilePath = actualPath.substring(lastSlashIndex + 1);
            }
        } else {
            // Handle regular paths
            const lastSlashIndex = inputPath.lastIndexOf('/');
            if (lastSlashIndex === -1) {
                // No directory separator, file is in current directory
                directoryPath = '.';
                relativeFilePath = inputPath;
            } else {
                directoryPath = inputPath.substring(0, lastSlashIndex);
                relativeFilePath = inputPath.substring(lastSlashIndex + 1);
            }
        }
    } else {
        // For directory paths, create storage for the directory and return empty path
        directoryPath = inputPath;
        relativeFilePath = '';
    }

    let storage: IStorage;
    let storageRootPath: string;
    let type: string;

    // Check for storage prefix on the directory path
    if (directoryPath.startsWith('fs:')) {
        storage = new FileStorage(`fs:`);
        storageRootPath = path.resolve(directoryPath.substring('fs:'.length));
        type = 'fs';
    } 
    else if (directoryPath.startsWith('s3:')) {
        // For S3, we keep the bucket:key format that CloudStorage expects
        const s3Path = directoryPath.substring('s3:'.length);
        storage = new CloudStorage(`s3:`, true, s3Config);
        storageRootPath = s3Path;
        type = 's3';
    } 
    else {
        // Assume local file system for backward compatibility
        storage = new FileStorage(`fs:`);
        storageRootPath = path.resolve(directoryPath);
        type = 'fs';
    }

    storageRootPath = storageRootPath.replace(/\\/g, '/'); // Convert backslashes to forward slashes for consistency.

    // Wrap with encryption if keys are provided
    if (options?.privateKey) {
        storage = new EncryptedStorage(directoryPath, storage, options.publicKey || options.privateKey, options.privateKey);
        // console.log(`Loading encrypted storage for path: ${directoryPath}`);
        type = `encrypted-${type}`;
    }

    storage = new StoragePrefixWrapper(storage, storageRootPath);

    // For directory paths, return the storage root path
    // For file paths, return the relative file path to be used with storage operations
    const normalizedPath = isFilePath ? relativeFilePath : storageRootPath;

    return { storage, normalizedPath, type };
}