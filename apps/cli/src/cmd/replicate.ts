import { log } from "utils";
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import pc from "picocolors";
import { exit } from "node-utils";
import { configureIfNeeded, getS3Config } from '../lib/config';
import { loadDatabase, IBaseCommandOptions, resolveKeyPath, promptForEncryption, selectEncryptionKey } from "../lib/init-cmd";
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

    //
    // Path to a specific file or directory to replicate (instead of entire database).
    //
    path?: string;
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
    }, false, true);

    let destDir = options.dest;
    if (destDir === undefined) {
        destDir = await getDirectoryForCommand('existing', nonInteractive, options.cwd || process.cwd());
    }
    
    const destMetaPath = options.destMeta || pathJoin(destDir, '.db');

    if (destDir.startsWith("s3:")) {
        await configureIfNeeded(['s3'], nonInteractive);
    }
    
    if (destMetaPath.startsWith("s3:")) {
        await configureIfNeeded(['s3'], nonInteractive);
    }
    
    // Check if destination database already exists
    const s3Config = await getS3Config();
    const { storage: destMetadataStorage } = createStorage(destMetaPath, s3Config);
    const destDbExists = await destMetadataStorage.fileExists('tree.dat');    
    if (destDbExists) {
        // Database already exists - check if it's encrypted
        const destDbIsEncrypted = await destMetadataStorage.fileExists('encryption.pub');
        
        if (destDbIsEncrypted) {
            // Database is encrypted - user must provide a key
            if (!options.destKey) {
                if (nonInteractive) {
                    log.error(pc.red(`✗ The destination database is encrypted and requires a private key to access.`));
                    log.error(pc.red(`  Please provide the private key using the --dest-key option.`));
                    log.error('');
                    log.error(`Example:`);
                    log.error(`    ${pc.cyan(`psi replicate --dest-key my-photos.key --dest ${destDir}`)}`);
                    log.error(`    ${pc.cyan(`psi replicate --dest-key <full or relative path to key> --dest ${destDir}`)}`);
                    await exit(1);
                } else {
                    // Interactive mode - show key selection menu
                    log.info(pc.yellow('The destination database is encrypted and requires a private key to access.'));
                    
                    // Show menu of available keys
                    const selectedKey = await selectEncryptionKey('Select the encryption key for the destination database:');
                    options.destKey = selectedKey;
                }
            }
            
            // Verify the key works by trying to load encryption keys
            const resolvedDestKeyPath = await resolveKeyPath(options.destKey);
            try {
                await loadEncryptionKeys(resolvedDestKeyPath, false);
            } catch (error) {
                log.error(pc.red(`✗ Failed to load encryption key: ${error instanceof Error ? error.message : String(error)}`));
                log.error(pc.red(`  Please check that the key file exists and is valid.`));
                await exit(1);
            }
            
        } else {
            // Database is not encrypted
            if (options.destKey) {
                log.error(pc.red(`✗ You specified an encryption key, but the destination database is not encrypted.`));
                log.error(pc.red(`  Either remove the --dest-key option, or replicate to a different location to create a new encrypted database.`));
                await exit(1);
            }
        }
    } 
    else {
        // Database doesn't exist - ask about encryption if not already specified
        if (!options.destKey && !options.generateKey && !nonInteractive) {
            const encryptionResult = await promptForEncryption('Would you like to encrypt the destination database?');
            
            if (encryptionResult.keyPath) {
                options.destKey = encryptionResult.keyPath;
                options.generateKey = encryptionResult.generateKey || false;
            }
        }
    }

    const resolvedDestKeyPath = await resolveKeyPath(options.destKey);
    const { options: destStorageOptions, isEncrypted: destIsEncrypted } = await loadEncryptionKeys(resolvedDestKeyPath, options.generateKey || false);

    const { storage: destAssetStorage } = createStorage(destDir, s3Config, destStorageOptions);        
    // Re-create destMetadataStorage with proper storage options (in case it's encrypted)
    const { storage: destMetadataStorageFinal } = createStorage(destMetaPath, s3Config);

    log.info('');
    log.info(`Replicating database:`);
    log.info(`  Source:         ${pc.cyan(srcDir)}`);
    log.info(`  Destination:    ${pc.cyan(destDir)}`);
    log.info('');

    writeProgress(options.path 
        ? `Copying files matching: ${options.path}...` 
        : `Copying files...`);

    const result = await sourceDatabase.replicate(destAssetStorage, destMetadataStorageFinal, { 
        pathFilter: options.path 
    }, (progress) => {
        const progressMessage = `🔄 ${progress}`;
        writeProgress(progressMessage);
    });

    clearProgressMessage(); // Flush the progress message.

    log.info(pc.bold(pc.blue(options.path 
        ? `📊 Replication Results (filtered: ${options.path})` 
        : `📊 Replication Results`)));
    log.info('');
    
    log.info(`Total files imported:      ${pc.cyan(result.filesImported.toString())}`);
    log.info(`Total files considered:    ${pc.cyan(result.filesConsidered.toString())}`);
    log.info(`Total files copied:        ${result.copiedFiles > 0 ? pc.green(result.copiedFiles.toString()) : pc.gray('0')}`);
    log.info(`Skipped (unchanged):       ${result.existingFiles > 0 ? pc.yellow(result.existingFiles.toString()) : pc.gray('0')}`);
    
    // If destination is encrypted, copy the public key to the destination .db directory
    if (destIsEncrypted && resolvedDestKeyPath) {
        const publicKeySource = `${resolvedDestKeyPath}.pub`;
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