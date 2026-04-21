import { createStorage, loadEncryptionKeysFromPem } from "storage";
import { computeHash } from "api";
import { exit } from "node-utils";
import pc from "picocolors";
import { resolveKeyPems, configureS3IfNeeded, getDefaultS3Config } from "../lib/init-cmd";
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
    
    if (filePath.startsWith("s3:")) {
        await configureS3IfNeeded(options.yes ?? false);
    }

    const s3Config = await getDefaultS3Config();

    const keyPems = await resolveKeyPems(options.key);
    let { options: storageOptions } = await loadEncryptionKeysFromPem(keyPems);

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

    const stream = await storage.readStream(fileName);
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