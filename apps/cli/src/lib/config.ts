import { intro, outro, text, password, confirm, isCancel, note } from './clack/prompts';
import fs from 'fs/promises';
import path from 'path';
import os from 'os';
import pc from 'picocolors';
import { IS3Credentials } from 'storage';
import { exit } from 'node-utils';
import { getVault, getDefaultVaultType } from 'vault';

//
// Non-secret CLI preferences stored in ~/.config/photosphere/cli.json.
//
interface ICliConfig {
    // Whether the user previously declined to configure a Google API key.
    googleApiKeyDeclined?: boolean;
}

//
// Returns the path to the non-secret CLI preferences file.
//
function getCliConfigPath(): string {
    return path.join(os.homedir(), '.config', 'photosphere', 'cli.json');
}

//
// Loads non-secret CLI preferences from disk.
// Returns an empty object if the file does not exist.
//
async function loadCliConfig(): Promise<ICliConfig> {
    try {
        const raw = await fs.readFile(getCliConfigPath(), 'utf-8');
        return JSON.parse(raw) as ICliConfig;
    }
    catch {
        return {};
    }
}

//
// Saves non-secret CLI preferences to disk.
//
async function saveCliConfig(config: ICliConfig): Promise<void> {
    const configPath = getCliConfigPath();
    await fs.mkdir(path.dirname(configPath), { recursive: true });
    await fs.writeFile(configPath, JSON.stringify(config, null, 2), 'utf-8');
    if (process.platform !== 'win32') {
        await fs.chmod(configPath, 0o600);
    }
}

//
// Prompts the user to configure S3 credentials and stores them in the vault.
//
export async function configureS3(): Promise<IS3Credentials | undefined> {
    note('Configure credentials to access your S3-hosted media file database.');
    
    const endpoint = await text({
        message: 'S3 Endpoint URL (leave empty for AWS S3, supply the endpoint URL for Digital Ocean Spaces):',
        placeholder: 'https://nyc3.digitaloceanspaces.com',
        validate: (value) => {
            if (value && !value.startsWith('http://') && !value.startsWith('https://')) {
                return 'Endpoint must start with http:// or https://';
            }
        }
    });
    
    if (isCancel(endpoint)) {
        outro(pc.red('Setup cancelled'));
        return undefined;
    }
    
    const region = await text({
        message: 'Region (this should be us-east-1 for Digital Ocean Spaces or the actual region name for AWS S3):',
        placeholder: 'us-east-1',
        initialValue: 'us-east-1',
        validate: (value) => {
            if (!value || value.trim() === '') {
                return 'Region is required';
            }
        }
    });
    
    if (isCancel(region)) {
        outro(pc.red('Setup cancelled'));
        return undefined;
    }
    
    const accessKeyId = await text({
        message: 'Access Key ID:',
        validate: (value) => {
            if (!value || value.trim() === '') {
                return 'Access Key ID is required';
            }
        }
    });
    
    if (isCancel(accessKeyId)) {
        outro(pc.red('Setup cancelled'));
        return undefined;
    }
    
    const secretAccessKey = await password({
        message: 'Secret Access Key:',
        validate: (value) => {
            if (!value || value.trim() === '') {
                return 'Secret Access Key is required';
            }
        }
    });
    
    if (isCancel(secretAccessKey)) {
        outro(pc.red('Setup cancelled'));
        return undefined;
    }
   
    
    const s3Config: IS3Credentials = {
        region: typeof region === 'string' ? region.trim() : '',
        accessKeyId: typeof accessKeyId === 'string' ? accessKeyId.trim() : '',
        secretAccessKey: typeof secretAccessKey === 'string' ? secretAccessKey.trim() : ''
    };
    
    if (endpoint && typeof endpoint === 'string' && endpoint.trim() !== '') {
        s3Config.endpoint = endpoint.trim();
    }

    const vault = getVault(getDefaultVaultType());
    await vault.set({ name: 'cli:s3', type: 's3-credentials', value: JSON.stringify(s3Config) });

    outro(pc.green('S3 credentials saved.'));

    return s3Config;
}

//
// Reads S3 credentials from the vault.
//
export async function getS3Config(): Promise<IS3Credentials | undefined> {
    const vault = getVault(getDefaultVaultType());
    const secret = await vault.get('cli:s3');
    if (!secret) {
        return undefined;
    }
    return JSON.parse(secret.value) as IS3Credentials;
}

//
// Reads the Google geocoding API key from env or vault.
//
export async function getGoogleApiKey(): Promise<string | undefined> {
    if (process.env.GOOGLE_API_KEY) {
        return process.env.GOOGLE_API_KEY.trim();
    }
    const vault = getVault(getDefaultVaultType());
    const secret = await vault.get('cli:geocoding');
    return secret?.value;
}

//
// Prompts the user to enter a Google API key and stores it in the vault.
//
export async function configureGoogleApiKey(): Promise<void> {
    note(
        'Create a Google API key for reverse geocoding: https://github.com/ashleydavis/photosphere/wiki/Google-Cloud-Setup\n' +
        'You can use the environment variable `GOOGLE_API_KEY` to skip this setup.'
    );
    
    const apiKey = await text({
        message: 'Enter your Google API key:',
        placeholder: 'AIza...',
        validate: (value) => {
            if (!value || value.trim() === '') {
                return 'API key is required';
            }
            if (!value.trim().startsWith('AIza')) {
                return 'Google API keys typically start with "AIza"';
            }
            if (value.trim().length < 30) {
                return 'Google API keys are typically longer than 30 characters';
            }
        }
    });
    
    if (isCancel(apiKey)) {
        outro(pc.red('Setup cancelled'));
        return;
    }

    const vault = getVault(getDefaultVaultType());
    await vault.set({ name: 'cli:geocoding', type: 'api-key', value: typeof apiKey === 'string' ? apiKey.trim() : '' });

    outro(pc.green('✓ Google API key configured successfully!'));
    note(pc.dim('Your photos and videos will now be reverse geocoded to determine location names.'));
}

//
// Sets the Google API key directly in the vault.
//
export async function setGoogleApiKey(apiKey: string): Promise<void> {
    const vault = getVault(getDefaultVaultType());
    await vault.set({ name: 'cli:geocoding', type: 'api-key', value: apiKey });
}

//
// Removes the Google API key from the vault.
//
export async function removeGoogleApiKey(): Promise<void> {
    const vault = getVault(getDefaultVaultType());
    await vault.delete('cli:geocoding');
}

//
// Resets the googleApiKeyDeclined flag in the CLI preferences file.
//
export async function resetGoogleApiKeyDeclined(): Promise<void> {
    const cliConfig = await loadCliConfig();
    delete cliConfig.googleApiKeyDeclined;
    await saveCliConfig(cliConfig);
}

//
// Configures required services based on tags and context.
//
export async function configureIfNeeded(tags: string[], nonInteractive: boolean): Promise<void> {
    for (const tag of tags) {
        switch (tag) {
            case 's3': {
                const s3Config = await getS3Config();
                if (!s3Config) {
                    if (process.env.AWS_ACCESS_KEY_ID && process.env.AWS_SECRET_ACCESS_KEY) {
                        // We have environment variables set so don't need to prompt the user.
                        return;
                    }

                    if (nonInteractive) {
                        // Non-interactive mode, cannot proceed without S3 config.
                        console.error(pc.red('\nS3 configuration is required to access your S3-hosted media file database.'));
                        console.error(pc.red('Please set environment variables or run "psi config" to set up your S3 credentials.')); 
                        await exit(1);
                    }

                    // No config exists, prompt user
                    console.log(pc.yellow(`\nYou are trying to access a media file database hosted in S3.`));
                    console.log(pc.yellow(`No S3 configuration found.`));
                    const shouldConfigure = await confirm({
                        message: 'Would you like to configure S3 credentials now?',
                        initialValue: true
                    });
                    
                    if (isCancel(shouldConfigure) || !shouldConfigure) {
                        // S3 is required but user declined to configure it.
                        console.error(pc.red('S3 configuration is required to access your S3-hosted media.'));
                        await exit(1);
                    }
                    
                    await configureS3();
                }
                break;
            }

            case 'google': {
                const apiKey = await getGoogleApiKey();
                const cliConfig = await loadCliConfig();
                const hasDeclined = cliConfig.googleApiKeyDeclined;

                if (!apiKey && !nonInteractive && !hasDeclined) {
                    const setupNow = await confirm({
                        message: 'Would you like to configure reverse geocoding? (This converts GPS coordinates to location names) (You can say no now and configure it later with "psi config")',
                        initialValue: false
                    });
                    
                    if (isCancel(setupNow) || !setupNow) {
                        cliConfig.googleApiKeyDeclined = true;
                        await saveCliConfig(cliConfig);
                        outro(pc.yellow('Skipping Google API Key setup'));
                        return;
                    }

                    await configureGoogleApiKey();
                }
                break;
            }

            default:
                console.warn(pc.yellow(`Unknown configuration tag: ${tag}`));
                break;
        }
    }
}

//
// Clears vault secrets and CLI preferences.
//
export async function clearConfig(): Promise<boolean> {
    intro(pc.cyan('Clear Configuration'));

    console.log(pc.red('\n⚠️ Warning: This action cannot be undone!'));
    console.log(pc.red('All your configuration (S3 credentials, Google API key, etc.) will be permanently deleted.'));
    
    const confirmText = await text({
        message: 'Type "confirm" to delete the configuration:',
        validate: (value) => {
            if (value !== 'confirm') {
                return 'Please type "confirm" to proceed';
            }
        }
    });
    
    if (isCancel(confirmText)) {
        outro(pc.yellow('Configuration deletion cancelled.'));
        return false;
    }

    const vault = getVault(getDefaultVaultType());
    await vault.delete('cli:s3');
    await vault.delete('cli:geocoding');

    const cliConfigPath = getCliConfigPath();
    try {
        await fs.unlink(cliConfigPath);
    }
    catch {
        // File may not exist; ignore.
    }

    outro(pc.green('Configuration cleared successfully.'));
    return true;
}
