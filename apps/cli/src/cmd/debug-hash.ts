import { createStorage } from "storage";
import { computeHash } from "adb";
import { exit } from "node-utils";
import pc from "picocolors";
import { getS3Config } from '../lib/config';
import { loadEncryptionKeys } from "storage";
import { resolveKeyPath } from "../lib/init-cmd";
import path from 'node:path';

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

    const dirPath = path.dirname(filePath);  
    const fileName = path.basename(filePath);          
    const { storage, normalizedPath, type } = createStorage(dirPath, s3Config, storageOptions);
    
    if (options.verbose) {
        console.log(pc.cyan(`Storage type: ${type}`));
        console.log(pc.cyan(`Path for storage operations: ${normalizedPath}`));
    }
       
    const fileInfo = await storage.info(fileName);
    if (!fileInfo) {
        console.error(pc.red(`File not found: ${filePath}`));
        await exit(1);
        return;
    }

    const stream = storage.readStream(fileName);
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