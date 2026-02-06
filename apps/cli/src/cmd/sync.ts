import { loadDatabase, IBaseCommandOptions, ICommandContext, selectEncryptionKey, resolveKeyPath } from "../lib/init-cmd";
import { getDirectoryForCommand } from "../lib/directory-picker";
import { log } from "utils";
import pc from "picocolors";
import { exit } from "node-utils";
import { syncDatabases, merkleTreeExists, isDatabaseEncrypted, loadDatabaseConfig, updateDatabaseConfig } from "api";
import { createStorage, loadEncryptionKeys } from "storage";
import { configureIfNeeded, getS3Config } from '../lib/config';

//
// Options for the sync command.
//
export interface ISyncCommandOptions extends IBaseCommandOptions {
    //
    // Destination database (optional; defaults to origin from config).
    //
    dest?: string;

    //
    // Path to destination encryption key file.
    //
    destKey?: string;
}

//
// Sync command implementation - synchronizes databases according to the sync specification.
//
export async function syncCommand(context: ICommandContext, options: ISyncCommandOptions): Promise<void> {
    const { uuidGenerator, timestampProvider, sessionId } = context;

    const nonInteractive = options.yes || false;

    // Load source database first so we can read origin if --dest not provided
    const { assetStorage: sourceAssetStorage, metadataStorage: sourceMetadataStorage, bsonDatabase: sourceBsonDatabase } = await loadDatabase(options.db, {
        db: options.db,
        key: options.key,
        verbose: options.verbose,
        yes: options.yes
    }, uuidGenerator, timestampProvider, sessionId);

    let destPath = options.dest;
    if (destPath === undefined) {
        const config = await loadDatabaseConfig(sourceMetadataStorage);
        destPath = config?.origin;
        if (destPath === undefined) {
            destPath = await getDirectoryForCommand('existing', nonInteractive, options.cwd || process.cwd());
        }
    }

    log.info("Starting database sync operation...");
    log.info(`  Source:    ${pc.cyan(options.db || ".")}`);
    log.info(`  Target:    ${pc.cyan(destPath)}`);
    log.info("");

    // Check if destination database exists and handle encryption (storage scoped to db root, paths use .db/...)
    if (destPath.startsWith("s3:")) {
        await configureIfNeeded(['s3'], nonInteractive);
    }

    const s3Config = await getS3Config();
    const { storage: destMetadataStorage } = createStorage(destPath, s3Config);

    // Check if destination database exists (uses .db/files.dat from API)
    const destDbExists = await merkleTreeExists(destMetadataStorage);    
    if (destDbExists) {
        // Database exists - check if it's encrypted
        const destDbIsEncrypted = await isDatabaseEncrypted(destMetadataStorage);        
        if (destDbIsEncrypted) {
            // Database is encrypted - user must provide a key
            if (!options.destKey) {
                if (nonInteractive) {
                    log.error(pc.red(`✗ The destination database is encrypted and requires a private key to access.`));
                    log.error(pc.red(`  Please provide the private key using the --dest-key option.`));
                    log.error('');
                    log.error(`Example:`);
                    log.error(`    ${pc.cyan(`psi sync --dest-key my-photos.key --dest ${destPath}`)}`);
                    log.error(`    ${pc.cyan(`psi sync --dest-key <full or relative path to key> --dest ${destPath}`)}`);
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
                log.error(pc.red(`  Either remove the --dest-key option, or sync to a different location.`));
                await exit(1);
            }
        }
    }

    // Load target database with target options (using destKey instead of key)
    const targetOptions = {
        ...options,
        db: destPath,
        key: options.destKey  // Use destKey for target database
    };
    const { assetStorage: targetAssetStorage, metadataStorage: targetMetadataStorage, bsonDatabase: targetBsonDatabase } = await loadDatabase(targetOptions.db, targetOptions, uuidGenerator, timestampProvider, sessionId);

    await syncDatabases(sourceAssetStorage, sourceMetadataStorage, sourceBsonDatabase, sessionId, targetAssetStorage, targetMetadataStorage, targetBsonDatabase, sessionId);

    const lastSyncedAt = new Date().toISOString();
    await updateDatabaseConfig(sourceMetadataStorage, { lastSyncedAt });
    await updateDatabaseConfig(targetMetadataStorage, { lastSyncedAt });

    log.info("Sync completed successfully!");

    await exit(0);
}

