import { Command } from 'commander';
import pc from 'picocolors';
import { getVault } from 'vault';
import { confirm, intro, outro, text, password, select, isCancel, spinner, note } from '../lib/clack/prompts';
import { exit } from 'node-utils';
import * as fs from 'fs/promises';
import { existsSync } from 'fs';
import { generateKeyPair, exportPublicKeyToPem } from 'storage';
import { LanShareSender, LanShareReceiver, resolveSecretSharePayload, importSecretPayload } from 'lan-share';
import type { ISecretSharePayload } from 'lan-share';

//
// Secret types supported by the secrets CLI.
//
const SECRET_TYPES = ['api-key', 's3-credentials', 'encryption-key', 'plain'];

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
// Returns the Commander sub-command group for `psi secrets`.
//
export function secretsCommand(): Command {
    const cmd = new Command('secrets')
        .description('Manage secrets stored in the Photosphere secrets store.');

    // psi secrets add
    cmd.command('add')
        .description('Interactively add a new secret.')
        .action(secretsAdd);

    // psi secrets list
    cmd.command('list')
        .description('List all secrets (values are masked).')
        .action(secretsList);

    // psi secrets view <name>
    cmd.command('view <name>')
        .description('Show the full value of a named secret.')
        .action(secretsView);

    // psi secrets edit <name>
    cmd.command('edit <name>')
        .description('Edit an existing secret, field by field.')
        .action(secretsEdit);

    // psi secrets delete <name>
    cmd.command('delete <name>')
        .description('Delete a named secret.')
        .action(secretsDelete);

    // psi secrets import
    cmd.command('import')
        .description('Import a .key / .key.pub PEM key pair file.')
        .action(secretsImport);

    // psi secrets send [name]
    cmd.command('send [name]')
        .description('Send a secret to another device over the LAN.')
        .option('--yes', 'Skip confirmation prompts')
        .option('--code <code>', 'Pairing code (required with --yes)')
        .action(secretsSend);

    // psi secrets receive
    cmd.command('receive')
        .description('Receive a secret from another device over the LAN.')
        .option('--yes', 'Skip confirmation prompts and field editing')
        .action(secretsReceive);

    return cmd;
}

//
// psi secrets add — prompt for name, type, value, then store.
//
async function secretsAdd(): Promise<void> {
    intro(pc.cyan('Add Secret'));

    const vault = getVault("plaintext");

    const name = await text({
        message: 'Secret name (e.g. cli:geocoding or db:abc123:s3):',
        validate: (value) => {
            if (!value || value.trim().length === 0) {
                return 'Name is required';
            }
            return undefined;
        },
    });

    if (isCancel(name)) {
        outro(pc.yellow('Cancelled.'));
        return;
    }

    const type = await select({
        message: 'Secret type:',
        options: SECRET_TYPES.map(secretType => ({ value: secretType, label: secretType })),
    });

    if (isCancel(type)) {
        outro(pc.yellow('Cancelled.'));
        return;
    }

    const value = await password({
        message: 'Secret value:',
        validate: (val) => {
            if (!val || val.trim().length === 0) {
                return 'Value is required';
            }
            return undefined;
        },
    });

    if (isCancel(value)) {
        outro(pc.yellow('Cancelled.'));
        return;
    }

    await vault.set({ name: (name as string).trim(), type: type as string, value: value as string });

    outro(pc.green(`✓ Secret "${name}" added.`));
}

//
// psi secrets list — print all secrets with masked values.
//
async function secretsList(): Promise<void> {
    const vault = getVault("plaintext");
    const secrets = await vault.list();

    if (secrets.length === 0) {
        console.log(pc.yellow('No secrets found.'));
        return;
    }

    console.log(pc.cyan(`\n${'Name'.padEnd(40)} ${'Type'.padEnd(20)} Value`));
    console.log('─'.repeat(80));

    for (const secret of secrets) {
        const masked = '****';
        console.log(`${secret.name.padEnd(40)} ${secret.type.padEnd(20)} ${masked}`);
    }

    console.log('');
}

//
// psi secrets view <name> — show the full value after confirmation.
//
async function secretsView(name: string): Promise<void> {
    const vault = getVault("plaintext");
    const secret = await vault.get(name);

    if (!secret) {
        console.error(pc.red(`✗ No secret named "${name}" found.`));
        await exit(1);
        return;
    }

    const confirmed = await confirm({
        message: `Reveal the value of "${name}"? (This will display sensitive data.)`,
        initialValue: false,
    });

    if (isCancel(confirmed) || !confirmed) {
        outro(pc.yellow('Cancelled.'));
        return;
    }

    console.log(pc.cyan(`\nName: `) + secret.name);
    console.log(pc.cyan(`Type: `) + secret.type);

    if (secret.type === 's3-credentials' || secret.type === 'encryption-key') {
        try {
            const parsed = JSON.parse(secret.value);
            console.log(pc.cyan(`Value:`));
            for (const [fieldKey, fieldVal] of Object.entries(parsed)) {
                console.log(`  ${fieldKey}: ${fieldVal}`);
            }
        }
        catch {
            console.log(pc.cyan(`Value: `) + secret.value);
        }
    }
    else {
        console.log(pc.cyan(`Value: `) + secret.value);
    }

    console.log('');
}

//
// psi secrets edit <name> — reload existing fields and re-prompt with current values pre-populated.
//
async function secretsEdit(name: string): Promise<void> {
    intro(pc.cyan(`Edit Secret: ${name}`));

    const vault = getVault("plaintext");
    const secret = await vault.get(name);

    if (!secret) {
        outro(pc.red(`✗ No secret named "${name}" found.`));
        await exit(1);
        return;
    }

    const newValue = await password({
        message: `New value (leave blank to keep current):`,
    });

    if (isCancel(newValue)) {
        outro(pc.yellow('Cancelled.'));
        return;
    }

    const updated = (newValue as string).trim();
    if (updated.length > 0) {
        await vault.set({ name: secret.name, type: secret.type, value: updated });
        outro(pc.green(`✓ Secret "${name}" updated.`));
    }
    else {
        outro(pc.yellow('No changes made.'));
    }
}

//
// psi secrets delete <name> — delete a secret after confirmation.
//
async function secretsDelete(name: string): Promise<void> {
    const vault = getVault("plaintext");
    const secret = await vault.get(name);

    if (!secret) {
        console.error(pc.red(`✗ No secret named "${name}" found.`));
        await exit(1);
        return;
    }

    const confirmed = await confirm({
        message: `Delete secret "${name}"? This cannot be undone.`,
        initialValue: false,
    });

    if (isCancel(confirmed) || !confirmed) {
        outro(pc.yellow('Cancelled.'));
        return;
    }

    await vault.delete(name);
    outro(pc.green(`✓ Secret "${name}" deleted.`));
}

//
// psi secrets import — import a .key / .key.pub PEM file pair into the secrets store.
//
async function secretsImport(): Promise<void> {
    intro(pc.cyan('Import Encryption Key'));

    const privateKeyPath = await text({
        message: 'Path to the private key file (.key):',
        validate: (value) => {
            if (!value || value.trim().length === 0) {
                return 'Path is required';
            }
            if (!existsSync(value.trim())) {
                return `File not found: ${value.trim()}`;
            }
            return undefined;
        },
    });

    if (isCancel(privateKeyPath)) {
        outro(pc.yellow('Cancelled.'));
        return;
    }

    const privatePath = (privateKeyPath as string).trim();
    const defaultPublicPath = `${privatePath}.pub`;
    let publicPath = defaultPublicPath;

    try {
        await fs.access(defaultPublicPath);
    }
    catch {
        const publicKeyPath = await text({
            message: `Public key file not found at "${defaultPublicPath}". Enter the path:`,
            validate: (value) => {
                if (!value || value.trim().length === 0) {
                    return 'Path is required';
                }
                if (!existsSync(value.trim())) {
                    return `File not found: ${value.trim()}`;
                }
                return undefined;
            },
        });

        if (isCancel(publicKeyPath)) {
            outro(pc.yellow('Cancelled.'));
            return;
        }

        publicPath = (publicKeyPath as string).trim();
    }

    const defaultKeyName = privatePath.split('/').pop()?.replace(/\.key$/, '') ?? 'imported-key';

    const keyNameInput = await text({
        message: 'Key name:',
        initialValue: defaultKeyName,
        validate: (value) => {
            if (!value || value.trim().length === 0) {
                return 'Name is required';
            }
            return undefined;
        },
    });

    if (isCancel(keyNameInput)) {
        outro(pc.yellow('Cancelled.'));
        return;
    }

    const keyName = (keyNameInput as string).trim();
    const privateKeyPem = await fs.readFile(privatePath, 'utf-8');
    const publicKeyPem = await fs.readFile(publicPath, 'utf-8');

    const vault = getVault("plaintext");
    await vault.set({
        name: `cli:encryption:${keyName}`,
        type: 'encryption-key',
        value: JSON.stringify({ privateKeyPem, publicKeyPem }),
    });

    outro(pc.green(`✓ Key imported as "cli:encryption:${keyName}".`));
}

//
// psi secrets send [name] — share a secret with another device over the LAN.
//
async function secretsSend(name: string | undefined, cmdOptions: { yes?: boolean; code?: string }): Promise<void> {
    intro(pc.cyan('Send Secret'));

    const skipPrompts = !!cmdOptions.yes;
    const vault = getVault("plaintext");
    let secretName: string;

    if (name) {
        const secret = await vault.get(name);
        if (!secret) {
            console.error(pc.red(`✗ No secret named "${name}" found.`));
            await exit(1);
            return;
        }
        secretName = name;
    }
    else {
        // Pick from all vault secrets
        const secrets = await vault.list();
        if (secrets.length === 0) {
            console.log(pc.yellow('No secrets found.'));
            console.log(pc.dim('Use "psi secrets add" to add a secret first.'));
            return;
        }

        const selected = await select({
            message: 'Select a secret to send:',
            options: secrets.map(secret => ({
                value: secret.name,
                label: `${secret.name} (${secret.type})`,
            })),
        });

        if (isCancel(selected)) {
            outro(pc.yellow('Cancelled.'));
            return;
        }

        secretName = selected as string;
    }

    console.log(pc.dim('Hint: Run `psi secrets receive` on another device to receive this secret.'));

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

    // Build the payload
    const payload = await resolveSecretSharePayload(secretName);

    console.log(pc.cyan('\nSecret to send:'));
    console.log(pc.cyan('  Name: ') + secretName);
    console.log(pc.cyan('  Type: ') + payload.secretType);
    console.log('');

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
        outro(pc.green('✓ Secret sent successfully!'));
    }
    else {
        console.error(pc.red('✗ Pairing code rejected by receiver.'));
        await exit(1);
    }
}

//
// psi secrets receive — receive a secret from another device over the LAN.
//
async function secretsReceive(cmdOptions: { yes?: boolean }): Promise<void> {
    intro(pc.cyan('Receive Secret'));

    const skipPrompts = !!cmdOptions.yes;

    console.log(pc.dim('Hint: Run `psi secrets send` on another device to send a secret.'));

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

    const payload = rawPayload as ISecretSharePayload;

    console.log(pc.cyan('\nReceived secret:'));
    console.log(pc.cyan('  Type: ') + payload.secretType);
    console.log('');

    let saveName: string;

    if (skipPrompts) {
        // Auto-generate a save name from the payload label or a random ID.
        let defaultName = "";
        try {
            const parsed = JSON.parse(payload.value);
            if (parsed.label) {
                defaultName = parsed.label;
            }
        }
        catch {
            // Ignore parse errors.
        }
        saveName = `shared:${defaultName || generateSharedSecretId()}`;
    }
    else {
        // Ask what name to save it as
        const nameInput = await text({
            message: 'Save secret as (name):',
            validate: (val) => {
                if (!val || val.trim().length === 0) {
                    return 'Name is required';
                }
                return undefined;
            },
        });

        if (isCancel(nameInput)) {
            outro(pc.yellow('Cancelled.'));
            return;
        }

        saveName = (nameInput as string).trim();
    }

    await importSecretPayload(payload, saveName);

    outro(pc.green(`✓ Secret "${saveName}" imported successfully!`));
}
