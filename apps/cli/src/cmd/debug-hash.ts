import { createStorage } from "storage";
import { computeHash } from "adb";
import { exit } from "node-utils";
import pc from "picocolors";
import { getS3Config } from '../lib/config';
import { loadEncryptionKeys } from "storage";
import { resolveKeyPath } from "../lib/init-cmd";

export interface IDebugHashCommandOptions {
    verbose?: boolean;
    yes?: boolean;
    key?: string;
}

//
// Command to hash a file through the storage abstraction
//
export async function debugHashCommand(filePath: string, options: IDebugHashCommandOptions): Promise<void> {
    
    if (!filePath) {
        console.error(pc.red("File path is required."));
        await exit(1);
        return;
    }
    
    // Load S3 configuration if needed
    const s3Config = await getS3Config();

    let resolvedKeyPath = await resolveKeyPath(options.key);
    let { options: storageOptions } = await loadEncryptionKeys(resolvedKeyPath, false);
            
    // Create storage based on the file path - createStorage now handles file paths directly
    const { storage, normalizedPath, type } = createStorage(filePath, s3Config, storageOptions);
    
    if (options.verbose) {
        console.log(pc.blue(`Storage type: ${type}`));
        console.log(pc.blue(`Path for storage operations: ${normalizedPath}`));
    }
    
    // Check if file exists
    const fileExists = await storage.fileExists(normalizedPath);
    if (!fileExists) {
        console.error(pc.red(`File not found: ${filePath}`));
        await exit(1);
    }
    
    // Get file info for date/time
    const fileInfo = await storage.info(normalizedPath);
    
    // Read file stream and compute hash
    const stream = storage.readStream(normalizedPath);
    const hashBuffer = await computeHash(stream);
    const hashHex = hashBuffer.toString('hex');
    
    // Print results
    console.log(pc.green(`File: ${filePath}`));
    console.log(pc.green(`Hash: ${hashHex}`));
    if (fileInfo) {
        console.log(pc.green(`Date: ${fileInfo.lastModified.toISOString().replace('T', ' ').slice(0, 19)}`));
        console.log(pc.green(`Size: ${fileInfo.length} bytes`));
    }
}