import { MediaFileDatabase } from "api";
import { createStorage, loadEncryptionKeys, pathJoin } from "storage";
import { configureLog } from "../lib/log";
import { log } from "utils";
import pc from "picocolors";
import { exit, registerTerminationCallback } from "node-utils";
import { configureS3IfNeeded } from '../lib/s3-config';
import { getDirectoryForCommand } from '../lib/directory-picker';
import { ensureMediaProcessingTools } from '../lib/ensure-tools';

export interface IInitCommandOptions { 
    //
    // Set the path to the database metadata.
    //
    meta?: string;

    //
    // Sets the path to private key file for encryption.
    //
    key?: string;

    //
    // Generates the encryption key if it doesn't exist and saves it to the key file.
    // But only if the key file doesn't exist.
    //
    generateKey?: boolean;

    //
    // Enables verbose logging.
    //
    verbose?: boolean;

    //
    // Non-interactive mode - use defaults and command line arguments.
    //
    yes?: boolean;
}

//
// Command that initializes a new Photosphere media file database.
//
export async function initCommand(dbDir: string, options: IInitCommandOptions): Promise<void> {

    configureLog({
        verbose: options.verbose,
    });

    // Ensure required media processing tools are available
    await ensureMediaProcessingTools(options.yes || false);

    // Get the directory for the database (validates it's empty/non-existent)
    const databaseDir = await getDirectoryForCommand('init', dbDir, options.yes || false);
    
    // Set up metadata directory
    const metaPath = options.meta || pathJoin(databaseDir, '.db');

    //
    // Configure S3 if the path requires it
    //
    if (!await configureS3IfNeeded(databaseDir)) {
        await exit(1);
    }
    
    if (!await configureS3IfNeeded(metaPath)) {
        await exit(1);
    }

    // Handle encryption keys
    const { options: storageOptions } = await loadEncryptionKeys(options.key, options.generateKey || false, "source");

    const { storage: assetStorage } = createStorage(databaseDir, storageOptions);        
    const { storage: metadataStorage } = createStorage(metaPath);

    const database = new MediaFileDatabase(assetStorage, metadataStorage, process.env.GOOGLE_API_KEY);

    registerTerminationCallback(async () => {
        await database.close();
    });    

    await database.create(); 

    log.info('');
    log.info(pc.green(`✓ Created new media file database in "${databaseDir}"`));
    log.info('');
    log.info(pc.dim('Your database is ready to receive photos and videos!'));
    log.info('');
    log.info(pc.dim('To get started:'));
    log.info(pc.dim(`  1. ${pc.cyan(`cd ${databaseDir}`)} (change to your database directory)`));
    log.info(pc.dim(`  2. ${pc.cyan(`psi add <source-media-directory>`)} (add your photos and videos)`));
    log.info('');
    log.info(pc.dim(`Or use the full path: ${pc.cyan(`psi add ${databaseDir} <source-media-directory>`)}`));

    await exit(0);
}