import { Command } from 'commander';
import pc from 'picocolors';
import { getVault } from 'vault';
import { confirm, intro, outro, text, password, select, isCancel } from '../lib/clack/prompts';
import { exit } from 'node-utils';
import * as fs from 'fs/promises';
import { existsSync } from 'fs';
import { generateKeyPair, exportPublicKeyToPem } from 'storage';

//
// Secret types supported by the vault CLI.
//
const SECRET_TYPES = ['api-key', 's3-credentials', 'encryption-key', 'plain'];

//
// Returns the Commander sub-command group for `psi vault`.
//
export function vaultCommand(): Command {
    const cmd = new Command('vault')
        .description('Manage secrets stored in the Photosphere vault.');

    // psi vault add
    cmd.command('add')
        .description('Interactively add a new secret to the vault.')
        .action(vaultAdd);

    // psi vault list
    cmd.command('list')
        .description('List all secrets in the vault (values are masked).')
        .action(vaultList);

    // psi vault view <name>
    cmd.command('view <name>')
        .description('Show the full value of a named secret.')
        .action(vaultView);

    // psi vault edit <name>
    cmd.command('edit <name>')
        .description('Edit an existing secret, field by field.')
        .action(vaultEdit);

    // psi vault delete <name>
    cmd.command('delete <name>')
        .description('Delete a named secret from the vault.')
        .action(vaultDelete);

    // psi vault import
    cmd.command('import')
        .description('Import a .key / .key.pub PEM key pair file into the vault.')
        .action(vaultImport);

    return cmd;
}

//
// psi vault add — prompt for name, type, value, then store.
//
async function vaultAdd(): Promise<void> {
    intro(pc.cyan('Add Vault Secret'));

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

    outro(pc.green(`✓ Secret "${name}" added to vault.`));
}

//
// psi vault list — print all secrets with masked values.
//
async function vaultList(): Promise<void> {
    const vault = getVault("plaintext");
    const secrets = await vault.list();

    if (secrets.length === 0) {
        console.log(pc.yellow('No secrets found in vault.'));
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
// psi vault view <name> — show the full value after confirmation.
//
async function vaultView(name: string): Promise<void> {
    const vault = getVault("plaintext");
    const secret = await vault.get(name);

    if (!secret) {
        console.error(pc.red(`✗ No secret named "${name}" found in vault.`));
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
// psi vault edit <name> — reload existing fields and re-prompt with current values pre-populated.
//
async function vaultEdit(name: string): Promise<void> {
    intro(pc.cyan(`Edit Vault Secret: ${name}`));

    const vault = getVault("plaintext");
    const secret = await vault.get(name);

    if (!secret) {
        outro(pc.red(`✗ No secret named "${name}" found in vault.`));
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
// psi vault delete <name> — delete a secret after confirmation.
//
async function vaultDelete(name: string): Promise<void> {
    const vault = getVault("plaintext");
    const secret = await vault.get(name);

    if (!secret) {
        console.error(pc.red(`✗ No secret named "${name}" found in vault.`));
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
// psi vault import — import a .key / .key.pub PEM file pair into the vault.
//
async function vaultImport(): Promise<void> {
    intro(pc.cyan('Import Encryption Key into Vault'));

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
        message: 'Vault key name:',
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
