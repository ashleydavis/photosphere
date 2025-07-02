import { MediaFileDatabase } from "api";
import { createStorage, loadEncryptionKeys, pathJoin, IStorage } from "storage";
import { configureLog } from "./log";
import { exit, registerTerminationCallback } from "node-utils";
import { log, RandomUuidGenerator } from "utils";
import { TestUuidGenerator } from "node-utils";
import { configureIfNeeded, getGoogleApiKey, getS3Config } from './config';
import { getDirectoryForCommand, isEmptyOrNonExistent, isMediaDatabase } from './directory-picker';
import { ensureMediaProcessingTools } from './ensure-tools';
import * as fs from 'fs-extra';
import pc from "picocolors";
import { confirm, text, isCancel, outro, select, note } from '@clack/prompts';
import { pickDirectory } from "../lib/directory-picker";
import { join } from "path";
import { existsSync } from "fs";

//
// Common options interface that all commands should extend
//
export interface IBaseCommandOptions {
    //
    // Database directory path.
    //
    db?: string;

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
export async function loadDatabase(dbDir: string | undefined, options: IBaseCommandOptions): Promise<IInitResult> {

    const nonInteractive = options.yes || false;
    
    // Configure logging
    await configureLog({
        verbose: options.verbose
    });   

    // Ensure media processing tools are available
    await ensureMediaProcessingTools(nonInteractive);

    if (dbDir === undefined) {
        if (await isMediaDatabase(process.cwd())) {
            // If the current directory looks like a media file database, use it.
            dbDir = ".";
        }
        else {           
            dbDir = await getDirectoryForCommand("existing", nonInteractive);
        }
    }
    
    const metaPath = options.meta || pathJoin(dbDir, '.db');

    if (dbDir.startsWith("s3:") && !await configureIfNeeded(['s3'], nonInteractive)) {
        await exit(1);
    }
    
    if (metaPath.startsWith("s3:") && !await configureIfNeeded(['s3'], nonInteractive)) {
        await exit(1);
    }

    const { options: storageOptions } = await loadEncryptionKeys(options.key, false, "source");

    const s3Config = await getS3Config();
    const { storage: assetStorage } = createStorage(dbDir, s3Config, storageOptions);        
    const { storage: metadataStorage } = createStorage(metaPath, s3Config);

    // Make sure the merkle tree file exists.
    if (!await metadataStorage.fileExists('tree.dat')) {
        outro(pc.red(`✗ No database found at: ${pc.cyan(dbDir)}\n  The database directory must contain a ".db" folder with the database metadata.\n\nTo create a new database at this directory, use:\n  ${pc.cyan(`psi init --db ${dbDir}`)}`));
        await exit(1);
    }

    // See if the database is encrypted and requires a key.
    if (await metadataStorage.fileExists('encryption.pub')) {
        if (!options.key) {
            outro(pc.red(`✗ This database is encrypted and requires a private key to access.\n  Please provide the private key using the --key option.\n\nExample:\n  ${pc.cyan(`psi <command> --key /path/to/your/private.key`)}`));
            await exit(1);
        }
    }

    // Create appropriate UUID generator based on NODE_ENV
    const uuidGenerator = process.env.NODE_ENV === "testing" 
        ? new TestUuidGenerator()
        : new RandomUuidGenerator();

    // Get Google API key from config or environment  
    const googleApiKey = await getGoogleApiKey();
        
    // Create database instance
    const database = new MediaFileDatabase(assetStorage, metadataStorage, googleApiKey, uuidGenerator); 

    // Register termination callback to ensure clean shutdown
    registerTerminationCallback(async () => {
        await database.close();
    });    

    // Load the database
    await database.load();

    return {
        database,
        databaseDir: dbDir,
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
export async function createDatabase(dbDir: string | undefined, options: ICreateCommandOptions): Promise<IInitResult> {

    const nonInteractive = options.yes || false;
    
    // Configure logging
    await configureLog({
        verbose: options.verbose
    });
    
    // Log the command being executed
    const command = process.argv.slice(2).join(' ');
    log.verbose(`Executing command: ${command}`);

    // Ensure media processing tools are available
    await ensureMediaProcessingTools(nonInteractive);

    if (dbDir === undefined) {
        // Is the current directory empty?
        if (await isEmptyOrNonExistent(process.cwd())) {
            // If the current directory is empty, use it.
            dbDir = ".";
        }
        else {
            // Get the directory for the database (validates it's empty/non-existent for init)
            dbDir = await getDirectoryForCommand('init', nonInteractive);
        }
    }

    // Check the directory is empty or non-existent.
    if (!isEmptyOrNonExistent(dbDir)) {
        outro(pc.red(`Error: Directory "${dbDir}" is not empty.\nPlease specify an empty directory or non-existent directory, or specify none so I can walk you through it.`));
        await exit(1);
    }

    // Ask about encryption if not already specified
    if (!options.key && !nonInteractive) {
        const wantEncryption = await confirm({
            message: 'Would you like to encrypt your database? (You can say no now and create an encrypted copy later using the replicate command)',
            initialValue: false,
        });

        if (isCancel(wantEncryption)) {
            await exit(1);
        }

        if (wantEncryption) {
            note(pc.yellow('⚠️  To encrypt your database you need a private key that you will have to keep safe and not lose\n   (otherwise you\'ll lose access to your encrypted database)'), 'Encryption Warning');
            
            // Ask how they want to handle the key
            const keyChoice = await select({
                message: 'How would you like to handle the encryption key?',
                options: [
                    { value: 'existing', label: 'Use an existing private key' },
                    { value: 'generate', label: 'Generate a new key and save it to a file' },
                ],
            });

            if (isCancel(keyChoice)) {
                await exit(1);
            }

            if (keyChoice === 'existing') {
                // Ask for existing key file
                const keyDir = await pickDirectory(
                    'Select directory containing your encryption key:',
                    process.cwd(),
                    async (path) => {
                        if (!await fs.exists(path)) {
                            return 'Directory does not exist';
                        }
                        return true;
                    }
                );

                if (!keyDir) {
                    outro(pc.red('No directory selected for encryption key'));
                    await exit(1);
                }

                // Ask for filename
                const keyFilename = await text({
                    message: 'Enter the encryption key filename:',
                    placeholder: 'photosphere.key',
                    validate: (value) => {
                        if (!value || value.trim().length === 0) {
                            return 'Filename is required';
                        }
                        // Check if file exists
                        const keyPath = join(keyDir!, value);
                        if (!existsSync(keyPath)) {
                            return 'File does not exist';
                        }
                        // Check if public key exists
                        const publicKeyPath = `${keyPath}.pub`;
                        if (!existsSync(publicKeyPath)) {
                            return 'Public key file (.pub) not found alongside private key';
                        }
                        return undefined;
                    },
                });

                if (isCancel(keyFilename)) {
                    await exit(1);
                }

                // Set the key path (no generation needed)
                options.key = join(keyDir!, keyFilename as string);
                options.generateKey = false;

                note(pc.green(`✓ Using existing encryption key: ${options.key}`), 'Encryption Key');
            } else if (keyChoice === 'generate') {
                // Generate new key
                // Ask for directory
                const keyDir = await pickDirectory(
                    'Select directory to save encryption key:',
                    process.cwd(),
                    async (path) => {
                        if (!await fs.exists(path)) {
                            return 'Directory does not exist';
                        }
                        return true;
                    }
                );

                if (!keyDir) {
                    outro(pc.red('No directory selected for encryption key'));
                    await exit(1);
                }

                // Ask for filename
                const keyFilename = await text({
                    message: 'Enter filename for encryption key:',
                    placeholder: 'photosphere.key',
                    initialValue: 'photosphere.key',
                    validate: (value) => {
                        if (!value || value.trim().length === 0) {
                            return 'Filename is required';
                        }
                        // Check for invalid characters
                        if (!/^[a-zA-Z0-9._-]+$/.test(value)) {
                            return 'Filename can only contain letters, numbers, dots, hyphens, and underscores';
                        }
                        // Check if file already exists
                        const keyPath = join(keyDir!, value);
                        if (existsSync(keyPath)) {
                            return 'File already exists';
                        }
                        return undefined;
                    },
                });

                if (isCancel(keyFilename)) {
                    await exit(1);
                }

                // Set the key path and enable generation
                options.key = join(keyDir!, keyFilename as string);
                options.generateKey = true;

                note(pc.green(`✓ Encryption key will be generated and saved to: ${options.key}\n`) + pc.yellow(`⚠️  Keep this key file safe! You will need it to access your encrypted database.`), 'Encryption Key Generation');
            }
        }
    }

    const metaPath = options.meta || pathJoin(dbDir, '.db');

    // Configure S3 if the paths require it
    if (dbDir.startsWith("s3:") && !await configureIfNeeded(['s3'], nonInteractive)) {
        await exit(1);
    }
    
    if (metaPath.startsWith("s3:") && !await configureIfNeeded(['s3'], nonInteractive)) {
        await exit(1);
    }

    // Load encryption keys (with generateKey support for init)
    const { options: storageOptions, isEncrypted } = await loadEncryptionKeys(options.key, options.generateKey || false, "source");

    const s3Config = await getS3Config();
    const { storage: assetStorage } = createStorage(dbDir, s3Config, storageOptions);
    const { storage: metadataStorage } = createStorage(metaPath, s3Config);

    // Create appropriate UUID generator based on NODE_ENV
    const uuidGenerator = process.env.NODE_ENV === "testing" 
        ? new TestUuidGenerator()
        : new RandomUuidGenerator();

    // Get Google API key from config or environment  
    const googleApiKey = await getGoogleApiKey();
        
    // Create database instance
    const database = new MediaFileDatabase(assetStorage, metadataStorage, googleApiKey, uuidGenerator); 

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
        databaseDir: dbDir,
        metaPath,
        assetStorage,
        metadataStorage
    };
}

