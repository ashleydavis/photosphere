import { createStorage } from "storage";
import { computeHash } from "api";
import { exit } from "node-utils";
import pc from "picocolors";
import { getS3Config } from '../lib/config';
import { loadEncryptionKeys } from "storage";
import { resolveKeyPaths } from "../lib/init-cmd";
import path from 'node:path';

export interface IHashCommandOptions {
    verbose?: boolean;
    yes?: boolean;
    key?: string;
}

//
// Compute the hash of a file.
//
export async function hashCommand(filePath: string, options: IHashCommandOptions): Promise<void> {
    
    if (!filePath) {
        console.error(pc.red("File path is required."));
        await exit(1);
        return;
    }
    
    // Load S3 configuration if needed
    const s3Config = await getS3Config();

    const resolvedKeyPaths = await resolveKeyPaths(options.key);
    let { options: storageOptions } = await loadEncryptionKeys(resolvedKeyPaths, false);

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