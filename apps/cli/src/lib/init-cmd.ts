import { createMediaFileDatabase, loadDatabase as loadMediaDatabase, createDatabase as createMediaDatabase, FileScanner } from "api";
import { createStorage, loadEncryptionKeys, pathJoin, IStorage } from "storage";
import type { BsonDatabase, IBsonCollection } from "bdb";
import type { IUuidGenerator, ITimestampProvider } from "utils";
import type { IAsset } from "defs";
import type { ITaskQueueProvider } from "api";
import { TaskQueueProvider } from "./task-queue-provider";
import { configureLog } from "./log";
import { exit, TestUuidGenerator, TestTimestampProvider } from "node-utils";
import { log, RandomUuidGenerator, TimestampProvider } from "utils";
import { configureIfNeeded, getS3Config } from './config';
import { getDirectoryForCommand } from './directory-picker';
import { ensureMediaProcessingTools } from './ensure-tools';
import * as fs from 'fs-extra';
import * as os from 'os';
import pc from "picocolors";
import { confirm, text, isCancel, outro, select } from './clack/prompts';
import { join } from "path";
import { CURRENT_DATABASE_VERSION, loadTreeVersion } from "merkle-tree";

//
// Helper function to get available encryption keys from the keys directory
//
export async function getAvailableKeys(): Promise<string[]> {
    const keysDir = join(os.homedir(), '.config', 'photosphere', 'keys');
    
    if (!await fs.pathExists(keysDir)) {
        return [];
    }
    
    const allFiles = await fs.readdir(keysDir);
    // Filter for .key files (private keys are all we need)
    return allFiles
        .filter(file => file.endsWith('.key'));
}

//
// Helper function to show key selection menu
//
export async function selectEncryptionKey(message: string): Promise<string> {
    const keyFiles = await getAvailableKeys();
    
    if (keyFiles.length === 0) {
        outro(pc.red('✗ No encryption keys found in ~/.config/photosphere/keys/\n  Please provide the private key using the --key option or place your key files in the keys directory.'));
        await exit(1);
    }

    // Show menu of available keys
    const selectedKey = await select({
        message,
        options: keyFiles.map(file => ({
            value: file,
            label: file
        })),
    });

    if (isCancel(selectedKey)) {
        await exit(1);
    }

    return selectedKey as string;
}

//
// Result of encryption prompting
//
export interface IEncryptionPromptResult {
    keyPath?: string;
    generateKey?: boolean;
}

//
// Shared function to prompt for encryption settings
// Returns the key path and whether to generate a new key
//
export async function promptForEncryption(message: string = 'Would you like to encrypt your database?'): Promise<IEncryptionPromptResult> {
    const wantEncryption = await confirm({
        message,
        initialValue: false,
    });

    if (isCancel(wantEncryption)) {
        await exit(1);
    }

    if (!wantEncryption) {
        return {};
    }

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
        // Show menu of available keys
        const selectedKey = await selectEncryptionKey('Select an encryption key:');
        
        return {
            keyPath: selectedKey,
            generateKey: false
        };
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

        return {
            keyPath: join(keysDir, keyFilename as string),
            generateKey: true
        };
    }

    return {};
}

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

    //
    // Session identifier for write lock tracking.
    //
    sessionId?: string;

    //
    // Number of worker threads to use for parallel processing.
    // Supported by commands that use the task queue (e.g., verify).
    //
    workers?: number;

    //
    // Task timeout in milliseconds.
    // Supported by commands that use the task queue (e.g., verify).
    // Defaults to 10 minutes (600000ms).
    //
    timeout?: number;
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
// Common dependencies injected into CLI commands.
//
export interface ICommandContext {
    uuidGenerator: IUuidGenerator;
    timestampProvider: ITimestampProvider;
    sessionId: string;
    taskQueueProvider: ITaskQueueProvider;
}

//
// Wraps a command function to inject common dependencies.
//
export function initContext<TArgs extends any[], TReturn>(
    command: (context: ICommandContext, ...args: TArgs) => Promise<TReturn>
): (...args: TArgs) => Promise<TReturn> {
    return async (...args: TArgs): Promise<TReturn> => {
        // Extract options from args - commander.js passes (args..., options, command)
        // So options is always the second-to-last argument
        const options = args[args.length - 2] as IBaseCommandOptions;
        
        // Configure logging
        await configureLog({
            verbose: options.verbose,
            tools: options.tools
        });        
        
        // Test providers are automatically configured when NODE_ENV === "testing"
        const uuidGenerator = process.env.NODE_ENV === "testing" 
            ? new TestUuidGenerator()
            : new RandomUuidGenerator();
        const timestampProvider = process.env.NODE_ENV === "testing"
            ? new TestTimestampProvider()
            : new TimestampProvider();
        const sessionId = options.sessionId || uuidGenerator.generate();
        // TaskQueueProvider defaults to number of CPUs if not specified
        // Check if command supports --workers and --timeout options and use them if provided
        const workers = options.workers;
        const timeout = options.timeout;
        const taskQueueProvider = new TaskQueueProvider(workers, timeout);
        
        const context: ICommandContext = {
            uuidGenerator,
            timestampProvider,
            sessionId,
            taskQueueProvider,
        };
        
        return command(context, ...args);
    };
}

//
// Result of the initialization
//
export interface IInitResult {
    //
    // The resolved database directory
    //
    databaseDir: string;
    
    //
    // Individual database dependencies
    //
    assetStorage: IStorage;
    bsonDatabase: BsonDatabase;
    sessionId: string;
    metadataCollection: IBsonCollection<IAsset>;
    localFileScanner: FileScanner;

    //
    // The resolved metadata path
    //
    metaPath: string;
}

//
// Shared database loading function for CLI commands.
//
export async function loadDatabase(
    dbDir: string | undefined, 
    options: IBaseCommandOptions, 
    allowOlderVersions: boolean,
    uuidGenerator: IUuidGenerator,
    timestampProvider: ITimestampProvider,
    sessionId: string
): Promise<IInitResult> { //todo: Move into api.

    const nonInteractive = options.yes || false;

    // Ensure media processing tools are available
    await ensureMediaProcessingTools(nonInteractive);

    if (dbDir === undefined) {
        dbDir = await getDirectoryForCommand("existing", nonInteractive, options.cwd || process.cwd());
    }
    
    const metaPath = pathJoin(dbDir, '.db');

    if (dbDir.startsWith("s3:")) {
        await configureIfNeeded(['s3'], nonInteractive);
    }
    
    if (metaPath.startsWith("s3:")) {
        await configureIfNeeded(['s3'], nonInteractive);
    }

    let resolvedKeyPath = await resolveKeyPath(options.key);
    let { options: storageOptions } = await loadEncryptionKeys(resolvedKeyPath, false);

    const s3Config = await getS3Config();
    let { storage: assetStorage } = createStorage(dbDir, s3Config, storageOptions);        

    //
    // Check that tree.dat exists.
    //
    if (!await assetStorage.fileExists(".db/tree.dat")) {
        outro(pc.red(`✗ No database found at: ${pc.cyan(dbDir)}\n  The database directory must contain a ".db" folder with the database metadata.\n\nTo create a new database at this directory, use:\n  ${pc.cyan(`psi init --db ${dbDir}`)}`));
        await exit(1);
    }

    if (!allowOlderVersions) {
        //
        // When trying to load the database and we don't allow older versions,
        // quickly load the version from the database and reject if the database is old.
        //
        
        let databaseVersion = await loadTreeVersion(".db/tree.dat", assetStorage);        
        if (databaseVersion && databaseVersion < CURRENT_DATABASE_VERSION) {
            outro(pc.red(`✗ Database version ${databaseVersion} is outdated. Current version is ${CURRENT_DATABASE_VERSION}. Please run 'psi upgrade' to upgrade your database.`));
            await exit(1);
        }
    }    

    //
    // See if the database is encrypted and requires a key.
    //
    if (await assetStorage.fileExists('.db/encryption.pub')) {
        if (!resolvedKeyPath) {
            if (nonInteractive) {
                outro(pc.red(`✗ This database is encrypted and requires a private key to access.\n  Please provide the private key using the --key option.\n\nExample:\n    ${pc.cyan(`psi <command> --key my-photos.key`)}\n    ${pc.cyan(`psi <command> --key <full or relative path to key>`)}`));
                await exit(1);
            } else {
                // Interactive mode - show key selection menu
                log.info(pc.yellow('This database is encrypted and requires a private key to access.'));
                
                // Show menu of available keys
                const selectedKey = await selectEncryptionKey('Select the encryption key for this database:');
                
                // Resolve the selected key path and reload encryption keys
                options.key = selectedKey;
                resolvedKeyPath = await resolveKeyPath(options.key);
                const { options: newStorageOptions } = await loadEncryptionKeys(resolvedKeyPath, false);
                storageOptions = newStorageOptions;
                
                // Recreate storage with the new encryption options
                const { storage: newAssetStorage } = createStorage(dbDir, s3Config, storageOptions);        
                assetStorage = newAssetStorage;
            }
        }
    }

    // Create database instance.
    const database = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);

    // Load the database
    await loadMediaDatabase(database.assetStorage, database.metadataCollection);

    return {
        databaseDir: dbDir,
        metaPath,
        assetStorage: database.assetStorage,
        bsonDatabase: database.bsonDatabase,
        sessionId,
        metadataCollection: database.metadataCollection,
        localFileScanner: database.localFileScanner,
    };
}

//
// Shared database creation function for CLI commands
// This handles creating a new database with similar setup to loadDatabase
// but uses 'init' directory type and calls database.create() instead of load()
//
export async function createDatabase(
    dbDir: string | undefined, 
    options: ICreateCommandOptions,
    uuidGenerator: IUuidGenerator,
    timestampProvider: ITimestampProvider,
    sessionId: string
): Promise<IInitResult> { //todo: Move into api.

    const nonInteractive = options.yes || false;
    
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
        const encryptionResult = await promptForEncryption('Would you like to encrypt your database? (You can say no now and create an encrypted copy later using the replicate command)');
        
        if (encryptionResult.keyPath) {
            options.key = encryptionResult.keyPath;
            options.generateKey = encryptionResult.generateKey || false;
        }
    }

    const metaPath = pathJoin(dbDir, '.db');

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

    // Check the requested directory is empty or non-existent using the storage interface. 
    if (!await assetStorage.isEmpty("/")) {
        outro(pc.red(`✗ The directory ${pc.cyan(dbDir)} is not empty or already contains a database.\n  Please choose an empty directory or a non-existent one.`));
        await exit(1);
    }

    if (!await assetStorage.isEmpty(".db")) {
        outro(pc.red(`✗ The metadata directory ${pc.cyan(metaPath)} is not empty or already contains a database.\n  Please choose an empty directory or a non-existent one.`));
        await exit(1);
    }

    // Create database instance
    const database = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider); 

    // Create the database (instead of loading)
    await createMediaDatabase(database.assetStorage, uuidGenerator, database.metadataCollection);

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
        databaseDir: dbDir,
        metaPath,
        assetStorage: database.assetStorage,
        bsonDatabase: database.bsonDatabase,
        sessionId,
        metadataCollection: database.metadataCollection,
        localFileScanner: database.localFileScanner,
    };
}

