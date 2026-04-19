import { Command } from 'commander';
import pc from 'picocolors';
import { getVault } from 'vault';
import { getDatabases, addDatabaseEntry, updateDatabaseEntry, removeDatabaseEntry } from 'node-utils';
import { confirm, intro, outro, text, select, isCancel } from '../lib/clack/prompts';
import { exit } from 'node-utils';
import { generateKeyPair, exportPublicKeyToPem } from 'storage';
import type { IDatabaseEntry } from 'electron-defs';

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
        console.error(pc.red(`✗ Ambiguous name "${name}" — matches ${matches.length} entries:`));
        for (const match of matches) {
            console.error(`  • ${match.name} → ${match.path}`);
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
    const vault = getVault("plaintext");
    const secrets = await vault.list();

    // Find existing shared secrets of the matching type.
    const matchingSecrets = secrets
        .filter(secret => secret.name.startsWith('shared:') && secret.type === secretType)
        .map(secret => {
            const secretId = secret.name.slice('shared:'.length);
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
    const vault = getVault("plaintext");
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
            name: `shared:${secretId}`,
            type: 's3-credentials',
            value: JSON.stringify(value),
        });

        console.log(pc.green(`  ✓ S3 credential "${label}" created (${secretId})`));
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
            name: `shared:${secretId}`,
            type: 'encryption-key',
            value: JSON.stringify({ label, privateKeyPem, publicKeyPem }),
        });

        console.log(pc.green(`  ✓ Encryption key "${label}" created (${secretId})`));
    }
    else if (secretType === 'api-key') {
        const label = await promptRequired('Label for this API key:');
        const apiKey = await promptRequired('API key value:');

        await vault.set({
            name: `shared:${secretId}`,
            type: 'api-key',
            value: JSON.stringify({ label, apiKey }),
        });

        console.log(pc.green(`  ✓ API key "${label}" created (${secretId})`));
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
        .action(dbsAdd);

    // psi dbs view <name>
    cmd.command('view <name>')
        .description('Show all fields of a database entry.')
        .action(dbsView);

    // psi dbs edit <name>
    cmd.command('edit <name>')
        .description('Edit fields of a database entry.')
        .action(dbsEdit);

    // psi dbs remove <name>
    cmd.command('remove <name>')
        .description('Remove a database entry from the list.')
        .option('--yes', 'Skip confirmation prompt')
        .action(dbsRemove);

    return cmd;
}

//
// psi dbs list — table of all configured databases.
//
async function dbsList(): Promise<void> {
    const databases = await getDatabases();

    if (databases.length === 0) {
        console.log(pc.yellow('No databases configured.'));
        console.log(pc.dim('Use "psi dbs add" to add a database.'));
        return;
    }

    console.log(pc.cyan(`\n${'Name'.padEnd(25)} Path`));
    console.log('─'.repeat(70));

    for (const dbEntry of databases) {
        console.log(`${dbEntry.name.padEnd(25)} ${dbEntry.path}`);
    }

    console.log('');
}

//
// psi dbs add — interactively add a new database entry.
//
async function dbsAdd(): Promise<void> {
    intro(pc.cyan('Add Database'));

    const name = await promptRequired('Database name:');
    const description = await promptOptional('Description (optional):') || '';
    const dbPath = await promptRequired('Database path (filesystem or S3):');

    // Secret linking
    const s3CredentialId = await pickOrCreateSecret('s3-credentials', 'S3 credentials:');
    const encryptionKeyId = await pickOrCreateSecret('encryption-key', 'Encryption key:');
    const geocodingKeyId = await pickOrCreateSecret('api-key', 'Geocoding API key:');

    const entry: IDatabaseEntry = {
        name,
        description,
        path: dbPath,
        s3CredentialId,
        encryptionKeyId,
        geocodingKeyId,
    };

    await addDatabaseEntry(entry);

    outro(pc.green(`✓ Database "${name}" added.`));
}

//
// psi dbs view <name> — show all fields of a database entry.
//
async function dbsView(name: string): Promise<void> {
    const entry = await findDatabaseByName(name);

    if (!entry) {
        console.error(pc.red(`✗ No database named "${name}" found.`));
        await exit(1);
        return;
    }

    console.log(pc.cyan('\nDatabase Entry'));
    console.log('─'.repeat(50));
    console.log(pc.cyan('Name:        ') + entry.name);
    console.log(pc.cyan('Description: ') + (entry.description || pc.dim('(none)')));
    console.log(pc.cyan('Path:        ') + entry.path);

    if (entry.s3CredentialId) {
        console.log(pc.cyan('S3 Creds:    ') + entry.s3CredentialId);
    }
    else {
        console.log(pc.cyan('S3 Creds:    ') + pc.dim('(none)'));
    }

    if (entry.encryptionKeyId) {
        console.log(pc.cyan('Encryption:  ') + entry.encryptionKeyId);
    }
    else {
        console.log(pc.cyan('Encryption:  ') + pc.dim('(none)'));
    }

    if (entry.geocodingKeyId) {
        console.log(pc.cyan('Geocoding:   ') + entry.geocodingKeyId);
    }
    else {
        console.log(pc.cyan('Geocoding:   ') + pc.dim('(none)'));
    }

    if (entry.origin) {
        console.log(pc.cyan('Origin:      ') + entry.origin);
    }

    console.log('');
}

//
// psi dbs edit <name> — edit fields with current values pre-populated.
//
async function dbsEdit(name: string): Promise<void> {
    const entry = await findDatabaseByName(name);

    if (!entry) {
        console.error(pc.red(`✗ No database named "${name}" found.`));
        await exit(1);
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
    const s3CredentialId = await pickOrCreateSecret('s3-credentials', 'S3 credentials:', entry.s3CredentialId);
    const encryptionKeyId = await pickOrCreateSecret('encryption-key', 'Encryption key:', entry.encryptionKeyId);
    const geocodingKeyId = await pickOrCreateSecret('api-key', 'Geocoding API key:', entry.geocodingKeyId);

    const updated: IDatabaseEntry = {
        name: (newName as string).trim(),
        description: (newDescription as string).trim(),
        path: (newPath as string).trim(),
        origin: entry.origin,
        s3CredentialId,
        encryptionKeyId,
        geocodingKeyId,
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
// psi dbs remove <name> — remove a database entry after confirmation.
//
async function dbsRemove(name: string, cmdOptions: { yes?: boolean }): Promise<void> {
    const entry = await findDatabaseByName(name);

    if (!entry) {
        console.error(pc.red(`✗ No database named "${name}" found.`));
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
