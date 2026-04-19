import { createMediaFileDatabase, createDatabase as createMediaDatabase, loadSortIndexes } from "api";
import { createStorage, loadEncryptionKeysFromPem, generateKeyPair, exportPublicKeyToPem, pathJoin, IStorage, IEncryptionKeyPem } from "storage";
import type { BsonDatabase, IBsonCollection } from "bdb";
import type { IUuidGenerator, ITimestampProvider } from "utils";
import type { IAsset } from "defs";
import type { IQueueBackend } from "task-queue";
import { setQueueBackend } from "task-queue";
import { WorkerPoolBun } from "./worker-pool-bun";
import { configureLog } from "./log";
import { exit, TestUuidGenerator, TestTimestampProvider, registerTerminationCallback, getDatabases, pathExists } from "node-utils";
import { log, RandomUuidGenerator, TimestampProvider } from "utils";
import type { IDatabaseEntry } from 'electron-defs';
import type { IS3Credentials } from 'storage';
import { configureIfNeeded, getS3Config } from './config';
import { getDirectoryForCommand } from './directory-picker';
import { ensureMediaProcessingTools } from './ensure-tools';
import * as fs from 'fs/promises';
import * as os from 'os';
import pc from "picocolors";
import { confirm, text, isCancel, outro, select } from './clack/prompts';
import * as path from "path";
import { CURRENT_DATABASE_VERSION, loadTreeVersion } from "merkle-tree";
import { getVault } from 'vault';

//
// Lists vault key names for all encryption keys stored under cli:encryption:*.
//
export async function getAvailableKeys(): Promise<string[]> {
    const vault = getVault("plaintext");
    const secrets = await vault.list();
    return secrets
        .filter(secret => secret.name.startsWith('cli:encryption:'))
        .map(secret => secret.name.slice('cli:encryption:'.length));
}

//
// Prompts the user to pick an encryption key from those stored in the vault.
// Returns the vault key name (the part after "cli:encryption:").
//
export async function selectEncryptionKey(message: string): Promise<string> {
    const keyNames = await getAvailableKeys();

    if (keyNames.length === 0) {
        outro(pc.red('✗ No encryption keys found.\n  Use "psi secrets add" to add a key or "psi secrets import" to import an existing key file.'));
        await exit(1);
    }

    const selectedKey = await select({
        message,
        options: keyNames.map(name => ({
            value: name,
            label: name
        })),
    });

    if (isCancel(selectedKey)) {
        await exit(1);
    }

    return selectedKey as string;
}

//
// Result of encryption prompting.
// keyName is the vault key name (e.g. "my-photos"); generateKey indicates a new key should be created.
//
export interface IEncryptionPromptResult {
    // Vault key name (the part after "cli:encryption:").
    keyName?: string;

    // True when a new key pair should be generated and stored in the vault.
    generateKey?: boolean;
}

//
// Prompts for encryption settings. Either selects an existing vault key or
// generates a new RSA-4096 key pair and stores it in the vault.
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
            { value: 'existing', label: 'Use an existing key' },
            { value: 'generate', label: 'Generate a new key' },
        ],
    });

    if (isCancel(keyChoice)) {
        await exit(1);
    }

    if (keyChoice === 'existing') {
        const selectedKey = await selectEncryptionKey('Select an encryption key:');
        return { keyName: selectedKey, generateKey: false };
    }
    else if (keyChoice === 'generate') {
        const keyNameInput = await text({
            message: 'Enter a name for the new encryption key:',
            placeholder: 'my-photos',
            initialValue: 'my-photos',
            validate: (value) => {
                if (!value || value.trim().length === 0) {
                    return 'Key name is required';
                }
                if (!/^[a-zA-Z0-9._-]+$/.test(value)) {
                    return 'Key name can only contain letters, numbers, dots, hyphens, and underscores';
                }
                return undefined;
            },
        });

        if (isCancel(keyNameInput)) {
            await exit(1);
        }

        const keyName = (keyNameInput as string).trim();
        const keyPair = generateKeyPair();
        const privateKeyPem = keyPair.privateKey.export({ type: 'pkcs8', format: 'pem' }) as string;
        const publicKeyPem = exportPublicKeyToPem(keyPair.publicKey);

        const vault = getVault("plaintext");
        await vault.set({
            name: `cli:encryption:${keyName}`,
            type: 'encryption-key',
            value: JSON.stringify({ privateKeyPem, publicKeyPem }),
        });

        log.info(pc.green(`✓ Encryption key "${keyName}" stored.`));

        return { keyName, generateKey: true };
    }

    return {};
}

//
// Resolves a comma-separated list of vault key names to PEM key pairs for use in storage descriptors.
// Returns an empty array if no key names are provided.
//
export async function resolveKeyPems(keyNames?: string): Promise<IEncryptionKeyPem[]> {
    if (!keyNames) {
        return [];
    }
    const names = keyNames.split(',').map(name => name.trim()).filter(name => name.length > 0);
    const pairs: IEncryptionKeyPem[] = [];
    for (const name of names) {
        const pair = await loadKeyPairFromVault(name);
        if (pair) {
            pairs.push(pair);
        }
    }
    return pairs;
}

//
// Loads a PEM key pair from the vault for the given key name.
// Returns the pair or undefined if not found.
//
async function loadKeyPairFromVault(keyName: string): Promise<IEncryptionKeyPem | undefined> {
    const vault = getVault("plaintext");
    const secret = await vault.get(`cli:encryption:${keyName}`);
    if (!secret) {
        return undefined;
    }
    return JSON.parse(secret.value) as IEncryptionKeyPem;
}

//
// Secrets resolved from a database entry in databases.json.
//
export interface IResolvedDatabaseSecrets {
    // S3 credentials resolved from the linked shared secret.
    s3Config?: IS3Credentials;

    // Encryption key PEM pairs resolved from the linked shared secret.
    keyPems: IEncryptionKeyPem[];

    // Google geocoding API key resolved from the linked shared secret.
    googleApiKey?: string;
}

//
// Resolves a --db value to a database entry from databases.json.
// Tries exact path match first, then case-insensitive name match.
// Returns undefined if no match is found (not an error — the value is treated as a raw path).
// Errors if multiple entries match by name (ambiguous).
//
export async function resolveDatabaseEntry(dbValue: string): Promise<IDatabaseEntry | undefined> {
    const databases = await getDatabases();

    // Try exact path match first.
    const pathMatch = databases.find(dbEntry => dbEntry.path === dbValue);
    if (pathMatch) {
        return pathMatch;
    }

    // Try case-insensitive name match.
    const nameMatches = databases.filter(
        dbEntry => dbEntry.name.toLowerCase() === dbValue.toLowerCase()
    );

    if (nameMatches.length === 0) {
        return undefined;
    }

    if (nameMatches.length > 1) {
        console.error(pc.red(`✗ Ambiguous database name "${dbValue}" — matches ${nameMatches.length} entries:`));
        for (const match of nameMatches) {
            console.error(`  • ${match.name} → ${match.path}`);
        }
        await exit(1);
    }

    return nameMatches[0];
}

//
// Resolves vault secrets linked to a database entry.
// Follows the same pattern as the desktop main.ts secret resolution.
//
export async function resolveSecretsFromEntry(entry: IDatabaseEntry): Promise<IResolvedDatabaseSecrets> {
    const vault = getVault("plaintext");
    const result: IResolvedDatabaseSecrets = {
        keyPems: [],
    };

    if (entry.s3CredentialId) {
        const s3Secret = await vault.get(`shared:${entry.s3CredentialId}`);
        if (s3Secret) {
            const parsed = JSON.parse(s3Secret.value);
            result.s3Config = {
                region: parsed.region,
                accessKeyId: parsed.accessKeyId,
                secretAccessKey: parsed.secretAccessKey,
                endpoint: parsed.endpoint,
            };
        }
    }

    if (entry.encryptionKeyId) {
        const encryptionSecret = await vault.get(`shared:${entry.encryptionKeyId}`);
        if (encryptionSecret) {
            const parsed = JSON.parse(encryptionSecret.value);
            result.keyPems.push({
                privateKeyPem: parsed.privateKeyPem,
                publicKeyPem: parsed.publicKeyPem,
            });
        }
    }

    if (entry.geocodingKeyId) {
        const geocodingSecret = await vault.get(`shared:${entry.geocodingKeyId}`);
        if (geocodingSecret) {
            const parsed = JSON.parse(geocodingSecret.value);
            result.googleApiKey = parsed.apiKey;
        }
    }

    return result;
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
    // Name of the encryption key stored in the vault (e.g. "my-photos").
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
    // Defaults to the number of CPU cores.
    // Supported by commands that use the task queue (e.g., verify, check).
    //
    workers?: number;

    //
    // Task timeout in milliseconds.
    // Supported by commands that use the task queue (e.g., verify).
    // Defaults to 40 minutes (2400000ms).
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
    sessionTempDir: string;
    workerPool: IQueueBackend;
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
        
        // Create a session temporary directory for this command execution
        const sessionTempDir = path.join(os.tmpdir(), 'photosphere', sessionId);
        await fs.mkdir(sessionTempDir, { recursive: true });
        log.verbose(`Created temporary directory for command session: "${sessionTempDir}"`);
        
        // Worker pool defaults to number of CPUs if not specified
        const workers = options.workers ?? os.cpus().length;
        const timeout = options.timeout ?? 2400000;
        const workerPool = new WorkerPoolBun(workers, timeout, {
            verbose: options.verbose,
            tools: options.tools,
            sessionId,
        });
        setQueueBackend(workerPool);

        const context: ICommandContext = {
            uuidGenerator,
            timestampProvider,
            sessionId,
            sessionTempDir,
            workerPool,
        };
        
        // Register cleanup handler for termination
        registerTerminationCallback(async (exitCode: number) => {
            workerPool.shutdown();
            if (exitCode === 0) {
                // Successful exit - clean up temp directory
                try {
                    await fs.rm(sessionTempDir, { recursive: true, force: true });
                    log.verbose(`Cleaned up temporary directory "${sessionTempDir}"`);
                }
                catch (error: any) {
                    log.exception(`Failed to clean up temporary directory ${sessionTempDir}`, error);
                }
            }
            else {
                // Error exit - retain temp directory for inspection
                log.info(`Temporary files retained for inspection: ${sessionTempDir}`);
            }
        });
        
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

    //
    // Raw (unencrypted) storage - reads bytes exactly as stored on disk, with no decryption applied.
    // Use this when you need to inspect the raw on-disk bytes (e.g. to read encryption headers).
    //
    rawAssetStorage: IStorage;

    bsonDatabase: BsonDatabase;
    sessionId: string;
    metadataCollection: IBsonCollection<IAsset>;

    //
    // The resolved metadata path
    //
    metaPath: string;

    //
    // Google geocoding API key resolved from the database entry's linked shared secret.
    //
    googleApiKey?: string;
}

//
// Shared database loading function for CLI commands.
//
export async function loadDatabase(
    dbDir: string | undefined, 
    options: IBaseCommandOptions, 
    uuidGenerator: IUuidGenerator,
    timestampProvider: ITimestampProvider,
    sessionId: string,
    allowOlderVersions: boolean = false,
): Promise<IInitResult> { //todo: Move into api.

    const nonInteractive = options.yes || false;

    // Ensure media processing tools are available
    await ensureMediaProcessingTools(nonInteractive);

    if (dbDir === undefined) {
        dbDir = await getDirectoryForCommand("existing", nonInteractive, options.cwd || process.cwd());
    }

    // Try to resolve the --db value to a database entry in databases.json.
    // This allows --db to accept a database name in addition to a path.
    let resolvedSecrets: IResolvedDatabaseSecrets | undefined;
    const matchedEntry = await resolveDatabaseEntry(dbDir);
    if (matchedEntry) {
        // If matched by name (dbDir doesn't equal the entry's path), use the entry's path.
        if (matchedEntry.path !== dbDir) {
            dbDir = matchedEntry.path;
        }
        resolvedSecrets = await resolveSecretsFromEntry(matchedEntry);
    }

    const metaPath = pathJoin(dbDir, '.db');

    if (dbDir.startsWith("s3:")) {
        if (!resolvedSecrets?.s3Config) {
            await configureIfNeeded(['s3'], nonInteractive);
        }
    }
    
    if (metaPath.startsWith("s3:")) {
        if (!resolvedSecrets?.s3Config) {
            await configureIfNeeded(['s3'], nonInteractive);
        }
    }

    let keyName = options.key;
    let keyPems: IEncryptionKeyPem[] = resolvedSecrets?.keyPems ?? [];

    if (keyName) {
        // Explicit --key overrides any resolved keys.
        keyPems = await resolveKeyPems(keyName);
        if (keyPems.length === 0) {
            outro(pc.red(`✗ Encryption key "${keyName}" not found.\n  Use "psi secrets list" to see available keys.`));
            await exit(1);
        }
    }

    let { options: storageOptions } = await loadEncryptionKeysFromPem(keyPems);

    const s3Config = resolvedSecrets?.s3Config ?? await getS3Config();
    let { storage: assetStorage, rawStorage: rawAssetStorage } = createStorage(dbDir, s3Config, storageOptions);

    //
    // Check that the files tree exists (.db/files.dat or legacy .db/tree.dat).
    //
    const hasFilesDat = await assetStorage.fileExists(".db/files.dat");
    const hasTreeDat = await assetStorage.fileExists(".db/tree.dat");
    if (!hasFilesDat && !hasTreeDat) {
        outro(pc.red(`✗ No database found at: ${pc.cyan(dbDir)}\n  The database directory must contain a ".db" folder with files.dat or tree.dat.\n\nTo create a new database at this directory, use:\n  ${pc.cyan(`psi init --db ${dbDir}`)}`));
        await exit(1);
    }

    if (!allowOlderVersions) {
        //
        // When trying to load the database and we don't allow older versions,
        // quickly load the version from the database and reject if the database is old.
        //
        const treePath = hasFilesDat ? ".db/files.dat" : ".db/tree.dat";
        const databaseVersion = await loadTreeVersion(treePath, assetStorage);
        if (databaseVersion && databaseVersion < CURRENT_DATABASE_VERSION) {
            outro(pc.red(`✗ Database version ${databaseVersion} is outdated. Current version is ${CURRENT_DATABASE_VERSION}. Please run 'psi upgrade' to upgrade your database.`));
            await exit(1);
        }
    }

    //
    // See if the database is encrypted and requires a key.
    //
    if (await assetStorage.fileExists('.db/encryption.pub')) {
        if (keyPems.length === 0) {
            if (nonInteractive) {
                outro(pc.red(`✗ This database is encrypted and requires a private key to access.\n  Please provide the key name using the --key option.\n\nExample:\n    ${pc.cyan(`psi <command> --key my-photos`)}`));
                await exit(1);
            }
            else {
                log.info(pc.yellow('This database is encrypted and requires a private key to access.'));

                const selectedKeyName = await selectEncryptionKey('Select the encryption key for this database:');
                keyName = selectedKeyName;
                options.key = keyName;

                keyPems = await resolveKeyPems(keyName);
                if (keyPems.length === 0) {
                    outro(pc.red(`✗ Encryption key "${keyName}" not found.`));
                    await exit(1);
                }

                const { options: newStorageOptions } = await loadEncryptionKeysFromPem(keyPems);
                storageOptions = newStorageOptions;

                const { storage: newAssetStorage } = createStorage(dbDir, s3Config, storageOptions);
                assetStorage = newAssetStorage;
            }
        }
    }

    // Create database instance (v6 layout: BSON under .db/bson)
    const database = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);

    await loadSortIndexes(database.assetStorage, database.metadataCollection);

    return {
        databaseDir: dbDir,
        metaPath,
        assetStorage,
        rawAssetStorage,
        bsonDatabase: database.bsonDatabase,
        sessionId,
        metadataCollection: database.metadataCollection,
        googleApiKey: resolvedSecrets?.googleApiKey,
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
        if (options.generateKey) {
            // User requested key generation via --generate-key without a key name.
            // Run the generate branch of the interactive prompt.
            const encryptionResult = await promptForEncryption('Would you like to encrypt your database? (You can say no now and create an encrypted copy later using the replicate command)');
            if (encryptionResult.keyName) {
                options.key = encryptionResult.keyName;
                options.generateKey = encryptionResult.generateKey || false;
            }
        }
        else {
            const encryptionResult = await promptForEncryption('Would you like to encrypt your database? (You can say no now and create an encrypted copy later using the replicate command)');
            if (encryptionResult.keyName) {
                options.key = encryptionResult.keyName;
                options.generateKey = encryptionResult.generateKey || false;
            }
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

    // Load encryption key pair from vault
    let keyPems: IEncryptionKeyPem[] = [];
    let publicKeyPemForMarker: string | undefined = undefined;

    if (options.key) {
        let pair = await loadKeyPairFromVault(options.key);
        if (!pair) {
            if (options.generateKey) {
                const keyPair = generateKeyPair();
                const privateKeyPem = keyPair.privateKey.export({ type: 'pkcs8', format: 'pem' }) as string;
                const publicKeyPem = exportPublicKeyToPem(keyPair.publicKey);
                const vault = getVault("plaintext");
                await vault.set({
                    name: `cli:encryption:${options.key}`,
                    type: 'encryption-key',
                    value: JSON.stringify({ privateKeyPem, publicKeyPem }),
                });
                pair = { privateKeyPem, publicKeyPem };
            }
            else {
                outro(pc.red(`✗ Encryption key "${options.key}" not found in vault.`));
                await exit(1);
            }
        }
        if (pair) {
            keyPems = [pair];
            publicKeyPemForMarker = pair.publicKeyPem;
        }
    }

    const { options: storageOptions, isEncrypted } = await loadEncryptionKeysFromPem(keyPems);

    const s3Config = await getS3Config();
    const { storage: assetStorage, rawStorage: rawAssetStorage } = createStorage(dbDir, s3Config, storageOptions);

    // Check the requested directory is empty or non-existent using the storage interface.
    if (!await assetStorage.isEmpty("/")) {
        outro(pc.red(`✗ The directory ${pc.cyan(dbDir)} is not empty or already contains a database.\n  Please choose an empty directory or a non-existent one.`));
        await exit(1);
    }

    if (!await assetStorage.isEmpty(".db")) {
        outro(pc.red(`✗ The metadata directory ${pc.cyan(metaPath)} is not empty or already contains a database.\n  Please choose an empty directory or a non-existent one.`));
        await exit(1);
    }

    // Create database instance (v6 layout: BSON under .db/bson)
    const database = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);

    // Create the database (instead of loading)
    await createMediaDatabase(assetStorage, rawAssetStorage, uuidGenerator, database.metadataCollection);

    // If database is encrypted, write the public key PEM to .db/encryption.pub as a marker
    if (isEncrypted && publicKeyPemForMarker) {
        await rawAssetStorage.write('.db/encryption.pub', undefined, Buffer.from(publicKeyPemForMarker, 'utf-8'));
    }

    return {
        databaseDir: dbDir,
        metaPath,
        assetStorage,
        rawAssetStorage,
        bsonDatabase: database.bsonDatabase,
        sessionId,
        metadataCollection: database.metadataCollection,
    };
}

