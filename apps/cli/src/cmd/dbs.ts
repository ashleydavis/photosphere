import { Command } from 'commander';
import pc from 'picocolors';
import { getVault, getDefaultVaultType } from 'vault';
import { log } from 'utils';
import { getDatabases, addDatabaseEntry, updateDatabaseEntry, removeDatabaseEntry } from 'node-utils';
import { confirm, intro, outro, text, select, isCancel, spinner, note } from '../lib/clack/prompts';
import { exit } from 'node-utils';
import { generateKeyPair, exportPublicKeyToPem } from 'storage';
import type { IDatabaseEntry } from 'electron-defs';
import { LanShareSender, LanShareReceiver, resolveDatabaseSharePayload, importDatabasePayload } from 'lan-share';
import type { IDatabaseSharePayload, ConflictResolver, IConflictResolution } from 'lan-share';
import { findSimilarDatabaseNames, findSimilarKeyNames, findSimilarSecretNames } from '../lib/init-cmd';

//
// Options for the `dbs add` command.
//
interface IDbsAddOptions {
    // Skip interactive prompts.
    yes?: boolean;
    // Database name.
    name?: string;
    // Database description.
    description?: string;
    // Database path.
    path?: string;
    // S3 credential secret name.
    s3Cred?: string;
    // Encryption key secret name.
    encryptionKey?: string;
    // Geocoding API key secret name.
    geocodingKey?: string;
}

//
// Options for the `dbs view` command.
//
interface IDbsViewOptions {
    // Skip interactive selection (requires --name or --path).
    yes?: boolean;
    // Database name to look up.
    name?: string;
    // Database path to look up.
    path?: string;
}

//
// Options for the `dbs edit` command.
//
interface IDbsEditOptions {
    // Skip interactive prompts.
    yes?: boolean;
    // Database name to edit (identifier).
    name?: string;
    // New database name (rename).
    newName?: string;
    // New description.
    description?: string;
    // New database path.
    path?: string;
    // S3 credential secret name.
    s3Cred?: string;
    // Encryption key secret name.
    encryptionKey?: string;
    // Geocoding API key secret name.
    geocodingKey?: string;
}

//
// Options for the `dbs remove` command.
//
interface IDbsRemoveOptions {
    // Skip confirmation prompt.
    yes?: boolean;
    // Database name to look up.
    name?: string;
    // Database path to look up.
    path?: string;
}

//
// Options for the `dbs send` command.
//
interface IDbsSendOptions {
    // Skip confirmation prompts.
    yes?: boolean;
    // Database name to look up.
    name?: string;
    // Database path to look up.
    path?: string;
    // Pairing code to use instead of generating one.
    code?: string;
}

//
// Returns true if the path refers to a local filesystem location rather than
// a network-accessible storage like S3. Local paths won't be valid on other devices.
//
function isLocalPath(dbPath: string): boolean {
    return !dbPath.startsWith('s3:');
}

//
// Generates an 8-character random alphanumeric ID for shared vault secrets.
//
function generateSharedSecretId(): string {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    let result = '';
    for (let index = 0; index < 8; index++) {
        result += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return result;
}

//
// Finds a database entry by its exact path.
//
async function findDatabaseByPath(dbPath: string): Promise<IDatabaseEntry | undefined> {
    const databases = await getDatabases();
    return databases.find(dbEntry => dbEntry.path === dbPath);
}

//
// Finds a database entry by name or path. Name takes precedence if both are provided.
//
async function findDatabaseByIdentifier(name: string | undefined, dbPath: string | undefined): Promise<IDatabaseEntry | undefined> {
    if (name) {
        return findDatabaseByName(name);
    }
    if (dbPath) {
        return findDatabaseByPath(dbPath);
    }
    return undefined;
}

//
// Finds a database entry by name using case-insensitive matching.
// Errors if multiple entries match the same name.
//
async function findDatabaseByName(name: string): Promise<IDatabaseEntry | undefined> {
    const databases = await getDatabases();
    const matches = databases.filter(
        dbEntry => dbEntry.name.toLowerCase() === name.toLowerCase()
    );

    if (matches.length === 0) {
        return undefined;
    }

    if (matches.length > 1) {
        log.error(pc.red(`✗ Ambiguous name "${name}" — matches ${matches.length} entries:`));
        for (const match of matches) {
            log.error(`  • ${match.name} → ${match.path}`);
        }
        await exit(1);
    }

    return matches[0];
}

//
// Presents a select prompt to pick or create a shared secret of the given type.
// Returns the secret ID to store on the database entry, or undefined for "None".
//
async function pickOrCreateSecret(secretType: string, label: string, currentId?: string): Promise<string | undefined> {
    const vault = getVault(getDefaultVaultType());
    const secrets = await vault.list();

    // Find existing secrets of the matching type.
    const matchingSecrets = secrets
        .filter(secret => secret.type === secretType)
        .map(secret => {
            const secretId = secret.name;
            let displayLabel = secretId;
            try {
                const parsed = JSON.parse(secret.value);
                if (parsed.label) {
                    displayLabel = parsed.label;
                }
            }
            catch {
                // Ignore parse errors, use ID as display.
            }
            return { secretId, displayLabel };
        });

    // Build the select options.
    const options: { value: string; label: string }[] = [
        { value: '__none__', label: 'None' },
    ];

    for (const matchingSecret of matchingSecrets) {
        options.push({
            value: matchingSecret.secretId,
            label: matchingSecret.displayLabel,
        });
    }

    options.push({ value: '__create__', label: '+ Create new' });

    // Determine the initial value (highlight current selection when editing).
    const initialValue = currentId || '__none__';

    const selected = await select({
        message: label,
        options,
        initialValue,
    });

    if (isCancel(selected)) {
        outro(pc.yellow('Cancelled.'));
        await exit(0);
        return undefined;
    }

    const selectedValue = selected as string;

    if (selectedValue === '__none__') {
        return undefined;
    }

    if (selectedValue === '__create__') {
        return await createSharedSecret(secretType);
    }

    return selectedValue;
}

//
// Inline creation flow for a new shared secret of the given type.
// Returns the generated secret ID.
//
async function createSharedSecret(secretType: string): Promise<string> {
    const vault = getVault(getDefaultVaultType());
    const secretId = generateSharedSecretId();

    if (secretType === 's3-credentials') {
        const label = await promptRequired('Label for this S3 credential:');
        const endpoint = await promptOptional('Endpoint URL (leave blank for AWS):');
        const region = await promptRequired('Region (e.g. us-east-1):');
        const accessKeyId = await promptRequired('Access Key ID:');
        const secretAccessKey = await promptRequired('Secret Access Key:');

        const value: Record<string, string> = { label, region, accessKeyId, secretAccessKey };
        if (endpoint) {
            value.endpoint = endpoint;
        }

        await vault.set({
            name: secretId,
            type: 's3-credentials',
            value: JSON.stringify(value),
        });

        log.info(pc.green(`  ✓ S3 credential "${label}" created (${secretId})`));
    }
    else if (secretType === 'encryption-key') {
        const label = await promptRequired('Label for this encryption key:');

        const keyChoice = await select({
            message: 'How would you like to provide the key?',
            options: [
                { value: 'generate', label: 'Generate a new RSA-4096 key pair' },
                { value: 'import', label: 'Import existing PEM files' },
            ],
        });

        if (isCancel(keyChoice)) {
            outro(pc.yellow('Cancelled.'));
            await exit(0);
        }

        let privateKeyPem: string;
        let publicKeyPem: string;

        if (keyChoice === 'generate') {
            const keyPair = generateKeyPair();
            privateKeyPem = keyPair.privateKey.export({ type: 'pkcs8', format: 'pem' }) as string;
            publicKeyPem = exportPublicKeyToPem(keyPair.publicKey);
        }
        else {
            const { readFile } = await import('fs/promises');
            const privatePath = await promptRequired('Path to private key (.key):');
            const publicPath = await promptRequired('Path to public key (.key.pub):');
            privateKeyPem = await readFile(privatePath, 'utf-8');
            publicKeyPem = await readFile(publicPath, 'utf-8');
        }

        await vault.set({
            name: secretId,
            type: 'encryption-key',
            value: JSON.stringify({ label, privateKeyPem, publicKeyPem }),
        });

        log.info(pc.green(`  ✓ Encryption key "${label}" created (${secretId})`));
    }
    else if (secretType === 'api-key') {
        const label = await promptRequired('Label for this API key:');
        const apiKey = await promptRequired('API key value:');

        await vault.set({
            name: secretId,
            type: 'api-key',
            value: JSON.stringify({ label, apiKey }),
        });

        log.info(pc.green(`  ✓ API key "${label}" created (${secretId})`));
    }

    return secretId;
}

//
// Prompts for a required text value and returns the trimmed string.
//
async function promptRequired(message: string): Promise<string> {
    const value = await text({
        message,
        validate: (val) => {
            if (!val || val.trim().length === 0) {
                return 'This field is required';
            }
            return undefined;
        },
    });

    if (isCancel(value)) {
        outro(pc.yellow('Cancelled.'));
        await exit(0);
    }

    return (value as string).trim();
}

//
// Prompts for an optional text value and returns the trimmed string, or undefined if blank.
//
async function promptOptional(message: string): Promise<string | undefined> {
    const value = await text({ message });

    if (isCancel(value)) {
        outro(pc.yellow('Cancelled.'));
        await exit(0);
    }

    const trimmed = (value as string).trim();
    return trimmed.length > 0 ? trimmed : undefined;
}

//
// Returns the Commander sub-command group for `psi dbs`.
//
export function dbsCommand(): Command {
    const cmd = new Command('dbs')
        .description('Manage the list of configured databases.');

    // psi dbs list
    cmd.command('list')
        .description('List all configured databases.')
        .action(dbsList);

    // psi dbs add
    cmd.command('add')
        .description('Interactively add a new database to the list.')
        .option('--yes', 'Skip prompts')
        .option('--name <name>', 'Database name')
        .option('--description <desc>', 'Database description')
        .option('--path <path>', 'Database path')
        .option('--s3-cred <name>', 'S3 credential secret name')
        .option('--encryption-key <name>', 'Encryption key secret name')
        .option('--geocoding-key <name>', 'Geocoding API key secret name')
        .action(dbsAdd);

    // psi dbs view
    cmd.command('view')
        .description('Show all fields of a database entry.')
        .option('--yes', 'Skip interactive selection (requires --name or --path)')
        .option('--name <name>', 'Database name')
        .option('--path <path>', 'Database path')
        .action(dbsView);

    // psi dbs edit
    cmd.command('edit')
        .description('Edit fields of a database entry.')
        .option('--yes', 'Skip prompts')
        .option('--name <name>', 'Database name to edit')
        .option('--new-name <name>', 'New database name')
        .option('--description <desc>', 'New description')
        .option('--path <path>', 'New database path')
        .option('--s3-cred <name>', 'S3 credential secret name')
        .option('--encryption-key <name>', 'Encryption key secret name')
        .option('--geocoding-key <name>', 'Geocoding API key secret name')
        .action(dbsEdit);

    // psi dbs remove
    cmd.command('remove')
        .description('Remove a database entry from the list.')
        .option('--yes', 'Skip confirmation prompt')
        .option('--name <name>', 'Database name')
        .option('--path <path>', 'Database path')
        .action(dbsRemove);

    // psi dbs clear
    cmd.command('clear')
        .description('Remove all database entries from the list.')
        .option('--yes', 'Skip confirmation prompt')
        .action(dbsClear);

    // psi dbs send
    cmd.command('send')
        .description('Send a database config (with secrets) to another device over the local network.')
        .option('--yes', 'Skip confirmation prompts and field editing')
        .option('--name <name>', 'Database name')
        .option('--path <path>', 'Database path')
        .option('--code <code>', 'Use a specific pairing code instead of generating one (useful for scripted use)')
        .action(dbsSend);

    // psi dbs receive
    cmd.command('receive')
        .description('Receive a database config (with secrets) from another device over the local network.')
        .option('--yes', 'Skip confirmation prompts and field editing')
        .option('--code <code>', 'Pairing code shown on the other device (required with --yes)')
        .action(dbsReceive);

    return cmd;
}

//
// psi dbs list — table of all configured databases.
//
async function dbsList(): Promise<void> {
    const databases = await getDatabases();

    if (databases.length === 0) {
        log.info(pc.yellow('No databases configured.'));
        log.info(pc.dim('Use "psi dbs add" to add a database.'));
        return;
    }

    log.info(pc.cyan(`\n${'Name'.padEnd(25)} Path`));
    log.info('─'.repeat(70));

    for (const dbEntry of databases) {
        log.info(`${dbEntry.name.padEnd(25)} ${dbEntry.path}`);
    }

    log.info('');
}

//
// psi dbs add — interactively add a new database entry.
//
export async function dbsAdd(cmdOptions: IDbsAddOptions): Promise<void> {
    if (cmdOptions.yes) {
        if (!cmdOptions.name || !cmdOptions.path) {
            log.error(pc.red('✗ --name and --path are required with --yes'));
            await exit(1);
            return;
        }

        const entry: IDatabaseEntry = {
            name: cmdOptions.name,
            description: cmdOptions.description || '',
            path: cmdOptions.path,
            s3Key: cmdOptions.s3Cred,
            encryptionKey: cmdOptions.encryptionKey,
            geocodingKey: cmdOptions.geocodingKey,
        };

        const existing = await findDatabaseByName(entry.name);
        if (existing) {
            log.error(pc.red(`✗ A database named "${entry.name}" already exists (${existing.path}). Use a different name or remove the existing entry first.`));
            await exit(1);
            return;
        }

        if (cmdOptions.encryptionKey) {
            const vault = getVault(getDefaultVaultType());
            const encryptionKeySecret = await vault.get(cmdOptions.encryptionKey);
            if (!encryptionKeySecret) {
                log.error(pc.red(`✗ Encryption key "${cmdOptions.encryptionKey}" not found in vault.`));
                const similarKeyNames = await findSimilarKeyNames(cmdOptions.encryptionKey);
                if (similarKeyNames.length > 0) {
                    log.info(`Did you mean:\n${similarKeyNames.map(similarName => `  • ${pc.cyan(similarName)}`).join('\n')}`);
                }
                await exit(1);
                return;
            }
        }

        if (cmdOptions.s3Cred) {
            const vault = getVault(getDefaultVaultType());
            const s3CredSecret = await vault.get(cmdOptions.s3Cred);
            if (!s3CredSecret) {
                log.error(pc.red(`✗ S3 credential "${cmdOptions.s3Cred}" not found in vault.`));
                const similarS3Names = await findSimilarSecretNames(cmdOptions.s3Cred, 's3-credentials');
                if (similarS3Names.length > 0) {
                    log.info(`Did you mean:\n${similarS3Names.map(similarName => `  • ${pc.cyan(similarName)}`).join('\n')}`);
                }
                await exit(1);
                return;
            }
        }

        if (cmdOptions.geocodingKey) {
            const vault = getVault(getDefaultVaultType());
            const geocodingKeySecret = await vault.get(cmdOptions.geocodingKey);
            if (!geocodingKeySecret) {
                log.error(pc.red(`✗ Geocoding API key "${cmdOptions.geocodingKey}" not found in vault.`));
                const similarGeoNames = await findSimilarSecretNames(cmdOptions.geocodingKey, 'api-key');
                if (similarGeoNames.length > 0) {
                    log.info(`Did you mean:\n${similarGeoNames.map(similarName => `  • ${pc.cyan(similarName)}`).join('\n')}`);
                }
                await exit(1);
                return;
            }
        }

        await addDatabaseEntry(entry);
        log.info(pc.green(`✓ Database "${entry.name}" added.`));
        return;
    }

    intro(pc.cyan('Add Database'));

    const name = await promptRequired('Database name:');
    const description = await promptOptional('Description (optional):') || '';
    const dbPath = await promptRequired('Database path (filesystem or S3):');

    const existing = await findDatabaseByName(name);
    if (existing) {
        outro(pc.red(`✗ A database named "${name}" already exists (${existing.path}). Use a different name or remove the existing entry first.`));
        await exit(1);
        return;
    }

    // Secret linking
    const s3Key = await pickOrCreateSecret('s3-credentials', 'S3 credentials:');
    const encryptionKey = await pickOrCreateSecret('encryption-key', 'Encryption key:');
    const geocodingKey = await pickOrCreateSecret('api-key', 'Geocoding API key:');

    const entry: IDatabaseEntry = {
        name,
        description,
        path: dbPath,
        s3Key,
        encryptionKey,
        geocodingKey,
    };

    await addDatabaseEntry(entry);

    outro(pc.green(`✓ Database "${name}" added.`));
}

//
// psi dbs view [name] — show all fields of a database entry.
//
export async function dbsView(cmdOptions: IDbsViewOptions): Promise<void> {
    let entry: IDatabaseEntry | undefined;

    if (!cmdOptions.name && !cmdOptions.path) {
        if (cmdOptions.yes) {
            log.error(pc.red('✗ --name or --path is required with --yes'));
            await exit(1);
            return;
        }

        const databases = await getDatabases();
        if (databases.length === 0) {
            log.info(pc.yellow('No databases configured.'));
            return;
        }

        const selected = await select({
            message: 'Select a database to view:',
            options: databases.map(database => ({
                value: database.path,
                label: `${database.name} (${database.path})`,
            })),
        });

        if (isCancel(selected)) {
            outro(pc.yellow('Cancelled.'));
            return;
        }

        entry = databases.find(database => database.path === selected as string);
    }
    else {
        entry = await findDatabaseByIdentifier(cmdOptions.name, cmdOptions.path);
    }

    if (!entry) {
        log.error(pc.red(`✗ No database matching the given name or path was found.`));
        if (cmdOptions.name) {
            const similarNames = await findSimilarDatabaseNames(cmdOptions.name);
            if (similarNames.length > 0) {
                log.info(`Did you mean:\n${similarNames.map(similarName => `  • ${pc.cyan(similarName)}`).join('\n')}`);
            }
        }
        await exit(1);
        return;
    }

    log.info(pc.cyan('\nDatabase Entry'));
    log.info('─'.repeat(50));
    log.info(pc.cyan('Name:        ') + entry.name);
    log.info(pc.cyan('Description: ') + (entry.description || pc.dim('(none)')));
    log.info(pc.cyan('Path:        ') + entry.path);

    if (entry.s3Key) {
        log.info(pc.cyan('S3 Creds:    ') + entry.s3Key);
    }
    else {
        log.info(pc.cyan('S3 Creds:    ') + pc.dim('(none)'));
    }

    if (entry.encryptionKey) {
        log.info(pc.cyan('Encryption:  ') + entry.encryptionKey);
    }
    else {
        log.info(pc.cyan('Encryption:  ') + pc.dim('(none)'));
    }

    if (entry.geocodingKey) {
        log.info(pc.cyan('Geocoding:   ') + entry.geocodingKey);
    }
    else {
        log.info(pc.cyan('Geocoding:   ') + pc.dim('(none)'));
    }

    if (entry.origin) {
        log.info(pc.cyan('Origin:      ') + entry.origin);
    }

    log.info('');
}

//
// psi dbs edit [name] — edit fields with current values pre-populated.
//
export async function dbsEdit(cmdOptions: IDbsEditOptions): Promise<void> {
    let entry: IDatabaseEntry | undefined;

    if (!cmdOptions.name) {
        if (cmdOptions.yes) {
            log.error(pc.red('✗ --name is required with --yes'));
            await exit(1);
            return;
        }

        const databases = await getDatabases();
        if (databases.length === 0) {
            log.info(pc.yellow('No databases configured.'));
            return;
        }

        const selected = await select({
            message: 'Select a database to edit:',
            options: databases.map(database => ({
                value: database.path,
                label: `${database.name} (${database.path})`,
            })),
        });

        if (isCancel(selected)) {
            outro(pc.yellow('Cancelled.'));
            return;
        }

        entry = databases.find(database => database.path === selected as string);
    }
    else {
        entry = await findDatabaseByName(cmdOptions.name);
    }

    if (!entry) {
        log.error(pc.red(`✗ No database named "${cmdOptions.name}" found.`));
        const similarNames = await findSimilarDatabaseNames(cmdOptions.name!);
        if (similarNames.length > 0) {
            log.info(`Did you mean:\n${similarNames.map(similarName => `  • ${pc.cyan(similarName)}`).join('\n')}`);
        }
        await exit(1);
        return;
    }

    if (cmdOptions.yes) {
        if (cmdOptions.encryptionKey) {
            const vault = getVault(getDefaultVaultType());
            const encryptionKeySecret = await vault.get(cmdOptions.encryptionKey);
            if (!encryptionKeySecret) {
                log.error(pc.red(`✗ Encryption key "${cmdOptions.encryptionKey}" not found in vault.`));
                const similarKeyNames = await findSimilarKeyNames(cmdOptions.encryptionKey);
                if (similarKeyNames.length > 0) {
                    log.info(`Did you mean:\n${similarKeyNames.map(similarName => `  • ${pc.cyan(similarName)}`).join('\n')}`);
                }
                await exit(1);
                return;
            }
        }

        if (cmdOptions.s3Cred) {
            const vault = getVault(getDefaultVaultType());
            const s3CredSecret = await vault.get(cmdOptions.s3Cred);
            if (!s3CredSecret) {
                log.error(pc.red(`✗ S3 credential "${cmdOptions.s3Cred}" not found in vault.`));
                const similarS3Names = await findSimilarSecretNames(cmdOptions.s3Cred, 's3-credentials');
                if (similarS3Names.length > 0) {
                    log.info(`Did you mean:\n${similarS3Names.map(similarName => `  • ${pc.cyan(similarName)}`).join('\n')}`);
                }
                await exit(1);
                return;
            }
        }

        if (cmdOptions.geocodingKey) {
            const vault = getVault(getDefaultVaultType());
            const geocodingKeySecret = await vault.get(cmdOptions.geocodingKey);
            if (!geocodingKeySecret) {
                log.error(pc.red(`✗ Geocoding API key "${cmdOptions.geocodingKey}" not found in vault.`));
                const similarGeoNames = await findSimilarSecretNames(cmdOptions.geocodingKey, 'api-key');
                if (similarGeoNames.length > 0) {
                    log.info(`Did you mean:\n${similarGeoNames.map(similarName => `  • ${pc.cyan(similarName)}`).join('\n')}`);
                }
                await exit(1);
                return;
            }
        }

        const updated: IDatabaseEntry = {
            name: cmdOptions.newName || entry.name,
            description: cmdOptions.description ?? entry.description ?? '',
            path: cmdOptions.path || entry.path,
            origin: entry.origin,
            s3Key: cmdOptions.s3Cred ?? entry.s3Key,
            encryptionKey: cmdOptions.encryptionKey ?? entry.encryptionKey,
            geocodingKey: cmdOptions.geocodingKey ?? entry.geocodingKey,
        };

        await updateDatabaseEntry({ ...updated, path: entry.path });

        if (updated.path !== entry.path) {
            await removeDatabaseEntry(entry.path);
            await addDatabaseEntry(updated);
        }

        log.info(pc.green(`✓ Database "${updated.name}" updated.`));
        return;
    }

    intro(pc.cyan(`Edit Database: ${entry.name}`));

    const newName = await text({
        message: 'Database name:',
        initialValue: entry.name,
        validate: (val) => {
            if (!val || val.trim().length === 0) {
                return 'Name is required';
            }
            return undefined;
        },
    });

    if (isCancel(newName)) {
        outro(pc.yellow('Cancelled.'));
        return;
    }

    const newDescription = await text({
        message: 'Description:',
        initialValue: entry.description || '',
    });

    if (isCancel(newDescription)) {
        outro(pc.yellow('Cancelled.'));
        return;
    }

    const newPath = await text({
        message: 'Database path:',
        initialValue: entry.path,
        validate: (val) => {
            if (!val || val.trim().length === 0) {
                return 'Path is required';
            }
            return undefined;
        },
    });

    if (isCancel(newPath)) {
        outro(pc.yellow('Cancelled.'));
        return;
    }

    // Secret linking (with current selections highlighted).
    const s3Key = await pickOrCreateSecret('s3-credentials', 'S3 credentials:', entry.s3Key);
    const encryptionKey = await pickOrCreateSecret('encryption-key', 'Encryption key:', entry.encryptionKey);
    const geocodingKey = await pickOrCreateSecret('api-key', 'Geocoding API key:', entry.geocodingKey);

    const updated: IDatabaseEntry = {
        name: (newName as string).trim(),
        description: (newDescription as string).trim(),
        path: (newPath as string).trim(),
        origin: entry.origin,
        s3Key,
        encryptionKey,
        geocodingKey,
    };

    // Update uses the original path as the match key.
    await updateDatabaseEntry({ ...updated, path: entry.path });

    // If the path changed, update it by removing old and adding new.
    if (updated.path !== entry.path) {
        await removeDatabaseEntry(entry.path);
        await addDatabaseEntry(updated);
    }

    outro(pc.green(`✓ Database "${updated.name}" updated.`));
}

//
// psi dbs remove [name] — remove a database entry after confirmation.
//
export async function dbsRemove(cmdOptions: IDbsRemoveOptions): Promise<void> {
    let entry: IDatabaseEntry | undefined;

    if (!cmdOptions.name && !cmdOptions.path) {
        if (cmdOptions.yes) {
            log.error(pc.red('✗ --name or --path is required with --yes'));
            await exit(1);
            return;
        }

        const databases = await getDatabases();
        if (databases.length === 0) {
            log.info(pc.yellow('No databases configured.'));
            return;
        }

        const selected = await select({
            message: 'Select a database to remove:',
            options: databases.map(database => ({
                value: database.path,
                label: `${database.name} (${database.path})`,
            })),
        });

        if (isCancel(selected)) {
            outro(pc.yellow('Cancelled.'));
            return;
        }

        entry = databases.find(database => database.path === selected as string);
    }
    else {
        entry = await findDatabaseByIdentifier(cmdOptions.name, cmdOptions.path);
    }

    if (!entry) {
        log.error(pc.red(`✗ No database matching the given name or path was found.`));
        if (cmdOptions.name) {
            const similarNames = await findSimilarDatabaseNames(cmdOptions.name);
            if (similarNames.length > 0) {
                log.info(`Did you mean:\n${similarNames.map(similarName => `  • ${pc.cyan(similarName)}`).join('\n')}`);
            }
        }
        await exit(1);
        return;
    }

    if (!cmdOptions.yes) {
        const confirmed = await confirm({
            message: `Remove database "${entry.name}" (${entry.path})? This does not delete the database files.`,
            initialValue: false,
        });

        if (isCancel(confirmed) || !confirmed) {
            outro(pc.yellow('Cancelled.'));
            return;
        }
    }

    await removeDatabaseEntry(entry.path);
    outro(pc.green(`✓ Database "${entry.name}" removed from list.`));
}

//
// Options for the `dbs clear` command.
//
interface IDbsClearOptions {
    // Skip confirmation prompt.
    yes?: boolean;
}

//
// psi dbs clear — remove all database entries after confirmation.
//
async function dbsClear(cmdOptions: IDbsClearOptions): Promise<void> {
    const databases = await getDatabases();

    if (databases.length === 0) {
        log.info(pc.yellow('No databases configured.'));
        return;
    }

    if (!cmdOptions.yes) {
        log.info(pc.cyan(`\nDatabases to be removed:`));
        for (const dbEntry of databases) {
            log.info(`  ${dbEntry.name} (${dbEntry.path})`);
        }
        log.info('');

        const firstConfirm = await confirm({
            message: `Remove all ${databases.length} database(s) from the list? This does not delete database files.`,
            initialValue: false,
        });

        if (isCancel(firstConfirm) || !firstConfirm) {
            outro(pc.yellow('Cancelled.'));
            return;
        }

        const secondConfirm = await confirm({
            message: `Are you sure? All database entries will be permanently removed from the list.`,
            initialValue: false,
        });

        if (isCancel(secondConfirm) || !secondConfirm) {
            outro(pc.yellow('Cancelled.'));
            return;
        }
    }

    for (const dbEntry of databases) {
        await removeDatabaseEntry(dbEntry.path);
    }

    outro(pc.green(`✓ Removed ${databases.length} database(s) from the list.`));
}

//
// psi dbs send [name] — share a database config with secrets over the LAN.
//
export async function dbsSend(cmdOptions: IDbsSendOptions): Promise<void> {
    intro(pc.cyan('Send Database'));

    const skipPrompts = !!cmdOptions.yes;

    note(
        'Both devices must be on the same local network (wired or Wi-Fi).\nThis does not work over the internet.',
        pc.cyan('ℹ Network Requirement')
    );

    let entry: IDatabaseEntry | undefined;

    if (cmdOptions.name || cmdOptions.path) {
        entry = await findDatabaseByIdentifier(cmdOptions.name, cmdOptions.path);
        if (!entry) {
            log.error(pc.red(`✗ No database matching the given name or path was found.`));
            if (cmdOptions.name) {
                const similarNames = await findSimilarDatabaseNames(cmdOptions.name);
                if (similarNames.length > 0) {
                    log.info(`Did you mean:\n${similarNames.map(similarName => `  • ${pc.cyan(similarName)}`).join('\n')}`);
                }
            }
            await exit(1);
            return;
        }
    }
    else {
        // Pick from configured databases
        const databases = await getDatabases();
        if (databases.length === 0) {
            log.info(pc.yellow('No databases configured.'));
            log.info(pc.dim('Use "psi dbs add" to add a database first.'));
            return;
        }

        const selected = await select({
            message: 'Select a database to send:',
            options: databases.map(dbEntry => ({
                value: dbEntry.path,
                label: dbEntry.name,
            })),
        });

        if (isCancel(selected)) {
            outro(pc.yellow('Cancelled.'));
            return;
        }

        entry = databases.find(dbEntry => dbEntry.path === selected as string);
        if (!entry) {
            log.error(pc.red('✗ Database not found.'));
            await exit(1);
            return;
        }
    }

    // Resolve the database payload with secrets
    const payload = await resolveDatabaseSharePayload(entry);

    // Display resolved fields
    log.info(pc.cyan('\nDatabase to send:'));
    log.info(pc.cyan('  Name:        ') + payload.name);
    log.info(pc.cyan('  Description: ') + (payload.description || pc.dim('(none)')));
    log.info(pc.cyan('  Path:        ') + payload.path);
    if (payload.s3Credentials) {
        log.info(pc.cyan('  S3 Creds:    ') + payload.s3Credentials.label);
    }
    if (payload.encryptionKey) {
        log.info(pc.cyan('  Encryption:  ') + payload.encryptionKey.label);
    }
    if (payload.geocodingKey) {
        log.info(pc.cyan('  Geocoding:   ') + payload.geocodingKey.label);
    }
    log.info('');

    if (isLocalPath(payload.path)) {
        note(
            'The database path is a local filesystem path.\nThis works if the other device has access to the same path (e.g. a shared network drive),\nbut will need updating if the path is specific to this machine.',
            pc.yellow('⚠ Local Path')
        );
    }

    if (!skipPrompts) {
        // Allow editing fields
        const editedName = await text({
            message: 'Database name:',
            initialValue: payload.name,
            validate: (val) => {
                if (!val || val.trim().length === 0) {
                    return 'Name is required';
                }
                return undefined;
            },
        });
        if (isCancel(editedName)) {
            outro(pc.yellow('Cancelled.'));
            return;
        }
        payload.name = (editedName as string).trim();

        const editedDescription = await text({
            message: 'Description:',
            initialValue: payload.description || '',
        });
        if (isCancel(editedDescription)) {
            outro(pc.yellow('Cancelled.'));
            return;
        }
        payload.description = (editedDescription as string).trim();

        const editedPath = await text({
            message: 'Database path:',
            initialValue: payload.path,
            validate: (val) => {
                if (!val || val.trim().length === 0) {
                    return 'Path is required';
                }
                return undefined;
            },
        });
        if (isCancel(editedPath)) {
            outro(pc.yellow('Cancelled.'));
            return;
        }
        payload.path = (editedPath as string).trim();

        // Confirm which secrets to include
        if (payload.s3Credentials) {
            const includeS3 = await confirm({
                message: `Include S3 credentials (${payload.s3Credentials.label})?`,
                initialValue: true,
            });
            if (isCancel(includeS3)) {
                outro(pc.yellow('Cancelled.'));
                return;
            }
            if (!includeS3) {
                payload.s3Credentials = undefined;
            }
        }

        if (payload.encryptionKey) {
            const includeEnc = await confirm({
                message: `Include encryption key (${payload.encryptionKey.label})?`,
                initialValue: true,
            });
            if (isCancel(includeEnc)) {
                outro(pc.yellow('Cancelled.'));
                return;
            }
            if (!includeEnc) {
                payload.encryptionKey = undefined;
            }
        }

        if (payload.geocodingKey) {
            const includeGeo = await confirm({
                message: `Include geocoding key (${payload.geocodingKey.label})?`,
                initialValue: true,
            });
            if (isCancel(includeGeo)) {
                outro(pc.yellow('Cancelled.'));
                return;
            }
            if (!includeGeo) {
                payload.geocodingKey = undefined;
            }
        }
    }

    // Create sender (generates or uses supplied pairing code)
    const sender = new LanShareSender(payload, cmdOptions.code);

    // Display the pairing code — the user must enter this on the other device
    log.info('');
    log.info(pc.cyan(`  Pairing code: ${pc.bold(sender.pairingCode)}`));
    log.info(pc.dim('  Enter this code on the other device, then wait.'));
    log.info('');

    const spin = spinner();
    spin.start('Waiting for other device on local network... (Ctrl+C to cancel)');

    const sigintHandler = () => {
        sender.cancel();
    };
    process.on('SIGINT', sigintHandler);

    const endpoint = await sender.waitForReceiver(60000);
    process.removeListener('SIGINT', sigintHandler);

    if (!endpoint) {
        spin.stop(pc.yellow('No device found within 60 seconds.'));
        return;
    }

    spin.stop(pc.green('Device found!'));

    const success = await sender.send(endpoint);

    if (success) {
        outro(pc.green('✓ Database sent successfully!'));
    }
    else {
        log.error(pc.red('✗ Pairing code rejected by other device.'));
        await exit(1);
    }
}

//
// Builds a ConflictResolver for use during dbs receive.
// When skipPrompts is true the resolver logs a message and reuses the
// existing secret without prompting.  Otherwise it presents an interactive
// menu offering replace, reuse, or rename.
//
function buildConflictResolver(skipPrompts: boolean): ConflictResolver {
    return async (secretName: string, secretType: string): Promise<IConflictResolution> => {
        if (skipPrompts) {
            log.info(pc.yellow(`  ⚠ Secret "${secretName}" already exists — reusing existing.`));
            return { action: 'reuse' };
        }

        log.info('');

        const choice = await select({
            message: `Secret "${secretName}" (${secretType}) already exists in your vault. What would you like to do?`,
            options: [
                { value: 'reuse', label: 'Reuse existing — skip importing this secret' },
                { value: 'replace', label: `Replace existing — ⚠ may break other databases that use "${secretName}"` },
                { value: 'rename', label: 'Save with a new name' },
            ],
        });

        if (isCancel(choice)) {
            outro(pc.yellow('Cancelled.'));
            await exit(0);
        }

        if (choice === 'rename') {
            const newName = await text({
                message: 'New secret name:',
                initialValue: secretName,
                validate: (val) => {
                    if (!val || val.trim().length === 0) {
                        return 'Name is required';
                    }
                    return undefined;
                },
            });

            if (isCancel(newName)) {
                outro(pc.yellow('Cancelled.'));
                await exit(0);
            }

            return { action: 'rename', newName: (newName as string).trim() };
        }

        return { action: choice as 'replace' | 'reuse' };
    };
}

//
// psi dbs receive — receive a database config with secrets from another device.
//
async function dbsReceive(cmdOptions: { yes?: boolean; code?: string }): Promise<void> {
    intro(pc.cyan('Receive Database'));

    const skipPrompts = !!cmdOptions.yes;

    note(
        'Both devices must be on the same local network (wired or Wi-Fi).\nThis does not work over the internet.',
        pc.cyan('ℹ Network Requirement')
    );

    log.info(pc.dim('Hint: Run `psi dbs send` on another device to send a database.'));

    let code: string;

    if (skipPrompts) {
        if (!cmdOptions.code) {
            log.error(pc.red('✗ --code is required with --yes'));
            await exit(1);
            return;
        }
        code = cmdOptions.code;
    }
    else {
        const codeInput = await text({
            message: 'Enter the 4-digit pairing code shown on the other device:',
            validate: (val) => {
                if (!val || !/^\d{4}$/.test(val.trim())) {
                    return 'Please enter a 4-digit code';
                }
                return undefined;
            },
        });

        if (isCancel(codeInput)) {
            outro(pc.yellow('Cancelled.'));
            return;
        }

        code = (codeInput as string).trim();
    }

    const receiver = new LanShareReceiver(60000);
    await receiver.start(code);

    const spin = spinner();
    spin.start('Waiting for other device on local network... (Ctrl+C to cancel)');

    const sigintHandler = () => {
        receiver.cancel();
    };
    process.on('SIGINT', sigintHandler);

    const rawPayload = await receiver.receive();
    process.removeListener('SIGINT', sigintHandler);

    if (!rawPayload) {
        spin.stop(pc.yellow('No device connected within 60 seconds.'));
        return;
    }

    spin.stop(pc.green('Payload received!'));

    const payload = rawPayload as IDatabaseSharePayload;

    // Display received fields
    log.info(pc.cyan('\nReceived database:'));
    log.info(pc.cyan('  Name:        ') + payload.name);
    log.info(pc.cyan('  Description: ') + (payload.description || pc.dim('(none)')));
    log.info(pc.cyan('  Path:        ') + payload.path);
    if (payload.s3Credentials) {
        log.info(pc.cyan('  S3 Creds:    ') + payload.s3Credentials.label);
    }
    if (payload.encryptionKey) {
        log.info(pc.cyan('  Encryption:  ') + payload.encryptionKey.label);
    }
    if (payload.geocodingKey) {
        log.info(pc.cyan('  Geocoding:   ') + payload.geocodingKey.label);
    }
    log.info('');

    if (isLocalPath(payload.path)) {
        note(
            'The database path is a local filesystem path from the other device.\nThis works if you have access to the same path (e.g. a shared network drive),\nbut you may need to update it if the path is specific to their machine.',
            pc.yellow('⚠ Local Path')
        );
    }

    if (!skipPrompts) {
        // Allow editing fields before saving
        const editedName = await text({
            message: 'Database name:',
            initialValue: payload.name,
            validate: (val) => {
                if (!val || val.trim().length === 0) {
                    return 'Name is required';
                }
                return undefined;
            },
        });
        if (isCancel(editedName)) {
            outro(pc.yellow('Cancelled.'));
            return;
        }
        payload.name = (editedName as string).trim();

        const editedDescription = await text({
            message: 'Description:',
            initialValue: payload.description || '',
        });
        if (isCancel(editedDescription)) {
            outro(pc.yellow('Cancelled.'));
            return;
        }
        payload.description = (editedDescription as string).trim();

        const editedPath = await text({
            message: 'Database path:',
            initialValue: payload.path,
            validate: (val) => {
                if (!val || val.trim().length === 0) {
                    return 'Path is required';
                }
                return undefined;
            },
        });
        if (isCancel(editedPath)) {
            outro(pc.yellow('Cancelled.'));
            return;
        }
        payload.path = (editedPath as string).trim();

        // Confirm which secrets to import
        if (payload.s3Credentials) {
            const importS3 = await confirm({
                message: `Import S3 credentials (${payload.s3Credentials.label})?`,
                initialValue: true,
            });
            if (isCancel(importS3)) {
                outro(pc.yellow('Cancelled.'));
                return;
            }
            if (!importS3) {
                payload.s3Credentials = undefined;
            }
        }

        if (payload.encryptionKey) {
            const importEnc = await confirm({
                message: `Import encryption key (${payload.encryptionKey.label})?`,
                initialValue: true,
            });
            if (isCancel(importEnc)) {
                outro(pc.yellow('Cancelled.'));
                return;
            }
            if (!importEnc) {
                payload.encryptionKey = undefined;
            }
        }

        if (payload.geocodingKey) {
            const importGeo = await confirm({
                message: `Import geocoding key (${payload.geocodingKey.label})?`,
                initialValue: true,
            });
            if (isCancel(importGeo)) {
                outro(pc.yellow('Cancelled.'));
                return;
            }
            if (!importGeo) {
                payload.geocodingKey = undefined;
            }
        }
    }

    // Import the payload
    const dbEntry = await importDatabasePayload(payload, buildConflictResolver(skipPrompts));
    await addDatabaseEntry(dbEntry);

    outro(pc.green(`✓ Database "${dbEntry.name}" imported successfully!`));
}
