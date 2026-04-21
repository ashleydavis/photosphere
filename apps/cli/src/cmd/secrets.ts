import { Command } from 'commander';
import pc from 'picocolors';
import { getVault, getDefaultVaultType } from 'vault';
import { confirm, intro, outro, text, password, select, isCancel, spinner, note } from '../lib/clack/prompts';
import { exit } from 'node-utils';
import * as fs from 'fs/promises';
import { existsSync } from 'fs';
import { generateKeyPair, exportPublicKeyToPem } from 'storage';
import { createPrivateKey, createPublicKey } from 'node:crypto';
import { LanShareSender, LanShareReceiver, resolveSecretSharePayload, importSecretPayload } from 'lan-share';
import type { ISecretSharePayload } from 'lan-share';

//
// Secret types supported by the secrets CLI.
//
const SECRET_TYPES = ['api-key', 's3-credentials', 'encryption-key', 'plain'];

//
// Checks that the vault's required tools are present.
// Prints an actionable error and exits with code 1 if any prerequisite is missing.
//
async function checkVaultPrereqs(): Promise<void> {
    const vault = getVault(getDefaultVaultType());
    const result = await vault.checkPrereqs();
    if (!result.ok) {
        console.error(pc.red(`✗ ${result.message}`));
        await exit(1);
    }
}

//
// Options for the `secrets add` command.
//
interface ISecretsAddOptions {
    // Skip interactive prompts.
    yes?: boolean;
    // Secret name.
    name?: string;
    // Secret type.
    type?: string;
    // Secret value.
    value?: string;
}

//
// Options for the `secrets view` command.
//
interface ISecretsViewOptions {
    // Skip confirmation prompt.
    yes?: boolean;
}

//
// Options for the `secrets edit` command.
//
interface ISecretsEditOptions {
    // Skip interactive prompts.
    yes?: boolean;
    // New secret name.
    name?: string;
    // New secret value.
    value?: string;
}

//
// Options for the `secrets delete` command.
//
interface ISecretsDeleteOptions {
    // Skip confirmation prompt.
    yes?: boolean;
}

//
// Options for the `secrets import` command.
//
interface ISecretsImportOptions {
    // Skip interactive prompts.
    yes?: boolean;
    // Path to the private key file.
    privateKey?: string;
    // Path to the public key file.
    publicKey?: string;
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
// Returns the Commander sub-command group for `psi secrets`.
//
export function secretsCommand(): Command {
    const cmd = new Command('secrets')
        .description('Manage secrets stored in the Photosphere secrets store.');

    // psi secrets add
    cmd.command('add')
        .description('Interactively add a new secret.')
        .option('--yes', 'Skip prompts')
        .option('--name <name>', 'Secret name')
        .option('--type <type>', 'Secret type')
        .option('--value <value>', 'Secret value')
        .action(secretsAdd);

    // psi secrets list
    cmd.command('list')
        .description('List all secrets (values are masked).')
        .action(secretsList);

    // psi secrets view [name]
    cmd.command('view [name]')
        .description('Show the full value of a named secret.')
        .option('--yes', 'Skip confirmation prompt')
        .action(secretsView);

    // psi secrets edit [name]
    cmd.command('edit [name]')
        .description('Edit an existing secret, field by field.')
        .option('--yes', 'Skip prompts')
        .option('--name <name>', 'New secret name')
        .option('--value <value>', 'New value')
        .action(secretsEdit);

    // psi secrets delete [name]
    cmd.command('delete [name]')
        .description('Delete a named secret.')
        .option('--yes', 'Skip confirmation prompt')
        .action(secretsDelete);

    // psi secrets import
    cmd.command('import')
        .description('Import a .key / .key.pub PEM key pair file.')
        .option('--yes', 'Skip prompts')
        .option('--private-key <path>', 'Path to private key file')
        .option('--public-key <path>', 'Path to public key file')
        .action(secretsImport);

    // psi secrets send [name]
    cmd.command('send [name]')
        .description('Send a secret to another device over the LAN.')
        .option('--yes', 'Skip confirmation prompts')
        .option('--code <code>', 'Use a specific pairing code instead of generating one (useful for scripted use)')
        .action(secretsSend);

    // psi secrets receive
    cmd.command('receive')
        .description('Receive a secret from another device over the LAN.')
        .option('--yes', 'Skip confirmation prompts and field editing')
        .option('--code <code>', 'Pairing code shown on the sender (required with --yes)')
        .action(secretsReceive);

    return cmd;
}

//
// psi secrets add — prompt for name, type, value, then store.
//
async function secretsAdd(cmdOptions: ISecretsAddOptions): Promise<void> {
    await checkVaultPrereqs();
    const vault = getVault(getDefaultVaultType());

    if (cmdOptions.yes) {
        if (!cmdOptions.name || !cmdOptions.type || !cmdOptions.value) {
            console.error(pc.red('✗ --name, --type, and --value are required with --yes'));
            await exit(1);
            return;
        }

        if (!SECRET_TYPES.includes(cmdOptions.type)) {
            console.error(pc.red(`✗ Invalid secret type "${cmdOptions.type}". Must be one of: ${SECRET_TYPES.join(', ')}`));
            await exit(1);
            return;
        }

        await vault.set({ name: cmdOptions.name.trim(), type: cmdOptions.type, value: cmdOptions.value });
        console.log(pc.green(`✓ Secret "${cmdOptions.name}" added.`));
        return;
    }

    intro(pc.cyan('Add Secret'));

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
    await checkVaultPrereqs();
    const vault = getVault(getDefaultVaultType());
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
// psi secrets view [name] — show the full value after confirmation.
//
async function secretsView(name: string | undefined, cmdOptions: ISecretsViewOptions): Promise<void> {
    await checkVaultPrereqs();
    const vault = getVault(getDefaultVaultType());

    if (!name) {
        if (cmdOptions.yes) {
            console.error(pc.red('✗ <name> is required with --yes'));
            await exit(1);
            return;
        }

        const secrets = await vault.list();
        if (secrets.length === 0) {
            console.log(pc.yellow('No secrets found.'));
            return;
        }

        const selected = await select({
            message: 'Select a secret to view:',
            options: secrets.map(secret => ({
                value: secret.name,
                label: `${secret.name} (${secret.type})`,
            })),
        });

        if (isCancel(selected)) {
            outro(pc.yellow('Cancelled.'));
            return;
        }

        name = selected as string;
    }

    const secret = await vault.get(name);

    if (!secret) {
        console.error(pc.red(`✗ No secret named "${name}" found.`));
        await exit(1);
        return;
    }

    if (!cmdOptions.yes) {
        const confirmed = await confirm({
            message: `Reveal the value of "${name}"? (This will display sensitive data.)`,
            initialValue: false,
        });

        if (isCancel(confirmed) || !confirmed) {
            outro(pc.yellow('Cancelled.'));
            return;
        }
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
// psi secrets edit [name] — reload existing fields and re-prompt with current values pre-populated.
//
async function secretsEdit(name: string | undefined, cmdOptions: ISecretsEditOptions): Promise<void> {
    await checkVaultPrereqs();
    const vault = getVault(getDefaultVaultType());

    if (!name) {
        if (cmdOptions.yes) {
            console.error(pc.red('✗ <name> is required with --yes'));
            await exit(1);
            return;
        }

        const secrets = await vault.list();
        if (secrets.length === 0) {
            console.log(pc.yellow('No secrets found.'));
            return;
        }

        const selected = await select({
            message: 'Select a secret to edit:',
            options: secrets.map(secret => ({
                value: secret.name,
                label: `${secret.name} (${secret.type})`,
            })),
        });

        if (isCancel(selected)) {
            outro(pc.yellow('Cancelled.'));
            return;
        }

        name = selected as string;
    }

    const secret = await vault.get(name);

    if (!secret) {
        console.error(pc.red(`✗ No secret named "${name}" found.`));
        await exit(1);
        return;
    }

    if (cmdOptions.yes) {
        if (!cmdOptions.name && !cmdOptions.value) {
            console.error(pc.red('✗ --name or --value is required with --yes'));
            await exit(1);
            return;
        }

        const updatedName = cmdOptions.name?.trim() || secret.name;
        const updatedValue = cmdOptions.value || secret.value;

        if (updatedName !== secret.name) {
            await vault.delete(secret.name);
        }

        await vault.set({ name: updatedName, type: secret.type, value: updatedValue });
        console.log(pc.green(`✓ Secret "${updatedName}" updated.`));
        return;
    }

    intro(pc.cyan(`Edit Secret: ${name}`));

    const newName = await text({
        message: 'Secret name:',
        initialValue: secret.name,
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

    const newValue = await password({
        message: `New value (leave blank to keep current):`,
    });

    if (isCancel(newValue)) {
        outro(pc.yellow('Cancelled.'));
        return;
    }

    const updatedName = (newName as string).trim();
    const updatedValue = newValue ? (newValue as string).trim() : secret.value;

    if (updatedName === secret.name && updatedValue === secret.value) {
        outro(pc.yellow('No changes made.'));
        return;
    }

    if (updatedName !== secret.name) {
        await vault.delete(secret.name);
    }

    await vault.set({ name: updatedName, type: secret.type, value: updatedValue });
    outro(pc.green(`✓ Secret "${updatedName}" updated.`));
}

//
// psi secrets delete [name] — delete a secret after confirmation.
//
async function secretsDelete(name: string | undefined, cmdOptions: ISecretsDeleteOptions): Promise<void> {
    await checkVaultPrereqs();
    const vault = getVault(getDefaultVaultType());

    if (!name) {
        if (cmdOptions.yes) {
            console.error(pc.red('✗ <name> is required with --yes'));
            await exit(1);
            return;
        }

        const secrets = await vault.list();
        if (secrets.length === 0) {
            console.log(pc.yellow('No secrets found.'));
            return;
        }

        const selected = await select({
            message: 'Select a secret to delete:',
            options: secrets.map(secret => ({
                value: secret.name,
                label: `${secret.name} (${secret.type})`,
            })),
        });

        if (isCancel(selected)) {
            outro(pc.yellow('Cancelled.'));
            return;
        }

        name = selected as string;
    }

    const secret = await vault.get(name);

    if (!secret) {
        console.error(pc.red(`✗ No secret named "${name}" found.`));
        await exit(1);
        return;
    }

    if (!cmdOptions.yes) {
        const confirmed = await confirm({
            message: `Delete secret "${name}"? This cannot be undone.`,
            initialValue: false,
        });

        if (isCancel(confirmed) || !confirmed) {
            outro(pc.yellow('Cancelled.'));
            return;
        }
    }

    await vault.delete(name);
    outro(pc.green(`✓ Secret "${name}" deleted.`));
}

//
// psi secrets import — import a .key / .key.pub PEM file pair into the secrets store.
//
async function secretsImport(cmdOptions: ISecretsImportOptions): Promise<void> {
    await checkVaultPrereqs();
    if (cmdOptions.yes) {
        if (!cmdOptions.privateKey) {
            console.error(pc.red('✗ --private-key is required with --yes'));
            await exit(1);
            return;
        }

        const privatePath = cmdOptions.privateKey.trim();
        if (!existsSync(privatePath)) {
            console.error(pc.red(`✗ File not found: ${privatePath}`));
            await exit(1);
            return;
        }

        const keyName = privatePath.split('/').pop()?.replace(/\.key$/, '') || 'imported-key';
        const privateKeyPem = await fs.readFile(privatePath, 'utf-8');
        let publicKeyPem: string;
        const publicPath = cmdOptions.publicKey?.trim() || `${privatePath}.pub`;
        if (existsSync(publicPath)) {
            publicKeyPem = await fs.readFile(publicPath, 'utf-8');
        }
        else {
            const privateKeyObj = createPrivateKey(privateKeyPem);
            publicKeyPem = exportPublicKeyToPem(createPublicKey(privateKeyObj));
        }

        const vault = getVault(getDefaultVaultType());
        await vault.set({
            name: keyName,
            type: 'encryption-key',
            value: JSON.stringify({ privateKeyPem, publicKeyPem }),
        });

        console.log(pc.green(`✓ Key imported as "${keyName}".`));
        return;
    }

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
    const keyName = privatePath.split('/').pop()?.replace(/\.key$/, '') ?? 'imported-key';
    const privateKeyPem = await fs.readFile(privatePath, 'utf-8');
    let publicKeyPem: string;
    const defaultPublicPath = `${privatePath}.pub`;
    if (existsSync(defaultPublicPath)) {
        publicKeyPem = await fs.readFile(defaultPublicPath, 'utf-8');
    }
    else {
        const privateKeyObj = createPrivateKey(privateKeyPem);
        publicKeyPem = exportPublicKeyToPem(createPublicKey(privateKeyObj));
    }

    const vault = getVault(getDefaultVaultType());
    await vault.set({
        name: keyName,
        type: 'encryption-key',
        value: JSON.stringify({ privateKeyPem, publicKeyPem }),
    });

    outro(pc.green(`✓ Key imported as "${keyName}".`));
}

//
// psi secrets send [name] — share a secret with another device over the LAN.
//
async function secretsSend(name: string | undefined, cmdOptions: { yes?: boolean; code?: string }): Promise<void> {
    await checkVaultPrereqs();
    intro(pc.cyan('Send Secret'));

    const skipPrompts = !!cmdOptions.yes;
    const vault = getVault(getDefaultVaultType());
    let secretName: string;

    note(
        'Both devices must be on the same local network (wired or Wi-Fi).\nThis does not work over the internet.',
        pc.cyan('ℹ Network Requirement')
    );

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

    // Create sender (generates or uses supplied pairing code)
    const sender = new LanShareSender(payload, cmdOptions.code);

    // Display the pairing code — the user must enter this on the receiver device
    console.log(pc.cyan(`  Pairing code: ${pc.bold(sender.pairingCode)}`));
    console.log(pc.dim('  Enter this code on the receiver device, then wait.'));
    console.log('');

    const spin = spinner();
    spin.start('Waiting for receiver on the LAN... (Ctrl+C to cancel)');

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

    const success = await sender.send(endpoint);

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
async function secretsReceive(cmdOptions: { yes?: boolean; code?: string }): Promise<void> {
    await checkVaultPrereqs();
    intro(pc.cyan('Receive Secret'));

    const skipPrompts = !!cmdOptions.yes;

    note(
        'Both devices must be on the same local network (wired or Wi-Fi).\nThis does not work over the internet.',
        pc.cyan('ℹ Network Requirement')
    );

    console.log(pc.dim('Hint: Run `psi secrets send` on another device to send a secret.'));

    let code: string;

    if (skipPrompts) {
        if (!cmdOptions.code) {
            console.error(pc.red('✗ --code is required with --yes'));
            await exit(1);
            return;
        }
        code = cmdOptions.code;
    }
    else {
        const codeInput = await text({
            message: 'Enter the 4-digit pairing code shown on the sender:',
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
    spin.start('Waiting for sender on the LAN... (Ctrl+C to cancel)');

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
        saveName = defaultName || generateSharedSecretId();
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
