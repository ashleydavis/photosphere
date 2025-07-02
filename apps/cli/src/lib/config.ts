import { intro, outro, text, password, confirm, select, isCancel, note } from '@clack/prompts';
import fs from 'fs/promises';
import path from 'path';
import os from 'os';
import pc from 'picocolors';
import { IS3Credentials } from 'storage';

export interface IConfig {
    s3?: IS3Credentials;
    googleApiKey?: string;
    googleApiKeyDeclined?: boolean;
}

//
// Gets the path to the Photosphere configuration directory
//
function getConfigDir(): string {
    const homeDir = os.homedir();
    if (process.platform === 'win32') {
        // Windows: use AppData\Roaming\Photosphere
        return path.join(homeDir, 'AppData', 'Roaming', 'Photosphere');
    } else {
        // Mac and Linux: use ~/.config/photosphere
        return path.join(homeDir, '.config', 'photosphere');
    }
}

//
// Gets the path to the config file
//
function getConfigPath(): string {
    if (process.platform === 'win32') {
        // Windows: use photosphere.conf
        return path.join(getConfigDir(), 'photosphere.conf');
    } else {
        // Mac and Linux: use photosphere.conf
        return path.join(getConfigDir(), 'photosphere.conf');
    }
}

//
// Loads configuration from file
//
export async function loadConfig(): Promise<IConfig | null> {
    try {
        const configPath = getConfigPath();
        const data = await fs.readFile(configPath, 'utf-8');
        return parseIniConfig(data);
    } catch {
        return null;
    }
}

//
// Parses INI format configuration
//
function parseIniConfig(content: string): IConfig {
    const config: IConfig = {};
    const lines = content.split('\n');
    let currentSection = '';
    
    for (const line of lines) {
        const trimmedLine = line.trim();
        
        // Skip empty lines and comments
        if (!trimmedLine || trimmedLine.startsWith('#')) {
            continue;
        }
        
        // Section headers
        if (trimmedLine.startsWith('[') && trimmedLine.endsWith(']')) {
            currentSection = trimmedLine.slice(1, -1);
            continue;
        }
        
        // Key-value pairs
        const equalIndex = trimmedLine.indexOf('=');
        if (equalIndex === -1) continue;
        
        const key = trimmedLine.slice(0, equalIndex).trim();
        const value = trimmedLine.slice(equalIndex + 1).trim();
        
        if (currentSection === 's3') {
            if (!config.s3) config.s3 = {} as IS3Credentials;
            (config.s3 as any)[key] = value;
        } else if (currentSection === 'google') {
            if (key === 'apiKey') {
                config.googleApiKey = value;
            } else if (key === 'declined') {
                config.googleApiKeyDeclined = value.toLowerCase() === 'true';
            }
        }
    }
    
    return config;
}

//
// Saves configuration to file
//
async function saveConfig(config: IConfig): Promise<void> {
    const configPath = getConfigPath();
    const dir = path.dirname(configPath);
    
    // Ensure directory exists
    await fs.mkdir(dir, { recursive: true });
    
    // Convert to INI format
    const iniContent = formatIniConfig(config);
    
    // Write config file
    await fs.writeFile(configPath, iniContent, 'utf-8');
    
    // Set restrictive permissions on non-Windows systems
    if (process.platform !== 'win32') {
        await fs.chmod(configPath, 0o600);
    }
}

//
// Formats configuration as INI content
//
function formatIniConfig(config: IConfig): string {
    const lines: string[] = [];
    
    // Add header comment
    lines.push('# Photosphere Configuration File');
    lines.push('# This file contains credentials and settings for Photosphere');
    lines.push('');
    
    // S3 configuration section
    if (config.s3) {
        lines.push('[s3]');
        lines.push(`region=${config.s3.region}`);
        lines.push(`accessKeyId=${config.s3.accessKeyId}`);
        lines.push(`secretAccessKey=${config.s3.secretAccessKey}`);
        if (config.s3.endpoint) {
            lines.push(`endpoint=${config.s3.endpoint}`);
        }
        lines.push('');
    }
    
    // Google API configuration section
    if (config.googleApiKey || config.googleApiKeyDeclined) {
        lines.push('[google]');
        if (config.googleApiKey) {
            lines.push(`apiKey=${config.googleApiKey}`);
        }
        if (config.googleApiKeyDeclined) {
            lines.push(`declined=true`);
        }
        lines.push('');
    }
    
    return lines.join('\n');
}

//
// Prompts user for S3 configuration
//
export async function promptForS3Config(skipIntro: boolean = false): Promise<IS3Credentials | undefined> {
    if (!skipIntro) {
        intro(pc.cyan('S3 Configuration Setup'));
        console.log(pc.dim('Configure credentials to access your S3-hosted media file database.'));
    } else {
        note('Configure credentials to access your S3-hosted media file database.', 'S3 Configuration Setup');
    }
    
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
        if (!skipIntro) {
            outro(pc.red('Setup cancelled'));
        }
        return undefined;
    }
    
    const region = await text({
        message: 'Region (this should be us-east-1 for Digital Ocean Spaces or the actual region name for AWS S3):',
        placeholder: 'us-east-1',
        validate: (value) => {
            if (!value || value.trim() === '') {
                return 'Region is required';
            }
        }
    });
    
    if (isCancel(region)) {
        if (!skipIntro) {
            outro(pc.red('Setup cancelled'));
        }
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
        if (!skipIntro) {
            outro(pc.red('Setup cancelled'));
        }
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
        if (!skipIntro) {
            outro(pc.red('Setup cancelled'));
        }
        return undefined;
    }
    
    
    const s3Config: IS3Credentials = {
        region: region.trim(),
        accessKeyId: accessKeyId.trim(),
        secretAccessKey: secretAccessKey.trim()
    };
    
    if (endpoint && endpoint.trim() !== '') {
        s3Config.endpoint = endpoint.trim();
    }
    
    // Load existing config or create new one
    const existingConfig = await loadConfig() || {};
    existingConfig.s3 = s3Config;
    
    // Save config
    await saveConfig(existingConfig);
    
    if (!skipIntro) {
        outro(pc.green(`Credentials saved to ${getConfigPath()}`));
    }
    
    return s3Config;
}

//
// Gets S3 configuration, prompting if necessary
//
export async function getS3Config(): Promise<IS3Credentials | undefined> {
    const config = await loadConfig();
    return config?.s3;   
}

//
// Gets the current Google API key from configuration
//
export async function getGoogleApiKey(): Promise<string | undefined> {
    if (process.env.GOOGLE_API_KEY) {
        // If the environment variable is set, use it directly.
        return process.env.GOOGLE_API_KEY.trim();
    }

    const config = await loadConfig();
    return config?.googleApiKey;
}

//
// Prompts user to configure Google API key for reverse geocoding
//
export async function promptForGoogleApiKey(skipIntro: boolean = false): Promise<void> {
    if (!skipIntro) {
        intro(pc.cyan('Google API Key Setup'));
    }
    
    const setupNow = await confirm({
        message: 'Would you like to configure reverse geocoding? (This converts GPS coordinates to location names) (You can say no now and configure it later with "psi config")',
        initialValue: false
    });
    
    if (isCancel(setupNow) || !setupNow) {
        // User declined to set up Google API key, remember this choice
        const existingConfig = await loadConfig() || {};
        existingConfig.googleApiKeyDeclined = true;
        await saveConfig(existingConfig);
        
        if (!skipIntro) {
            outro(pc.yellow('Skipping Google API Key setup'));
        }

        return;
    }

    note(
        'Creat a Google API key for reverse geocoding:\n' +
        'https://github.com/ashleydavis/photosphere/wiki/Google-Cloud-Setup\r\n' +
        'You can use set the environment variable `GOOGLE_API_KEY` to skip this setup.\n' +
        skipIntro ? 'Google API Key Setup' : undefined
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
        if (!skipIntro) {
            outro(pc.red('Setup cancelled'));
        }
        return;
    }
    
    // Load existing config or create new one
    const existingConfig = await loadConfig() || {};
    existingConfig.googleApiKey = apiKey.trim();
    
    // Save to global config (Google API key is typically global, not project-specific)
    await saveConfig(existingConfig);
    
    if (!skipIntro) {
        outro(pc.green('Google API key configured successfully!'));
        note(pc.dim('Your photos and videos will now be reverse geocoded to determine location names.'));
    }
}

//
// Sets the Google API key in configuration
//
export async function setGoogleApiKey(apiKey: string): Promise<void> {
    const existingConfig = await loadConfig() || {};
    existingConfig.googleApiKey = apiKey;
    await saveConfig(existingConfig);
}

//
// Removes the Google API key from configuration
//
export async function removeGoogleApiKey(): Promise<void> {
    const existingConfig = await loadConfig();
    if (existingConfig) {
        delete existingConfig.googleApiKey;
        await saveConfig(existingConfig);
    }
}

//
// Resets the Google API key declined state, allowing prompts to appear again
//
export async function resetGoogleApiKeyDeclined(): Promise<void> {
    const existingConfig = await loadConfig();
    if (existingConfig) {
        delete existingConfig.googleApiKeyDeclined;
        await saveConfig(existingConfig);
    }
}

//
// Configures required services based on tags and context
//
export async function configureIfNeeded(tags: string[], nonInteractive: boolean): Promise<boolean> {
    for (const tag of tags) {
        switch (tag) {
            case 's3':
                // Configure connection to S3 cloud storage.
                const s3Config = await getS3Config();
                if (!s3Config) {
                    if (process.env.AWS_ACCESS_KEY_ID && process.env.AWS_SECRET_ACCESS_KEY) {
                        // We have environment variables set so don't need to prompt the user.
                        return true;
                    }

                    if (nonInteractive) {
                        // Non-interactive mode, cannot proceed without S3 config.
                        console.error(pc.red('\nS3 configuration is required to access your S3-hosted media file database.'));
                        console.error(pc.red('Please set environment variables or run "psi config" to set up your S3 credentials.')); 
                        return false;
                    }

                    // No config exists, prompt user
                    console.log(pc.yellow(`\nYou are trying to access a media file database hosted in S3.`));
                    console.log(pc.yellow(`No S3 configuration found.`));
                    const shouldConfigure = await confirm({
                        message: 'Would you like to configure S3 credentials now?',
                        initialValue: true
                    });
                    
                    if (isCancel(shouldConfigure) || !shouldConfigure) {
                        return false;
                    }
                    
                    await promptForS3Config();
                    return true;
                }
                break;
                
            case 'google':
                // Check if Google API key is configured, prompt if not (unless --yes is specified or user previously declined)
                const apiKey = await getGoogleApiKey();
                const config = await loadConfig();
                const hasDeclined = config?.googleApiKeyDeclined;
                
                if (!apiKey && !nonInteractive && !hasDeclined) {
                    console.log(pc.yellow('\nReverse geocoding is available to convert GPS coordinates to location names.'));
                    await promptForGoogleApiKey(false);
                }
                break;
                
            default:
                console.warn(pc.yellow(`Unknown configuration tag: ${tag}`));
                break;
        }
    }
    
    return true;
}

//
// Clears all configuration files
//
export async function clearConfig(): Promise<boolean> {
    intro(pc.cyan('Clear Configuration'));
    
    // Check if config file exists
    const configPath = getConfigPath();
    
    try {
        await fs.access(configPath);
    } catch {
        outro(pc.yellow('No configuration file found.'));
        return true;
    }
    
    console.log(pc.yellow(`\nThe following configuration file will be deleted:`));
    console.log(pc.dim(`  - ${configPath}`));
    
    console.log(pc.red('\n⚠️  Warning: This action cannot be undone!'));
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
    
    // Delete the configuration file
    try {
        await fs.unlink(configPath);
        console.log(pc.green(`✓ Deleted ${configPath}`));
    } catch (err) {
        console.error(pc.red(`✗ Failed to delete ${configPath}: ${err}`));
        return false;
    }
    
    outro(pc.green('Configuration file deleted successfully.'));
    return true;
}