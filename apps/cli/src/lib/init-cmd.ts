import { createMediaFileDatabase, createDatabase as createMediaDatabase, loadSortIndexes } from "api";
import { createStorage, loadEncryptionKeysFromPem, generateKeyPair, exportPublicKeyToPem, pathJoin, IStorage, IEncryptionKeyPem } from "storage";
import { createPrivateKey, createPublicKey } from "node:crypto";
import type { BsonDatabase, IBsonCollection } from "bdb";
import type { IUuidGenerator, ITimestampProvider } from "utils";
import type { IAsset } from "api";
import type { IQueueBackend } from "task-queue";
import { setQueueBackend } from "task-queue";
import { WorkerPoolBun } from "./worker-pool-bun";
import { configureLog } from "./log";
import { exit, TestUuidGenerator, TestTimestampProvider, registerTerminationCallback, pathExists, getProcessTmpDir } from "node-utils";
import { getDatabases } from "api";
import { log, RandomUuidGenerator, TimestampProvider } from "utils";
import type { IDatabaseEntry } from 'electron-defs';
import type { IS3Credentials } from 'storage';
import { getDirectoryForCommand } from './directory-picker';
import { ensureMediaProcessingTools } from './ensure-tools';
import * as fs from 'fs/promises';
import * as os from 'os';
import pc from "picocolors";
import { confirm, text, password, isCancel, outro, select, multiline } from './clack/prompts';
import * as path from "path";
import { CURRENT_DATABASE_VERSION, loadTreeVersion } from "merkle-tree";
import { getVault, getDefaultVaultType } from 'vault';
import { fuzzyMatch } from 'fuzzy-match';

//
// Reads the default S3 credentials fallback from the vault.
//
export async function getDefaultS3Config(): Promise<IS3Credentials | undefined> {
    const vault = getVault(getDefaultVaultType());
    const secret = await vault.get('default:s3');
    if (!secret) {
        return undefined;
    }
    const parsed = JSON.parse(secret.value);
    return {
        region: parsed.region,
        accessKeyId: parsed.accessKeyId,
        secretAccessKey: parsed.secretAccessKey,
        endpoint: parsed.endpoint,
    };
}

//
// Resolves the Google geocoding API key from the vault when a vault key name is provided,
// or falls back to the GOOGLE_API_KEY environment variable.
// Only touches the vault when geocodingKeyName is set — call this lazily at the point
// where geocoding is actually needed.
//
export async function resolveGeocodingApiKey(geocodingKeyName: string | undefined): Promise<string | undefined> {
    if (geocodingKeyName) {
        const vault = getVault(getDefaultVaultType());
        const geocodingSecret = await vault.get(geocodingKeyName);
        if (geocodingSecret) {
            const parsed = JSON.parse(geocodingSecret.value);
            return parsed.apiKey as string;
        }
        return undefined;
    }
    return process.env.GOOGLE_API_KEY?.trim();
}

//
// Prompts the user to configure S3 credentials and stores them in the vault as a named secret.
// Returns the configured credentials, or undefined if AWS env vars are already set.
//
export async function configureS3IfNeeded(nonInteractive: boolean): Promise<IS3Credentials | undefined> {
    if (process.env.AWS_ACCESS_KEY_ID && process.env.AWS_SECRET_ACCESS_KEY) {
        return undefined;
    }

    const existing = await getDefaultS3Config();
    if (existing) {
        return existing;
    }

    if (nonInteractive) {
        log.error(pc.red('✗ S3 credentials are required. Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables, or run interactively to configure credentials.'));
        await exit(1);
        return undefined;
    }

    log.info(pc.yellow('\nNo S3 credentials found.'));
    const shouldConfigure = await confirm({
        message: 'Would you like to configure S3 credentials now?',
        initialValue: true,
    });

    if (isCancel(shouldConfigure) || !shouldConfigure) {
        log.error(pc.red('S3 credentials are required.'));
        await exit(1);
        return undefined;
    }

    log.info(pc.cyan('Your credentials will be stored securely in your OS keychain as \'default:s3\'.'));

    const endpoint = await text({
        message: 'S3 Endpoint URL (leave empty for AWS S3):',
        placeholder: 'https://nyc3.digitaloceanspaces.com',
        validate: (value) => {
            if (value && !value.startsWith('http://') && !value.startsWith('https://')) {
                return 'Endpoint must start with http:// or https://';
            }
            return undefined;
        },
    });

    if (isCancel(endpoint)) {
        await exit(0);
        return undefined;
    }

    const region = await text({
        message: 'Region:',
        initialValue: 'us-east-1',
        validate: (value) => {
            if (!value || value.trim() === '') {
                return 'Region is required';
            }
            return undefined;
        },
    });

    if (isCancel(region)) {
        await exit(0);
        return undefined;
    }

    const accessKeyId = await text({
        message: 'Access Key ID:',
        validate: (value) => {
            if (!value || value.trim() === '') {
                return 'Access Key ID is required';
            }
            return undefined;
        },
    });

    if (isCancel(accessKeyId)) {
        await exit(0);
        return undefined;
    }

    const secretAccessKey = await password({
        message: 'Secret Access Key:',
        validate: (value) => {
            if (!value || value.trim() === '') {
                return 'Secret Access Key is required';
            }
            return undefined;
        },
    });

    if (isCancel(secretAccessKey)) {
        await exit(0);
        return undefined;
    }

    const credentials: IS3Credentials = {
        region: (region as string).trim(),
        accessKeyId: (accessKeyId as string).trim(),
        secretAccessKey: (secretAccessKey as string).trim(),
    };

    const endpointStr = typeof endpoint === 'string' ? endpoint.trim() : '';
    if (endpointStr) {
        credentials.endpoint = endpointStr;
    }

    const vault = getVault(getDefaultVaultType());
    await vault.set({
        name: 'default:s3',
        type: 's3-credentials',
        value: JSON.stringify(credentials),
    });

    return credentials;
}

//
// Lists vault key names for all encryption keys stored in the vault.
//
export async function getAvailableKeys(): Promise<string[]> {
    const vault = getVault(getDefaultVaultType());
    const secrets = await vault.list();
    return secrets
        .filter(secret => secret.type === 'encryption-key')
        .map(secret => secret.name);
}

//
// Prompts the user to pick an encryption key from those stored in the vault.
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
//
export interface IEncryptionPromptResult {
    // Vault key name (e.g. "my-photos").
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

        const vault = getVault(getDefaultVaultType());
        await vault.set({
            name: keyName,
            type: 'encryption-key',
            value: privateKeyPem,
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
    const vault = getVault(getDefaultVaultType());
    const secret = await vault.get(keyName);
    if (!secret || secret.type !== 'encryption-key') {
        return undefined;
    }
    const privateKeyPem = secret.value;
    const privateKeyObj = createPrivateKey(privateKeyPem);
    const publicKeyPem = exportPublicKeyToPem(createPublicKey(privateKeyObj));
    return { privateKeyPem, publicKeyPem };
}

//
// Builds an IEncryptionKeyPem from a private key PEM string and stores it in the vault.
//
async function buildAndStoreKeyPem(keyName: string, privateKeyPem: string): Promise<IEncryptionKeyPem> {
    const vault = getVault(getDefaultVaultType());
    await vault.set({ name: keyName, type: 'encryption-key', value: privateKeyPem });
    const privateKeyObj = createPrivateKey(privateKeyPem);
    const publicKeyPem = exportPublicKeyToPem(createPublicKey(privateKeyObj));
    return { privateKeyPem, publicKeyPem };
}

//
// Interactively prompts the user to add a missing encryption key (paste PEM or import from file).
// Returns undefined when non-interactive or cancelled.
//
export async function promptToAddKey(keyName: string, nonInteractive: boolean): Promise<IEncryptionKeyPem | undefined> {
    if (nonInteractive) {
        return undefined;
    }

    const choice = await select({
        message: `Encryption key "${keyName}" was not found. How would you like to add it?`,
        options: [
            { value: 'paste', label: 'Paste PEM' },
            { value: 'import', label: 'Import from file' },
            { value: 'cancel', label: 'Cancel' },
        ],
    });

    if (isCancel(choice) || choice === 'cancel') {
        return undefined;
    }

    if (choice === 'paste') {
        const pem = await multiline({ message: 'Paste the private key PEM:' });
        if (isCancel(pem)) {
            return undefined;
        }
        return buildAndStoreKeyPem(keyName, pem as string);
    }

    if (choice === 'import') {
        const filePath = await text({ message: 'Enter the path to the PEM file:' });
        if (isCancel(filePath)) {
            return undefined;
        }
        const pem = await fs.readFile(filePath as string, 'utf-8');
        return buildAndStoreKeyPem(keyName, pem);
    }

    return undefined;
}

//
// Interactively prompts the user to generate a new key, paste a PEM, or import from file.
// Returns undefined when non-interactive or cancelled.
//
export async function promptToGenerateOrAddKey(keyName: string, nonInteractive: boolean): Promise<IEncryptionKeyPem | undefined> {
    if (nonInteractive) {
        return undefined;
    }

    const choice = await select({
        message: `Encryption key "${keyName}" was not found. How would you like to add it?`,
        options: [
            { value: 'generate', label: 'Generate a new key' },
            { value: 'paste', label: 'Paste PEM' },
            { value: 'import', label: 'Import from file' },
            { value: 'cancel', label: 'Cancel' },
        ],
    });

    if (isCancel(choice) || choice === 'cancel') {
        return undefined;
    }

    if (choice === 'generate') {
        const keyPair = generateKeyPair();
        const privateKeyPem = keyPair.privateKey.export({ type: 'pkcs8', format: 'pem' }) as string;
        return buildAndStoreKeyPem(keyName, privateKeyPem);
    }

    if (choice === 'paste') {
        const pem = await multiline({ message: 'Paste the private key PEM:' });
        if (isCancel(pem)) {
            return undefined;
        }
        return buildAndStoreKeyPem(keyName, pem as string);
    }

    if (choice === 'import') {
        const filePath = await text({ message: 'Enter the path to the PEM file:' });
        if (isCancel(filePath)) {
            return undefined;
        }
        const pem = await fs.readFile(filePath as string, 'utf-8');
        return buildAndStoreKeyPem(keyName, pem);
    }

    return undefined;
}

//
// Resolves key PEMs by name. When the key is not found in the vault and a
// name was provided, the user is prompted to add the key (or generate one
// when canGenerate is true). Returns the resolved or newly-added key pems,
// or an empty array when the user cancels or non-interactive mode is active.
//
export async function resolveKeyPemsWithPrompt(
    keyName: string | undefined,
    nonInteractive: boolean,
    canGenerate: boolean
): Promise<IEncryptionKeyPem[]> {
    const keyPems = await resolveKeyPems(keyName);
    if (keyPems.length > 0 || !keyName) {
        return keyPems;
    }
    const newPair = canGenerate
        ? await promptToGenerateOrAddKey(keyName, nonInteractive)
        : await promptToAddKey(keyName, nonInteractive);
    if (newPair === undefined) {
        return [];
    }
    return [newPair];
}

//
// Secrets resolved from a database entry in databases.json.
//
export interface IResolvedDatabaseSecrets {
    // S3 credentials resolved from the linked shared secret.
    s3Config?: IS3Credentials;

    // Vault key name for the encryption key pair linked to this database entry.
    encryptionKeyName?: string;

    // Vault key name for the Google geocoding API key linked to this database entry.
    geocodingKeyName?: string;
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
        log.error(pc.red(`✗ Ambiguous database name "${dbValue}" — matches ${nameMatches.length} entries:`));
        for (const match of nameMatches) {
            log.error(`  • ${match.name} → ${match.path}`);
        }
        await exit(1);
    }

    return nameMatches[0];
}

//
// Returns registered database names whose edit distance from dbValue is within
// the fuzzy threshold. Used to suggest alternatives in "No database found" errors.
//
export async function findSimilarDatabaseNames(dbValue: string): Promise<string[]> {
    const databases = await getDatabases();
    return fuzzyMatch(dbValue, databases.map(dbEntry => dbEntry.name));
}

//
// Returns vault secret names whose edit distance from secretName is within the
// fuzzy threshold. When type is provided only secrets of that type are considered.
// Used to suggest alternatives in "No secret found" errors.
//
export async function findSimilarSecretNames(secretName: string, type?: string): Promise<string[]> {
    const vault = getVault(getDefaultVaultType());
    const secrets = await vault.list();
    const filtered = type !== undefined ? secrets.filter(secret => secret.type === type) : secrets;
    return fuzzyMatch(secretName, filtered.map(secret => secret.name));
}

//
// Returns encryption-key secret names whose edit distance from keyName is within
// the fuzzy threshold. Thin wrapper around findSimilarSecretNames with type='encryption-key'.
//
export function findSimilarKeyNames(keyName: string): Promise<string[]> {
    return findSimilarSecretNames(keyName, 'encryption-key');
}

//
// Resolves vault secrets linked to a database entry.
// S3 credentials are only fetched when the entry path uses the s3: scheme.
// Encryption and geocoding key names are returned without vault access — the
// caller fetches them lazily when the secret is actually needed.
//
export async function resolveSecretsFromEntry(entry: IDatabaseEntry): Promise<IResolvedDatabaseSecrets> {
    const result: IResolvedDatabaseSecrets = {};

    if (entry.s3Key && entry.path.startsWith('s3:')) {
        const vault = getVault(getDefaultVaultType());
        const s3Secret = await vault.get(entry.s3Key);
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

    if (entry.encryptionKey) {
        result.encryptionKeyName = entry.encryptionKey;
    }

    if (entry.geocodingKey) {
        result.geocodingKeyName = entry.geocodingKey;
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
        const sessionTempDir = path.join(getProcessTmpDir(), 'photosphere', sessionId);
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
    // Vault key name for the Google geocoding API key linked to this database entry.
    // Call resolveGeocodingApiKey() with this value to obtain the actual API key.
    //
    geocodingKeyName?: string;

    //
    // S3 credentials resolved from the database entry's linked shared secret.
    //
    s3Config?: IS3Credentials;
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

    if (dbDir.startsWith('s3:') || metaPath.startsWith('s3:')) {
        if (!resolvedSecrets?.s3Config) {
            await configureS3IfNeeded(nonInteractive);
        }
    }

    let keyName = options.key;
    let keyPems: IEncryptionKeyPem[] = [];

    if (keyName) {
        // Explicit --key overrides any resolved keys.
        keyPems = await resolveKeyPemsWithPrompt(keyName, nonInteractive, false);
        if (keyPems.length === 0) {
            outro(pc.red(`✗ Encryption key "${keyName}" not found.\n  Use "psi secrets list" to see available keys.`));
            await exit(1);
        }
    }

    let { options: storageOptions } = await loadEncryptionKeysFromPem(keyPems);

    const s3Config = resolvedSecrets?.s3Config ?? (dbDir.startsWith('s3:') ? await getDefaultS3Config() : undefined);
    let { storage: assetStorage, rawStorage: rawAssetStorage } = createStorage(dbDir, s3Config, storageOptions);

    //
    // Check that the files tree exists (.db/files.dat or legacy .db/tree.dat).
    //
    const hasFilesDat = await assetStorage.fileExists(".db/files.dat");
    const hasTreeDat = await assetStorage.fileExists(".db/tree.dat");
    if (!hasFilesDat && !hasTreeDat) {
        let notFoundMessage = pc.red(`✗ No database found at: ${pc.cyan(dbDir)}\n  The database directory must contain a ".db" folder with files.dat or tree.dat.`)
            + `\n\nTo create a new database at this directory, use:\n  ${pc.cyan(`psi init --db ${dbDir}`)}`;

        if (!matchedEntry) {
            const similarNames = await findSimilarDatabaseNames(dbDir);
            if (similarNames.length > 0) {
                notFoundMessage += `\n\nDid you mean:\n${similarNames.map(similarName => `  • ${pc.cyan(similarName)}`).join('\n')}`;
            }
        }

        outro(notFoundMessage);
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
            if (resolvedSecrets?.encryptionKeyName) {
                // Lazy fetch: the database is confirmed encrypted, so retrieve the key from vault now.
                keyPems = await resolveKeyPems(resolvedSecrets.encryptionKeyName);
                if (keyPems.length === 0) {
                    outro(pc.red(`✗ Encryption key "${resolvedSecrets.encryptionKeyName}" not found.\n  Use "psi secrets list" to see available keys.`));
                    const similarKeyNames = await findSimilarKeyNames(resolvedSecrets.encryptionKeyName);
                    if (similarKeyNames.length > 0) {
                        log.info(`Did you mean:\n${similarKeyNames.map(similarName => `  • ${pc.cyan(similarName)}`).join('\n')}`);
                    }
                    await exit(1);
                }

                const { options: newStorageOptions } = await loadEncryptionKeysFromPem(keyPems);
                storageOptions = newStorageOptions;

                const { storage: newAssetStorage } = createStorage(dbDir, s3Config, storageOptions);
                assetStorage = newAssetStorage;
            }
            else if (nonInteractive) {
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
                    const similarKeyNames = await findSimilarKeyNames(keyName);
                    if (similarKeyNames.length > 0) {
                        log.info(`Did you mean:\n${similarKeyNames.map(similarName => `  • ${pc.cyan(similarName)}`).join('\n')}`);
                    }
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
        assetStorage,
        rawAssetStorage,
        bsonDatabase: database.bsonDatabase,
        sessionId,
        metadataCollection: database.metadataCollection,
        geocodingKeyName: resolvedSecrets?.geocodingKeyName,
        s3Config,
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

    if (dbDir.startsWith('s3:') || metaPath.startsWith('s3:')) {
        await configureS3IfNeeded(nonInteractive);
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
                const vault = getVault(getDefaultVaultType());
                await vault.set({
                    name: options.key,
                    type: 'encryption-key',
                    value: privateKeyPem,
                });
                const publicKeyPem = exportPublicKeyToPem(keyPair.publicKey);
                pair = { privateKeyPem, publicKeyPem };
            }
            else {
                const newPair = await promptToGenerateOrAddKey(options.key!, nonInteractive);
                if (newPair === undefined) {
                    outro(pc.red(`✗ Encryption key "${options.key}" not found in vault.`));
                    await exit(1);
                }
                else {
                    pair = newPair;
                }
            }
        }
        if (pair) {
            keyPems = [pair];
            publicKeyPemForMarker = pair.publicKeyPem;
        }
    }

    const { options: storageOptions, isEncrypted } = await loadEncryptionKeysFromPem(keyPems);

    const s3Config = dbDir.startsWith('s3:') ? await getDefaultS3Config() : undefined;
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
        assetStorage,
        rawAssetStorage,
        bsonDatabase: database.bsonDatabase,
        sessionId,
        metadataCollection: database.metadataCollection,
    };
}

