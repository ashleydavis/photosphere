import { MediaFileDatabase } from "api";
import { createStorage, loadEncryptionKeys, pathJoin, IStorage } from "storage";
import { configureLog } from "./log";
import { exit, registerTerminationCallback } from "node-utils";
import { log, RandomUuidGenerator } from "utils";
import { TestUuidGenerator } from "node-utils";
import { configureS3IfNeeded } from './s3-config';
import { getDirectoryForCommand } from './directory-picker';
import { ensureMediaProcessingTools } from './ensure-tools';
import * as fs from 'fs-extra';
import pc from "picocolors";

//
// Check if a database is encrypted by looking for the public key file
//
export async function isDatabaseEncrypted(metaPath: string): Promise<boolean> {
    const publicKeyPath = pathJoin(metaPath, 'encryption.pub');
    return await fs.pathExists(publicKeyPath);
}

//
// Common options interface that all commands should extend
//
export interface IBaseCommandOptions {
    //
    // Database directory path.
    //
    db: string;

    //
    // Set the path to the database metadata.
    //
    meta?: string;

    //
    // Sets the path to private key file for encryption.
    //
    key?: string;

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
// Options for creating a new database
//
export interface ICreateCommandOptions extends IBaseCommandOptions {
    //
    // Generates the encryption key if it doesn't exist and saves it to the key file.
    // But only if the key file doesn't exist.
    //
    generateKey?: boolean;
}

//
// Result of the initialization
//
export interface IInitResult {
    //
    // The initialized database instance
    //
    database: MediaFileDatabase;

    //
    // The resolved database directory
    //
    databaseDir: string;

    //
    // The resolved metadata path
    //
    metaPath: string;

    //
    // The asset storage instance
    //
    assetStorage: IStorage;

    //
    // The metadata storage instance
    //
    metadataStorage: IStorage;
}

//
// Shared database loading function for CLI commands
// This handles all the common setup that most commands need:
// - Configure logging
// - Ensure media processing tools
// - Get/validate database directory
// - Configure S3 if needed
// - Load encryption keys
// - Create storage instances
// - Create and load database
// - Register termination callback
//
export async function loadDatabase(dbDir: string, options: IBaseCommandOptions): Promise<IInitResult> {
    
    // Configure logging
    await configureLog({
        verbose: options.verbose
    });
    
    // Log the command being executed
    const command = process.argv.slice(2).join(' ');
    log.verbose(`Executing command: ${command}`);

    // Ensure media processing tools are available
    await ensureMediaProcessingTools(options.yes || false);

    // Get the directory for the database
    const databaseDir = await getDirectoryForCommand("init", dbDir, options.yes || false);
    
    const metaPath = options.meta || pathJoin(databaseDir, '.db');

    // Configure S3 if the paths require it
    if (!await configureS3IfNeeded(databaseDir)) {
        await exit(1);
    }
    
    if (!await configureS3IfNeeded(metaPath)) {
        await exit(1);
    }

    // Check if database is encrypted and require key
    if (await isDatabaseEncrypted(metaPath)) {
        if (!options.key) {
            log.error('');
            log.error(pc.red('✗ This database is encrypted and requires a private key to access.'));
            log.error(pc.red('  Please provide the private key using the --key option.'));
            log.error('');
            log.error(pc.dim('Example:'));
            log.error(pc.dim(`  psi <command> --key /path/to/your/private.key`));
            log.error('');
            await exit(1);
        }
    }

    // Load encryption keys
    const { options: storageOptions } = await loadEncryptionKeys(options.key, false, "source");

    // Create storage instances
    const { storage: assetStorage } = createStorage(databaseDir, storageOptions);        
    const { storage: metadataStorage } = createStorage(metaPath);

    // Create appropriate UUID generator based on NODE_ENV
    const uuidGenerator = process.env.NODE_ENV === "testing" 
        ? new TestUuidGenerator()
        : new RandomUuidGenerator();
        
    // Create database instance
    const database = new MediaFileDatabase(assetStorage, metadataStorage, process.env.GOOGLE_API_KEY, uuidGenerator); 

    // Register termination callback to ensure clean shutdown
    registerTerminationCallback(async () => {
        await database.close();
    });    

    // Load the database
    await database.load();

    return {
        database,
        databaseDir,
        metaPath,
        assetStorage,
        metadataStorage
    };
}

//
// Shared database creation function for CLI commands
// This handles creating a new database with similar setup to loadDatabase
// but uses 'init' directory type and calls database.create() instead of load()
//
export async function createDatabase(dbDir: string, options: ICreateCommandOptions): Promise<IInitResult> {
    
    // Configure logging
    await configureLog({
        verbose: options.verbose
    });
    
    // Log the command being executed
    const command = process.argv.slice(2).join(' ');
    log.verbose(`Executing command: ${command}`);

    // Ensure media processing tools are available
    await ensureMediaProcessingTools(options.yes || false);

    // Get the directory for the database (validates it's empty/non-existent for init)
    const databaseDir = await getDirectoryForCommand('init', dbDir, options.yes || false);
    
    const metaPath = options.meta || pathJoin(databaseDir, '.db');

    // Configure S3 if the paths require it
    if (!await configureS3IfNeeded(databaseDir)) {
        await exit(1);
    }
    
    if (!await configureS3IfNeeded(metaPath)) {
        await exit(1);
    }

    // Load encryption keys (with generateKey support for init)
    const { options: storageOptions, isEncrypted } = await loadEncryptionKeys(options.key, options.generateKey || false, "source");

    // Create storage instances
    const { storage: assetStorage } = createStorage(databaseDir, storageOptions);        
    const { storage: metadataStorage } = createStorage(metaPath);

    // Create appropriate UUID generator based on NODE_ENV
    const uuidGenerator = process.env.NODE_ENV === "testing" 
        ? new TestUuidGenerator()
        : new RandomUuidGenerator();
        
    // Create database instance
    const database = new MediaFileDatabase(assetStorage, metadataStorage, process.env.GOOGLE_API_KEY, uuidGenerator); 

    // Register termination callback to ensure clean shutdown
    registerTerminationCallback(async () => {
        await database.close();
    });    

    // Create the database (instead of loading)
    await database.create();

    // If database is encrypted, copy the public key to the .db directory as a marker
    if (isEncrypted && options.key) {
        const publicKeySource = `${options.key}.pub`;
        const publicKeyDest = pathJoin(metaPath, 'encryption.pub');
        
        try {
            if (await fs.pathExists(publicKeySource)) {
                await fs.copy(publicKeySource, publicKeyDest);
                // console.log(`Copied public key to database directory: ${publicKeyDest}`);
            }
        } catch (error) {
            console.warn(`Warning: Could not copy public key to database directory: ${error instanceof Error ? error.message : 'Unknown error'}`);
        }
    }

    return {
        database,
        databaseDir,
        metaPath,
        assetStorage,
        metadataStorage
    };
}