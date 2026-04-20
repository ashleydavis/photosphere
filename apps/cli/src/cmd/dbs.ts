import { Command } from 'commander';
import pc from 'picocolors';
import { getVault } from 'vault';
import { getDatabases, addDatabaseEntry, updateDatabaseEntry, removeDatabaseEntry } from 'node-utils';
import { confirm, intro, outro, text, select, isCancel, spinner, note } from '../lib/clack/prompts';
import { exit } from 'node-utils';
import { generateKeyPair, exportPublicKeyToPem } from 'storage';
import type { IDatabaseEntry } from 'electron-defs';
import { LanShareSender, LanShareReceiver, resolveDatabaseSharePayload, importDatabasePayload } from 'lan-share';
import type { IDatabaseSharePayload } from 'lan-share';

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

    // psi dbs send [name]
    cmd.command('send [name]')
        .description('Send a database config (with secrets) to another device over the LAN.')
        .option('--yes', 'Skip confirmation prompts and field editing')
        .option('--code <code>', 'Pairing code (required with --yes)')
        .action(dbsSend);

    // psi dbs receive
    cmd.command('receive')
        .description('Receive a database config (with secrets) from another device over the LAN.')
        .option('--yes', 'Skip confirmation prompts and field editing')
        .action(dbsReceive);

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

//
// psi dbs send [name] — share a database config with secrets over the LAN.
//
async function dbsSend(name: string | undefined, cmdOptions: { yes?: boolean; code?: string }): Promise<void> {
    intro(pc.cyan('Send Database'));

    const skipPrompts = !!cmdOptions.yes;

    let entry: IDatabaseEntry | undefined;

    if (name) {
        entry = await findDatabaseByName(name);
        if (!entry) {
            console.error(pc.red(`✗ No database named "${name}" found.`));
            await exit(1);
            return;
        }
    }
    else {
        // Pick from configured databases
        const databases = await getDatabases();
        if (databases.length === 0) {
            console.log(pc.yellow('No databases configured.'));
            console.log(pc.dim('Use "psi dbs add" to add a database first.'));
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
            console.error(pc.red('✗ Database not found.'));
            await exit(1);
            return;
        }
    }

    console.log(pc.dim('Hint: Run `psi dbs receive` on another device to receive this database.'));

    // Security warning
    note(
        'This will share sensitive credentials over your local network.\nOnly use this on a trusted network.',
        pc.yellow('⚠ Security Warning')
    );

    if (!skipPrompts) {
        const confirmed = await confirm({
            message: 'Continue with sending?',
            initialValue: true,
        });

        if (isCancel(confirmed) || !confirmed) {
            outro(pc.yellow('Cancelled.'));
            return;
        }
    }

    // Resolve the database payload with secrets
    const payload = await resolveDatabaseSharePayload(entry);

    // Display resolved fields
    console.log(pc.cyan('\nDatabase to send:'));
    console.log(pc.cyan('  Name:        ') + payload.name);
    console.log(pc.cyan('  Description: ') + (payload.description || pc.dim('(none)')));
    console.log(pc.cyan('  Path:        ') + payload.path);
    if (payload.s3Credentials) {
        console.log(pc.cyan('  S3 Creds:    ') + payload.s3Credentials.label);
    }
    if (payload.encryptionKey) {
        console.log(pc.cyan('  Encryption:  ') + payload.encryptionKey.label);
    }
    if (payload.geocodingKey) {
        console.log(pc.cyan('  Geocoding:   ') + payload.geocodingKey.label);
    }
    console.log('');

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

    // Search for receiver
    const sender = new LanShareSender(payload);
    const spin = spinner();
    spin.start('Searching for receiver on the LAN... (Ctrl+C to cancel)');

    const sigintHandler = () => {
        sender.cancel();
    };
    process.on('SIGINT', sigintHandler);

    const endpoint = await sender.waitForReceiver(60000);
    process.removeListener('SIGINT', sigintHandler);

    if (!endpoint) {
        spin.stop(pc.yellow('No receiver found within 60 seconds.'));
        return;
    }

    spin.stop(pc.green('Receiver found!'));

    let code: string;

    if (skipPrompts) {
        if (!cmdOptions.code) {
            console.error(pc.red('✗ --code is required when using --yes'));
            await exit(1);
            return;
        }
        code = cmdOptions.code;
    }
    else {
        // Prompt for pairing code
        const codeInput = await text({
            message: 'Enter the 4-digit pairing code shown on the receiver:',
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

    const success = await sender.send(endpoint, code);

    if (success) {
        outro(pc.green('✓ Database sent successfully!'));
    }
    else {
        console.error(pc.red('✗ Pairing code rejected by receiver.'));
        await exit(1);
    }
}

//
// psi dbs receive — receive a database config with secrets from another device.
//
async function dbsReceive(cmdOptions: { yes?: boolean }): Promise<void> {
    intro(pc.cyan('Receive Database'));

    const skipPrompts = !!cmdOptions.yes;

    console.log(pc.dim('Hint: Run `psi dbs send` on another device to send a database.'));

    const receiver = new LanShareReceiver(60000);
    const receiverInfo = await receiver.start();

    console.log('');
    console.log(pc.cyan(`  Pairing code: ${pc.bold(receiverInfo.code)}`));
    console.log('');

    const spin = spinner();
    spin.start(`Waiting for sender... Code: ${receiverInfo.code} (Ctrl+C to cancel)`);

    const sigintHandler = () => {
        receiver.cancel();
    };
    process.on('SIGINT', sigintHandler);

    const rawPayload = await receiver.receive();
    process.removeListener('SIGINT', sigintHandler);

    if (!rawPayload) {
        spin.stop(pc.yellow('No sender connected within 60 seconds.'));
        return;
    }

    spin.stop(pc.green('Payload received!'));

    const payload = rawPayload as IDatabaseSharePayload;

    // Display received fields
    console.log(pc.cyan('\nReceived database:'));
    console.log(pc.cyan('  Name:        ') + payload.name);
    console.log(pc.cyan('  Description: ') + (payload.description || pc.dim('(none)')));
    console.log(pc.cyan('  Path:        ') + payload.path);
    if (payload.s3Credentials) {
        console.log(pc.cyan('  S3 Creds:    ') + payload.s3Credentials.label);
    }
    if (payload.encryptionKey) {
        console.log(pc.cyan('  Encryption:  ') + payload.encryptionKey.label);
    }
    if (payload.geocodingKey) {
        console.log(pc.cyan('  Geocoding:   ') + payload.geocodingKey.label);
    }
    console.log('');

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
    const dbEntry = await importDatabasePayload(payload);
    await addDatabaseEntry(dbEntry);

    outro(pc.green(`✓ Database "${dbEntry.name}" imported successfully!`));
}
