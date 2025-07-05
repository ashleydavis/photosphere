import { log } from "utils";
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import pc from "picocolors";
import { exit } from "node-utils";
import { configureIfNeeded, getS3Config } from '../lib/config';
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

    const nonInteractive = options.yes || false;

    const { database: sourceDatabase, databaseDir: srcDir } = await loadDatabase(options.db, {
        db: options.db,
        meta: options.meta,
        key: options.key,
        verbose: options.verbose,
        yes: options.yes
    });

    let destDir = options.dest;
    if (destDir === undefined) {
        destDir = await getDirectoryForCommand('existing', nonInteractive);
    }
    
    const destMetaPath = options.destMeta || pathJoin(destDir, '.db');

    if (destDir.startsWith("s3:")) {
        await configureIfNeeded(['s3'], nonInteractive);
    }
    
    if (destMetaPath.startsWith("s3:")) {
        await configureIfNeeded(['s3'], nonInteractive)
    }

    const { options: destStorageOptions, isEncrypted: destIsEncrypted } = await loadEncryptionKeys(options.destKey, options.generateKey || false, "destination");

    const s3Config = await getS3Config();
    const { storage: destAssetStorage } = createStorage(destDir, s3Config, destStorageOptions);        
    const { storage: destMetadataStorage } = createStorage(destMetaPath, s3Config);

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

    log.info(pc.bold(pc.blue(`📊 Replication Results`)));
    log.info('');
    
    log.info(`Total files imported:      ${pc.cyan(result.filesImported.toString())}`);
    log.info(`Total files considered:    ${pc.cyan(result.filesConsidered.toString())}`);
    log.info(`Total files copied:        ${result.copiedFiles > 0 ? pc.green(result.copiedFiles.toString()) : pc.gray('0')}`);
    log.info(`Skipped (unchanged):       ${result.existingFiles > 0 ? pc.yellow(result.existingFiles.toString()) : pc.gray('0')}`);
    
    // If destination is encrypted, copy the public key to the destination .db directory
    if (destIsEncrypted && options.destKey) {
        const publicKeySource = `${options.destKey}.pub`;
        const publicKeyDest = pathJoin(destMetaPath, 'encryption.pub');
        
        try {
            if (await fs.pathExists(publicKeySource)) {
                await fs.copy(publicKeySource, publicKeyDest);
                log.info(pc.green(`✓ Copied public key to destination database directory`));
            }
        } catch (error) {
            console.warn(pc.yellow(`⚠️ Warning: Could not copy public key to destination database directory: ${error instanceof Error ? error.message : 'Unknown error'}`));
        }
    }

    log.info('');
    log.info(pc.green(`✅ Replication completed successfully`));

    log.info('');
    log.info(pc.blue(`💡 Tip: You can run this command again anytime to update your replica when the source database changes.`));

    // Show follow-up commands
    log.info('');
    log.info(pc.bold('Next steps:'));
    log.info(`    ${pc.cyan('psi verify --db')} ${pc.gray(destDir)}         Verify integrity of the replicated database`);
    log.info(`    ${pc.cyan('psi compare --dest')} ${pc.gray(destDir)}      Compare source and destination databases`);
    log.info(`    ${pc.cyan('psi summary --db')} ${pc.gray(destDir)}       View summary of the replicated database`);
    log.info(`    ${pc.cyan('psi ui --db')} ${pc.gray(destDir)}            Open web interface for the replicated database`);

    await exit(0);
}