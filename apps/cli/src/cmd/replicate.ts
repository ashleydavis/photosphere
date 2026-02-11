import { log } from "utils";
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import pc from "picocolors";
import { exit } from "node-utils";
import { configureIfNeeded, getS3Config } from '../lib/config';
import { loadDatabase, IBaseCommandOptions, resolveKeyPath, promptForEncryption, selectEncryptionKey, ICommandContext } from "../lib/init-cmd";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import * as fs from 'fs/promises';
import { pathExists, copy } from 'node-utils';
import { getDirectoryForCommand } from "../lib/directory-picker";
import { replicate } from "api";
import { confirm, isCancel } from '../lib/clack/prompts';

export interface IReplicateCommandOptions extends IBaseCommandOptions { 
    //
    // Destination directory for replicated database.
    //
    dest?: string;

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

    //
    // If true, allows replication even if destination has modifications not in source.
    //
    force?: boolean;

    //
    // If true, only copy thumb directory assets. Asset and display files will be lazily copied when needed.
    //
    partial?: boolean;
}

//
// Command that replicates an asset database from source to destination.
//
export async function replicateCommand(context: ICommandContext, options: IReplicateCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;

    const nonInteractive = options.yes || false;

    const { assetStorage: sourceAssetStorage, metadataStorage: sourceMetadataStorage, bsonDatabase: sourceBsonDatabase, databaseDir: srcDir } = await loadDatabase(options.db, {
        db: options.db,
        key: options.key,
        verbose: options.verbose,
        yes: options.yes
    }, false, uuidGenerator, timestampProvider, sessionId);

    let destDir = options.dest;
    if (destDir === undefined) {
        destDir = await getDirectoryForCommand('existing', nonInteractive, options.cwd || process.cwd());
    }
    
    const destMetaPath = pathJoin(destDir, '.db');

    if (destDir.startsWith("s3:")) {
        await configureIfNeeded(['s3'], nonInteractive);
    }
    
    if (destMetaPath.startsWith("s3:")) {
        await configureIfNeeded(['s3'], nonInteractive);
    }
    
    // Check if destination database already exists
    const s3Config = await getS3Config();
    const { storage: destMetadataStorage } = createStorage(destDir, s3Config, undefined);

    // Check for tree.dat in device-specific location first, then old location
    let destDbExists = await destMetadataStorage.fileExists(".db/tree.dat");    
    if (destDbExists) {
        // Database already exists - check if it's encrypted
        const destDbIsEncrypted = await destMetadataStorage.fileExists('.db/encryption.pub');        
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

    // If destination database exists, warn user and ask for confirmation (unless --ues is used)
    if (destDbExists && !options.yes) {
        if (nonInteractive) {
            log.error(pc.red(`✗ The destination database already exists at ${destDir}.`));
            log.error(pc.red(`  Replication will overwrite any changes made to the destination database.`));
            log.error(pc.red(`  Use the --force flag to proceed without confirmation.`));
            await exit(1);
        } 
        else {
            log.warn(pc.yellow(`⚠️  The destination database already exists at ${destDir}.`));
            log.warn(pc.yellow(`    Replication will overwrite any changes made to the destination database.`));
            log.info('');
            
            const confirmed = await confirm({
                message: 
                    `Do you want to proceed with replication?\n` +
                    `   This will cause the destination database to be updated to match the source database.\n` +
                    `   Any changes you have made separately to the destination database will be overwritten.\n` +
                    `   If you have made changes to the source and destination databases separately you should use the sync command instead.`,
                initialValue: false,
            });

            if (isCancel(confirmed) || !confirmed) {
                log.info('Replication cancelled.');
                await exit(0);
                return;
            }
        }
    }

    log.info('');
    log.info(`Replicating database:`);
    log.info(`  Source:         ${pc.cyan(srcDir)}`);
    log.info(`  Destination:    ${pc.cyan(destDir)}`);
    log.info('');

    writeProgress(options.path 
        ? `Copying files matching: ${options.path}...` 
        : `Copying files...`);

    const result = await replicate(sourceAssetStorage, sourceMetadataStorage, sourceBsonDatabase, uuidGenerator, timestampProvider, destAssetStorage, destMetadataStorage, { 
        pathFilter: options.path,
        force: options.force,
        partial: options.partial
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
    log.info(`Total files copied:        ${result.copiedFiles > 0 ? pc.green(result.copiedFiles.toString()) : '0'}`);
    log.info('');
    log.info(`Total records copied:      ${result.copiedRecords > 0 ? pc.green(result.copiedRecords.toString()) : '0'}`);
    
    // Print pruned files if any
    if (result.prunedFiles.length > 0) {
        log.info('');
        log.info(`Files pruned from destination: ${pc.red(result.prunedFiles.length.toString())}`);
        for (const fileName of result.prunedFiles) {
            log.info(`  ${pc.red('✗')} ${fileName}`);
        }
    }
    
    // If destination is encrypted, copy the public key to the destination .db directory
    if (destIsEncrypted && resolvedDestKeyPath) {
        const publicKeySource = `${resolvedDestKeyPath}.pub`;
        const publicKeyDest = pathJoin(destMetaPath, 'encryption.pub');
        
        try {
            if (await pathExists(publicKeySource)) {
                await copy(publicKeySource, publicKeyDest);
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
    log.info(`    # Verify the integrity of the replicated database`);
    log.info(`    psi verify --db ${destDir}`);
    log.info('');
    log.info(`    # Compare source and destination databases`);
    log.info(`    psi compare --db ${srcDir} --dest ${destDir}`);
    log.info('');
    log.info(`    # Synchronize changes between two databases that have been independently changed`);
    log.info(`    psi sync --db ${srcDir} --dest ${destDir}`);
    log.info('');
    log.info(`    # View summary of the replicated database`);
    log.info(`    psi summary --db ${destDir}`);

    await exit(0);
}