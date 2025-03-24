import { IStorage } from './storage';
import { FileStorage } from './file-storage';
import { CloudStorage } from './cloud-storage';

/**
 * Creates the appropriate storage implementation based on the prefix in the path
 * @param path Path with storage prefix (e.g. "fs:/path" or "s3:bucket/path")
 * @returns The corresponding storage implementation and normalized path
 */
export function createStorage(path: string): { storage: IStorage, normalizedPath: string, type: string } {
    if (!path) {
        throw new Error('Path is required');
    }

    // Check for storage prefix
    if (path.startsWith('fs:')) {
        return {
            storage: new FileStorage(),
            normalizedPath: path.substring('fs:'.length),
            type: 'fs',
        };
    } 
    else if (path.startsWith('s3:')) {
        // For S3, we keep the bucket:key format that CloudStorage expects
        const s3Path = path.substring('s3:'.length);
        return {
            storage: new CloudStorage(true),
            normalizedPath: s3Path,
            type: 's3',
        };
    } 
    else {
        // Assume local file system for backward compatibility
        console.warn('Storage prefix missing, assuming local file system');
        return {
            storage: new FileStorage(),
            normalizedPath: path,
            type: 'fs',
        };
    }
}
