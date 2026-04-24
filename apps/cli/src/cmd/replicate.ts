import { log } from "utils";
import { createStorage, loadEncryptionKeysFromPem, pathJoin, generateKeyPair, exportPublicKeyToPem } from "storage";
import pc from "picocolors";
import { exit } from "node-utils";
import { loadDatabase, IBaseCommandOptions, resolveKeyPems, promptForEncryption, selectEncryptionKey, ICommandContext, configureS3IfNeeded, getDefaultS3Config } from "../lib/init-cmd";
import { getVault, getDefaultVaultType } from "vault";
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { getDirectoryForCommand } from "../lib/directory-picker";
import { replicate, merkleTreeExists, loadDatabaseConfig, updateDatabaseConfig } from "api";
import { confirm, select, isCancel } from '../lib/clack/prompts';

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

    //
    // If true, perform a full replication (copies all asset, display, and thumb files).
    //
    full?: boolean;
}

//
// Command that replicates an asset database from source to destination.
//
export async function replicateCommand(context: ICommandContext, options: IReplicateCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;

    const nonInteractive = options.yes || false;

    if (options.partial && options.full) {
        log.error(pc.red(`✗ --partial and --full cannot be used together. Please specify only one.`));
        await exit(1);
        return;
    }

    const { assetStorage: sourceAssetStorage, rawAssetStorage: sourceRawAssetStorage, bsonDatabase: sourceBsonDatabase, databaseDir: srcDir } = await loadDatabase(options.db, {
        db: options.db,
        key: options.key,
        verbose: options.verbose,
        yes: options.yes
    }, uuidGenerator, timestampProvider, sessionId);

    let destDir = options.dest;
    if (destDir === undefined) {
        const config = await loadDatabaseConfig(sourceRawAssetStorage);
        destDir = config?.origin;
        if (destDir === undefined) {
            destDir = await getDirectoryForCommand('existing', nonInteractive, options.cwd || process.cwd());
        }
    }
    
    //
    // If neither --partial nor --full was specified, prompt the user to choose.
    // In non-interactive (--yes) mode, default to full replication.
    //
    if (!options.partial && !options.full) {
        if (nonInteractive) {
            options.full = true;
        }
        else {
            const mode = await select({
                message: 'How would you like to replicate the database?',
                options: [
                    {
                        value: 'full',
                        label: 'Full',
                        hint: 'Copy everything — all original, display, and thumbnail files',
                    },
                    {
                        value: 'partial',
                        label: 'Partial',
                        hint: 'Copy only metadata and structure; asset files are fetched on demand from origin',
                    },
                ],
            });

            if (isCancel(mode)) {
                log.info('Replication cancelled.');
                await exit(0);
                return;
            }

            options.partial = mode === 'partial';
            options.full = mode === 'full';
        }
    }

    const destMetaPath = pathJoin(destDir, '.db');

    if (destDir.startsWith("s3:") || destMetaPath.startsWith("s3:")) {
        await configureS3IfNeeded(nonInteractive);
    }

    // Check if destination database already exists (using plain metadata probe storage)
    const s3Config = await getDefaultS3Config();
    const { storage: destMetadataProbeStorage } = createStorage(destDir, s3Config, undefined);

    // Check if destination database already has a files tree
    let destDbExists = await merkleTreeExists(destMetadataProbeStorage);    
    if (destDbExists) {
        // Database already exists - check if it's encrypted
        const destDbIsEncrypted = await destMetadataProbeStorage.fileExists('.db/encryption.pub');        
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
            const verifyKeyPems = await resolveKeyPems(options.destKey);
            try {
                await loadEncryptionKeysFromPem(verifyKeyPems);
            } catch (error) {
                log.error(pc.red(`✗ Failed to load encryption key: ${error instanceof Error ? error.message : String(error)}`));
                log.error(pc.red(`  Please check that the key exists. Use "psi secrets list" to see available keys.`));
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

            if (encryptionResult.keyName) {
                options.destKey = encryptionResult.keyName;
                options.generateKey = encryptionResult.generateKey || false;
            }
        }
    }

    // If --generate-key is set, generate the dest key in the vault if it doesn't exist yet.
    if (options.generateKey && options.destKey) {
        const vault = getVault(getDefaultVaultType());
        const existing = await vault.get(options.destKey);
        if (!existing) {
            const keyPair = generateKeyPair();
            const privateKeyPem = keyPair.privateKey.export({ type: 'pkcs8', format: 'pem' }) as string;
            await vault.set({
                name: options.destKey,
                type: 'encryption-key',
                value: privateKeyPem,
            });
        }
    }

    const destKeyPems = await resolveKeyPems(options.destKey);
    const { options: destStorageOptions, isEncrypted: destIsEncrypted } = await loadEncryptionKeysFromPem(destKeyPems);
    const { storage: destAssetStorage, rawStorage: destRawStorage } = createStorage(destDir, s3Config, destStorageOptions);

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

    const result = await replicate(sourceAssetStorage, sourceBsonDatabase, uuidGenerator, timestampProvider, destAssetStorage, destRawStorage, {
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
    
    // If destination is encrypted, write the public key PEM to the destination .db directory
    if (destIsEncrypted && destKeyPems.length > 0) {
        try {
            await destRawStorage.write('.db/encryption.pub', undefined, Buffer.from(destKeyPems[0].publicKeyPem, 'utf-8'));
            log.info(pc.green(`✓ Wrote public key to destination database directory`));
        } catch (error) {
            log.warn(pc.yellow(`⚠️ Warning: Could not write public key to destination database directory: ${error instanceof Error ? error.message : 'Unknown error'}`));
        }
    }

    // Set replica config: origin = source path, lastReplicatedAt = now
    await updateDatabaseConfig(destRawStorage, {
        origin: srcDir,
        lastReplicatedAt: new Date().toISOString(),
    });

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