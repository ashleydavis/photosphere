import { Command } from 'commander';
import pc from 'picocolors';
import { getVault, getDefaultVaultType } from 'vault';
import { log } from 'utils';
import { confirm, intro, outro, text, password, select, isCancel, spinner, note, multiline } from '../lib/clack/prompts';
import { exit } from 'node-utils';
import * as fs from 'fs/promises';
import { existsSync } from 'fs';
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
        log.error(pc.red(`✗ ${result.message}`));
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
    // Secret name to view.
    name?: string;
}

//
// Options for the `secrets edit` command.
//
interface ISecretsEditOptions {
    // Skip interactive prompts.
    yes?: boolean;
    // Secret name to edit (identifier).
    name?: string;
    // New secret name (rename).
    newName?: string;
    // New secret value.
    value?: string;
    // Path to a file whose content is used as the new secret value (for multiline values such as PEM keys).
    valueFile?: string;
}

//
// Options for the `secrets remove` command.
//
interface ISecretsRemoveOptions {
    // Skip confirmation prompt.
    yes?: boolean;
    // Secret name to remove.
    name?: string;
}

//
// Options for the `secrets send` command.
//
interface ISecretsSendOptions {
    // Skip confirmation prompts.
    yes?: boolean;
    // Secret name to send.
    name?: string;
    // Pairing code to use instead of generating one.
    code?: string;
}

//
// Options for the `secrets import` command.
//
interface ISecretsImportOptions {
    // Skip interactive prompts.
    yes?: boolean;
    // Path to the private key file.
    privateKey?: string;
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

    // psi secrets view
    cmd.command('view')
        .description('Show the full value of a named secret.')
        .option('--yes', 'Skip confirmation prompt')
        .option('--name <name>', 'Secret name')
        .action(secretsView);

    // psi secrets edit
    cmd.command('edit')
        .description('Edit an existing secret, field by field.')
        .option('--yes', 'Skip prompts')
        .option('--name <name>', 'Secret name to edit')
        .option('--new-name <name>', 'New secret name')
        .option('--value <value>', 'New value')
        .option('--value-file <path>', 'Read new value from a file (for multiline values such as PEM keys)')
        .action(secretsEdit);

    // psi secrets remove
    cmd.command('remove')
        .description('Remove a named secret.')
        .option('--yes', 'Skip confirmation prompt')
        .option('--name <name>', 'Secret name to remove')
        .action(secretsRemove);

    // psi secrets clear
    cmd.command('clear')
        .description('Remove all secrets.')
        .option('--yes', 'Skip confirmation prompt')
        .action(secretsClear);

    // psi secrets import
    cmd.command('import')
        .description('Import a PEM private key file as an encryption key.')
        .option('--yes', 'Skip prompts')
        .option('--private-key <path>', 'Path to private key file')
        .action(secretsImport);

    // psi secrets send
    cmd.command('send')
        .description('Send a secret to another device over the LAN.')
        .option('--yes', 'Skip confirmation prompts')
        .option('--name <name>', 'Secret name to send')
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
            log.error(pc.red('✗ --name, --type, and --value are required with --yes'));
            await exit(1);
            return;
        }

        if (!SECRET_TYPES.includes(cmdOptions.type)) {
            log.error(pc.red(`✗ Invalid secret type "${cmdOptions.type}". Must be one of: ${SECRET_TYPES.join(', ')}`));
            await exit(1);
            return;
        }

        const existing = await vault.get(cmdOptions.name);
        if (existing) {
            log.error(pc.red(`✗ A secret named "${cmdOptions.name}" already exists. Use "secrets edit" to update it.`));
            await exit(1);
            return;
        }

        await vault.set({ name: cmdOptions.name, type: cmdOptions.type, value: cmdOptions.value });
        log.info(pc.green(`✓ Secret "${cmdOptions.name}" added.`));
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

    const trimmedName = (name as string).trim();
    const existing = await vault.get(trimmedName);
    if (existing) {
        outro(pc.red(`✗ A secret named "${trimmedName}" already exists. Use "secrets edit" to update it.`));
        await exit(1);
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

    log.info(pc.cyan('Your secret will be stored securely in your OS keychain.'));

    let value: string;

    if (type === 'encryption-key') {
        const multilineResult = await multiline({
            message: 'Secret value (paste your key, then press Ctrl+D to submit):',
            validate: (val) => {
                if (!val || val.trim().length === 0) {
                    return 'Value is required';
                }
                return undefined;
            },
        });

        if (isCancel(multilineResult)) {
            outro(pc.yellow('Cancelled.'));
            return;
        }

        value = multilineResult as string;
    }
    else {
        const passwordResult = await password({
            message: 'Secret value:',
            validate: (val) => {
                if (!val || val.trim().length === 0) {
                    return 'Value is required';
                }
                return undefined;
            },
        });

        if (isCancel(passwordResult)) {
            outro(pc.yellow('Cancelled.'));
            return;
        }

        value = passwordResult as string;
    }

    await vault.set({ name: trimmedName, type: type as string, value });

    outro(pc.green(`✓ Secret "${trimmedName}" added.`));
}

//
// psi secrets list — print all secrets with masked values.
//
async function secretsList(): Promise<void> {
    await checkVaultPrereqs();
    const vault = getVault(getDefaultVaultType());
    const secrets = await vault.list();

    if (secrets.length === 0) {
        log.info(pc.yellow('No secrets found.'));
        return;
    }

    log.info(pc.cyan(`\n${'Name'.padEnd(40)} ${'Type'.padEnd(20)} Value`));
    log.info('─'.repeat(80));

    for (const secret of secrets) {
        const masked = '****';
        log.info(`${secret.name.padEnd(40)} ${secret.type.padEnd(20)} ${masked}`);
    }

    log.info('');
}

//
// psi secrets view [name] — show the full value after confirmation.
//
async function secretsView(cmdOptions: ISecretsViewOptions): Promise<void> {
    await checkVaultPrereqs();
    const vault = getVault(getDefaultVaultType());
    let secretName: string | undefined = cmdOptions.name;

    if (!secretName) {
        if (cmdOptions.yes) {
            log.error(pc.red('✗ --name is required with --yes'));
            await exit(1);
            return;
        }

        const secrets = await vault.list();
        if (secrets.length === 0) {
            log.info(pc.yellow('No secrets found.'));
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

        secretName = selected as string;
    }

    const secret = await vault.get(secretName);

    if (!secret) {
        log.error(pc.red(`✗ No secret named "${secretName}" found.`));
        await exit(1);
        return;
    }

    if (!cmdOptions.yes) {
        const confirmed = await confirm({
            message: `Reveal the value of "${secretName}"? (This will display sensitive data.)`,
            initialValue: false,
        });

        if (isCancel(confirmed) || !confirmed) {
            outro(pc.yellow('Cancelled.'));
            return;
        }
    }

    log.info(pc.cyan(`\nName: `) + secret.name);
    log.info(pc.cyan(`Type: `) + secret.type);

    if (secret.type === 's3-credentials') {
        try {
            const parsed = JSON.parse(secret.value);
            log.info(pc.cyan(`Value:`));
            for (const [fieldKey, fieldVal] of Object.entries(parsed)) {
                log.info(`  ${fieldKey}: ${fieldVal}`);
            }
        }
        catch {
            log.info(pc.cyan(`Value: `) + secret.value);
        }
    }
    else {
        log.info(pc.cyan(`Value: `) + secret.value);
    }

    log.info('');
}

//
// psi secrets edit [name] — reload existing fields and re-prompt with current values pre-populated.
//
async function secretsEdit(cmdOptions: ISecretsEditOptions): Promise<void> {
    await checkVaultPrereqs();
    const vault = getVault(getDefaultVaultType());
    let secretName: string | undefined = cmdOptions.name;

    if (!secretName) {
        if (cmdOptions.yes) {
            log.error(pc.red('✗ --name is required with --yes'));
            await exit(1);
            return;
        }

        const secrets = await vault.list();
        if (secrets.length === 0) {
            log.info(pc.yellow('No secrets found.'));
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

        secretName = selected as string;
    }

    const secret = await vault.get(secretName);

    if (!secret) {
        log.error(pc.red(`✗ No secret named "${secretName}" found.`));
        await exit(1);
        return;
    }

    if (cmdOptions.yes) {
        if (!cmdOptions.newName && !cmdOptions.value && !cmdOptions.valueFile) {
            log.error(pc.red('✗ --new-name, --value, or --value-file is required with --yes'));
            await exit(1);
            return;
        }

        let updatedValue = secret.value;

        if (cmdOptions.valueFile) {
            if (!existsSync(cmdOptions.valueFile)) {
                log.error(pc.red(`✗ File not found: ${cmdOptions.valueFile}`));
                await exit(1);
                return;
            }

            updatedValue = await fs.readFile(cmdOptions.valueFile, 'utf-8');
        }
        else if (cmdOptions.value) {
            updatedValue = cmdOptions.value;
        }

        const updatedName = cmdOptions.newName || secret.name;

        if (updatedName !== secret.name) {
            await vault.delete(secret.name);
        }

        await vault.set({ name: updatedName, type: secret.type, value: updatedValue });
        log.info(pc.green(`✓ Secret "${updatedName}" updated.`));
        return;
    }

    intro(pc.cyan(`Edit Secret: ${secretName}`));

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

    log.info(pc.cyan('Your secret will be stored securely in your OS keychain.'));

    let newValue: string | symbol;

    if (secret.type === 'encryption-key') {
        newValue = await multiline({
            message: 'New value (paste your key, then press Ctrl+D to submit; leave empty and Ctrl+D to keep current):',
        });
    }
    else {
        newValue = await password({
            message: `New value (leave blank to keep current):`,
        });
    }

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
// psi secrets remove [name] — remove a secret after confirmation.
//
async function secretsRemove(cmdOptions: ISecretsRemoveOptions): Promise<void> {
    await checkVaultPrereqs();
    const vault = getVault(getDefaultVaultType());
    let secretName: string | undefined = cmdOptions.name;

    if (!secretName) {
        if (cmdOptions.yes) {
            log.error(pc.red('✗ --name is required with --yes'));
            await exit(1);
            return;
        }

        const secrets = await vault.list();
        if (secrets.length === 0) {
            log.info(pc.yellow('No secrets found.'));
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

        secretName = selected as string;
    }

    const secret = await vault.get(secretName);

    if (!secret) {
        log.error(pc.red(`✗ No secret named "${secretName}" found.`));
        await exit(1);
        return;
    }

    if (!cmdOptions.yes) {
        const confirmed = await confirm({
            message: `Delete secret "${secretName}"? This cannot be undone.`,
            initialValue: false,
        });

        if (isCancel(confirmed) || !confirmed) {
            outro(pc.yellow('Cancelled.'));
            return;
        }
    }

    await vault.delete(secretName);
    outro(pc.green(`✓ Secret "${secretName}" deleted.`));
}

//
// Options for the `secrets clear` command.
//
interface ISecretsClearOptions {
    // Skip confirmation prompt.
    yes?: boolean;
}

//
// psi secrets clear — remove all secrets after confirmation.
//
async function secretsClear(cmdOptions: ISecretsClearOptions): Promise<void> {
    await checkVaultPrereqs();
    const vault = getVault(getDefaultVaultType());
    const secrets = await vault.list();

    if (secrets.length === 0) {
        log.info(pc.yellow('No secrets found.'));
        return;
    }

    if (!cmdOptions.yes) {
        log.info(pc.cyan(`\nSecrets to be deleted:`));
        for (const secret of secrets) {
            log.info(`  ${secret.name} (${secret.type})`);
        }
        log.info('');

        const firstConfirm = await confirm({
            message: `Delete all ${secrets.length} secret(s)? This cannot be undone.`,
            initialValue: false,
        });

        if (isCancel(firstConfirm) || !firstConfirm) {
            outro(pc.yellow('Cancelled.'));
            return;
        }

        const secondConfirm = await confirm({
            message: `Are you sure? All secrets will be permanently deleted.`,
            initialValue: false,
        });

        if (isCancel(secondConfirm) || !secondConfirm) {
            outro(pc.yellow('Cancelled.'));
            return;
        }
    }

    for (const secret of secrets) {
        await vault.delete(secret.name);
    }

    outro(pc.green(`✓ Deleted ${secrets.length} secret(s).`));
}

//
// psi secrets import — import a .key / .key.pub PEM file pair into the secrets store.
//
async function secretsImport(cmdOptions: ISecretsImportOptions): Promise<void> {
    await checkVaultPrereqs();
    if (cmdOptions.yes) {
        if (!cmdOptions.privateKey) {
            log.error(pc.red('✗ --private-key is required with --yes'));
            await exit(1);
            return;
        }

        const privatePath = cmdOptions.privateKey.trim();
        if (!existsSync(privatePath)) {
            log.error(pc.red(`✗ File not found: ${privatePath}`));
            await exit(1);
            return;
        }

        const keyName = privatePath.split('/').pop()?.replace(/\.key$/, '') || 'imported-key';
        const privateKeyPem = await fs.readFile(privatePath, 'utf-8');
        const vault = getVault(getDefaultVaultType());
        await vault.set({ name: keyName, type: 'encryption-key', value: privateKeyPem });
        log.info(pc.green(`✓ Key imported as "${keyName}".`));
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
    const vault = getVault(getDefaultVaultType());
    await vault.set({ name: keyName, type: 'encryption-key', value: privateKeyPem });
    outro(pc.green(`✓ Key imported as "${keyName}".`));
}

//
// psi secrets send [name] — share a secret with another device over the LAN.
//
async function secretsSend(cmdOptions: ISecretsSendOptions): Promise<void> {
    await checkVaultPrereqs();
    intro(pc.cyan('Send Secret'));

    const vault = getVault(getDefaultVaultType());
    let secretName: string;

    note(
        'Both devices must be on the same local network (wired or Wi-Fi).\nThis does not work over the internet.',
        pc.cyan('ℹ Network Requirement')
    );

    if (cmdOptions.name) {
        const secret = await vault.get(cmdOptions.name);
        if (!secret) {
            log.error(pc.red(`✗ No secret named "${cmdOptions.name}" found.`));
            await exit(1);
            return;
        }
        secretName = cmdOptions.name;
    }
    else {
        // Pick from all vault secrets
        const secrets = await vault.list();
        if (secrets.length === 0) {
            log.info(pc.yellow('No secrets found.'));
            log.info(pc.dim('Use "psi secrets add" to add a secret first.'));
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

    log.info(pc.dim('Hint: Run `psi secrets receive` on another device to receive this secret.'));

    // Build the payload
    const payload = await resolveSecretSharePayload(secretName);

    log.info(pc.cyan('\nSecret to send:'));
    log.info(pc.cyan('  Name: ') + secretName);
    log.info(pc.cyan('  Type: ') + payload.secretType);
    log.info('');

    // Create sender (generates or uses supplied pairing code)
    const sender = new LanShareSender(payload, cmdOptions.code);

    // Display the pairing code — the user must enter this on the receiver device
    log.info(pc.cyan(`  Pairing code: ${pc.bold(sender.pairingCode)}`));
    log.info(pc.dim('  Enter this code on the receiver device, then wait.'));
    log.info('');

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
        log.error(pc.red('✗ Pairing code rejected by receiver.'));
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

    log.info(pc.dim('Hint: Run `psi secrets send` on another device to send a secret.'));

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

    log.info(pc.cyan('\nReceived secret:'));
    log.info(pc.cyan('  Type: ') + payload.secretType);
    log.info('');

    let saveName: string;

    if (skipPrompts) {
        saveName = payload.name;
    }
    else {
        // Ask what name to save it as, pre-populated with the sender's name.
        const nameInput = await text({
            message: 'Save secret as (name):',
            initialValue: payload.name,
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
