import { MediaFileDatabase } from "api";
import { createStorage, loadEncryptionKeys, pathJoin, IStorage } from "storage";
import { configureLog } from "./log";
import { exit, registerTerminationCallback, TestUuidGenerator, TestTimestampProvider } from "node-utils";
import { log, RandomUuidGenerator, TimestampProvider } from "utils";
import { configureIfNeeded, getGoogleApiKey, getS3Config } from './config';
import { getDirectoryForCommand } from './directory-picker';
import { ensureMediaProcessingTools } from './ensure-tools';
import * as fs from 'fs-extra';
import * as os from 'os';
import pc from "picocolors";
import { confirm, text, isCancel, outro, select } from './clack/prompts';
import { pickDirectory } from "../lib/directory-picker";
import { join } from "path";

//
// Helper function to resolve encryption key path
// If the key path doesn't contain path separators, check ~/.config/photosphere/keys/ first, then current directory
//
export async function resolveKeyPath(keyPath: string | undefined): Promise<string | undefined> {
    if (!keyPath) {
        return undefined;
    }
    
    // If the path contains separators, use it as-is (absolute or relative path)
    if (keyPath.includes('/') || keyPath.includes('\\')) {
        return keyPath;
    }
    
    // For filenames only, check ~/.config/photosphere/keys/ first
    const keysDir = join(os.homedir(), '.config', 'photosphere', 'keys');
    const keysPath = join(keysDir, keyPath);
    
    if (await fs.pathExists(keysPath)) {
        return keysPath;
    }
    
    // If not found in keys directory, use current directory
    return keyPath;
}

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
    // Enables tool output logging.
    //
    tools?: boolean;

    //
    // Non-interactive mode - use defaults and command line arguments.
    //
    yes?: boolean;

    //
    // Set the current working directory for directory selection prompts.
    //
    cwd?: string;
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
        verbose: options.verbose,
        tools: options.tools
    });   

    // Ensure media processing tools are available
    await ensureMediaProcessingTools(nonInteractive);

    if (dbDir === undefined) {
        dbDir = await getDirectoryForCommand("existing", nonInteractive, options.cwd || process.cwd());
    }
    
    const metaPath = options.meta || pathJoin(dbDir, '.db');

    if (dbDir.startsWith("s3:")) {
        await configureIfNeeded(['s3'], nonInteractive);
    }
    
    if (metaPath.startsWith("s3:")) {
        await configureIfNeeded(['s3'], nonInteractive);
    }

    const resolvedKeyPath = await resolveKeyPath(options.key);
    const { options: storageOptions } = await loadEncryptionKeys(resolvedKeyPath, false);

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
        if (!resolvedKeyPath) {
            outro(pc.red(`✗ This database is encrypted and requires a private key to access.\n  Please provide the private key using the --key option.\n\nExample:\n    ${pc.cyan(`psi <command> --key /path/to/your/private.key`)}\n    ${pc.cyan(`psi <command> --key your-key-filename.key`)}`));
            await exit(1);
        }
    }

    // Create appropriate providers based on NODE_ENV
    const uuidGenerator = process.env.NODE_ENV === "testing" 
        ? new TestUuidGenerator()
        : new RandomUuidGenerator();
    const timestampProvider = process.env.NODE_ENV === "testing"
        ? new TestTimestampProvider()
        : new TimestampProvider();
    
    // Test providers are automatically configured when NODE_ENV === "testing"

    // Get Google API key from config or environment  
    const googleApiKey = await getGoogleApiKey();
        
    // Create database instance
    const database = new MediaFileDatabase(assetStorage, metadataStorage, googleApiKey, uuidGenerator, timestampProvider); 

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
        verbose: options.verbose,
        tools: options.tools
    });
    
    // Log the command being executed
    const command = process.argv.slice(2).join(' ');
    log.verbose(`Executing command: ${command}`);

    // Ensure media processing tools are available
    await ensureMediaProcessingTools(nonInteractive);

    if (dbDir === undefined) {
        // Get the directory for the database (validates it's empty/non-existent for init)
        dbDir = await getDirectoryForCommand('init', nonInteractive, options.cwd || process.cwd());
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
            log.info(pc.yellow('\n⚠️ To encrypt your database you need a private key that you will have to keep safe and not lose\n   (otherwise you\'ll lose access to your encrypted database)'));
            
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
                // Look for existing keys in ~/.config/photosphere/keys
                const keysDir = join(os.homedir(), '.config', 'photosphere', 'keys');
                
                let keyFiles: string[] = [];
                if (await fs.pathExists(keysDir)) {
                    const allFiles = await fs.readdir(keysDir);
                    // Filter for .key files that have corresponding .pub files
                    keyFiles = allFiles
                        .filter(file => file.endsWith('.key'))
                        .filter(file => {
                            const publicKeyPath = join(keysDir, `${file}.pub`);
                            return fs.existsSync(publicKeyPath);
                        });
                }

                if (keyFiles.length === 0) {
                    outro(pc.red('No encryption keys found in ~/.config/photosphere/keys/\n  Please generate a new key or place your existing key files in this directory.'));
                    await exit(1);
                }

                // Show menu of available keys
                const selectedKey = await select({
                    message: 'Select an encryption key:',
                    options: keyFiles.map(file => ({
                        value: file,
                        label: file
                    })),
                });

                if (isCancel(selectedKey)) {
                    await exit(1);
                }

                // Set the key path (no generation needed)
                options.key = selectedKey as string;
                options.generateKey = false;
            } else if (keyChoice === 'generate') {
                // Generate new key - save in ~/.config/photosphere/keys directory
                const keysDir = join(os.homedir(), '.config', 'photosphere', 'keys');
                
                // Ensure the ~/.config/photosphere/keys directory exists
                await fs.ensureDir(keysDir);

                // Ask for filename
                const keyFilename = await text({
                    message: 'Enter filename for encryption key:',
                    placeholder: 'my-photos.key',
                    initialValue: 'my-photos.key',
                    validate: (value) => {
                        if (!value || value.trim().length === 0) {
                            return 'Filename is required';
                        }
                        // Check for invalid characters
                        if (!/^[a-zA-Z0-9._-]+$/.test(value)) {
                            return 'Filename can only contain letters, numbers, dots, hyphens, and underscores';
                        }
                        // Check if file already exists
                        const keyPath = join(keysDir, value);
                        if (fs.existsSync(keyPath)) {
                            return 'File already exists';
                        }
                        return undefined;
                    },
                });

                if (isCancel(keyFilename)) {
                    await exit(1);
                }

                // Set the key path and enable generation
                options.key = join(keysDir, keyFilename as string);
                options.generateKey = true;
            }
        }
    }

    const metaPath = options.meta || pathJoin(dbDir, '.db');

    // Configure S3 if the paths require it
    if (dbDir.startsWith("s3:")) {
        await configureIfNeeded(['s3'], nonInteractive);
    }
    
    if (metaPath.startsWith("s3:")) {
        await configureIfNeeded(['s3'], nonInteractive);
    }

    // Load encryption keys (with generateKey support for init)
    const resolvedKeyPath = await resolveKeyPath(options.key);
    const { options: storageOptions, isEncrypted } = await loadEncryptionKeys(resolvedKeyPath, options.generateKey || false);

    const s3Config = await getS3Config();
    const { storage: assetStorage } = createStorage(dbDir, s3Config, storageOptions);
    const { storage: metadataStorage } = createStorage(metaPath, s3Config);

    // Check the requested directory is empty or non-existent using the storage interface. 
    if (!await assetStorage.isEmpty("/")) {
        outro(pc.red(`✗ The directory ${pc.cyan(dbDir)} is not empty or already contains a database.\n  Please choose an empty directory or a non-existent one.`));
        await exit(1);
    }

    if (!await metadataStorage.isEmpty("/")) {
        outro(pc.red(`✗ The metadata directory ${pc.cyan(metaPath)} is not empty or already contains a database.\n  Please choose an empty directory or a non-existent one.`));
        await exit(1);
    }

    // Create appropriate providers based on NODE_ENV
    const uuidGenerator = process.env.NODE_ENV === "testing" 
        ? new TestUuidGenerator()
        : new RandomUuidGenerator();
    const timestampProvider = process.env.NODE_ENV === "testing"
        ? new TestTimestampProvider()
        : new TimestampProvider();
    
    // Test providers are automatically configured when NODE_ENV === "testing"

    // Get Google API key from config or environment  
    const googleApiKey = await getGoogleApiKey();
        
    // Create database instance
    const database = new MediaFileDatabase(assetStorage, metadataStorage, googleApiKey, uuidGenerator, timestampProvider); 

    // Register termination callback to ensure clean shutdown
    registerTerminationCallback(async () => {
        await database.close();
    });    

    // Create the database (instead of loading)
    await database.create();

    // If database is encrypted, copy the public key to the .db directory as a marker
    if (isEncrypted && resolvedKeyPath) {
        const publicKeySource = `${resolvedKeyPath}.pub`;
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

