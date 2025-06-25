import { log } from "utils";
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import pc from "picocolors";
import { exit } from "node-utils";
import { configureS3IfNeeded } from '../lib/s3-config';
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import * as fs from 'fs-extra';
import { getDirectoryForCommand } from "../lib/directory-picker";

export interface IReplicateCommandOptions extends IBaseCommandOptions { 
    //
    // Destination directory for replicated database.
    //
    dest?: string;

    //
    // Destination metadata directory override.
    //
    destMeta?: string;

    //
    // Path to destination encryption key file.
    //
    destKey?: string;

    //
    // Generate encryption keys if they don't exist.
    //
    generateKey?: boolean;
}

//
// Command that replicates an asset database from source to destination.
//
export async function replicateCommand(options: IReplicateCommandOptions): Promise<void> {

    const { database: sourceDatabase, databaseDir: srcDir } = await loadDatabase(options.db, {
        db: options.db,
        meta: options.meta,
        key: options.key,
        verbose: options.verbose,
        yes: options.yes
    });

    let destDir = options.dest;
    if (destDir === undefined) {
        destDir = await getDirectoryForCommand('existing', options.yes || false);
    }
    
    // Destination can be new or existing
    const destMetaPath = options.destMeta || pathJoin(destDir, '.db');

    // Configure S3 for destination
    if (!await configureS3IfNeeded(destDir)) {
        await exit(1);
    }
    
    if (!await configureS3IfNeeded(destMetaPath)) {
        await exit(1);
    }

    // Load destination encryption keys
    const { options: destStorageOptions, isEncrypted: destIsEncrypted } = await loadEncryptionKeys(options.destKey, options.generateKey || false, "destination");

    // Create destination storage instances
    const { storage: destAssetStorage } = createStorage(destDir, destStorageOptions);        
    const { storage: destMetadataStorage } = createStorage(destMetaPath);

    log.info('');
    log.info(`Replicating database:`);
    log.info(`  Source:         ${pc.cyan(srcDir)}`);
    log.info(`  Destination:    ${pc.cyan(destDir)}`);
    log.info('');

    writeProgress(`Copying files...`);

    const result = await sourceDatabase.replicate(destAssetStorage, destMetadataStorage, (progress) => {
        const progressMessage = `🔄 ${progress}`;
        writeProgress(progressMessage);
    });

    clearProgressMessage(); // Flush the progress message.

    console.log();
    console.log(pc.bold(pc.blue(`📊 Replication Results`)));
    console.log();
    
    console.log(`Total files imported: ${pc.cyan(result.filesImported.toString())}`);
    console.log(`Total files considered: ${pc.cyan(result.filesConsidered.toString())}`);
    console.log(`Total files copied: ${result.copiedFiles > 0 ? pc.green(result.copiedFiles.toString()) : pc.gray('0')}`);
    console.log(`Skipped (unchanged): ${result.existingFiles > 0 ? pc.yellow(result.existingFiles.toString()) : pc.gray('0')}`);
    
    // If destination is encrypted, copy the public key to the destination .db directory
    if (destIsEncrypted && options.destKey) {
        const publicKeySource = `${options.destKey}.pub`;
        const publicKeyDest = pathJoin(destMetaPath, 'encryption.pub');
        
        try {
            if (await fs.pathExists(publicKeySource)) {
                await fs.copy(publicKeySource, publicKeyDest);
                console.log(pc.green(`✓ Copied public key to destination database directory`));
            }
        } catch (error) {
            console.warn(pc.yellow(`⚠️  Warning: Could not copy public key to destination database directory: ${error instanceof Error ? error.message : 'Unknown error'}`));
        }
    }

    console.log();
    console.log(pc.green(`✅ Replication completed successfully`));

    await exit(0);
}