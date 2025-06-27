import { intro, outro, text, password, confirm, select, isCancel, note } from '@clack/prompts';
import fs from 'fs/promises';
import path from 'path';
import os from 'os';
import pc from 'picocolors';

export interface IS3Config {
    endpoint?: string;
    region: string;
    accessKeyId: string;
    secretAccessKey: string;
}

export interface IConfig {
    s3?: IS3Config;
    googleApiKey?: string;
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
            if (!config.s3) config.s3 = {} as IS3Config;
            (config.s3 as any)[key] = value;
        } else if (currentSection === 'google') {
            if (key === 'apiKey') {
                config.googleApiKey = value;
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
    if (config.googleApiKey) {
        lines.push('[google]');
        lines.push(`apiKey=${config.googleApiKey}`);
        lines.push('');
    }
    
    return lines.join('\n');
}

//
// Prompts user for S3 configuration
//
export async function promptForS3Config(skipIntro: boolean = false): Promise<IS3Config | null> {
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
        return null;
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
        return null;
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
        return null;
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
        return null;
    }
    
    
    const s3Config: IS3Config = {
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
export async function getS3Config(allowPrompt: boolean = true): Promise<IS3Config | null> {
    const config = await loadConfig();
    
    if (config?.s3) {
        return config.s3;
    }
    
    if (!allowPrompt) {
        return null;
    }
    
    // No config exists, prompt user
    console.log(pc.yellow(`\nYou are trying to access a media file database hosted in S3.`));
    console.log(pc.yellow(`No S3 configuration found.`));
    const shouldConfigure = await confirm({
        message: 'Would you like to configure S3 credentials now?',
        initialValue: true
    });
    
    if (isCancel(shouldConfigure) || !shouldConfigure) {
        return null;
    }
    
    return await promptForS3Config();
}

//
// Sets environment variables from S3 config
//
export function setS3EnvironmentVariables(s3Config: IS3Config): void {
    process.env.AWS_ACCESS_KEY_ID = s3Config.accessKeyId;
    process.env.AWS_SECRET_ACCESS_KEY = s3Config.secretAccessKey;
    process.env.AWS_DEFAULT_REGION = s3Config.region;
    
    if (s3Config.endpoint) {
        process.env.AWS_ENDPOINT = s3Config.endpoint;
    }
}

//
// Gets the current Google API key from configuration
//
export async function getGoogleApiKey(): Promise<string | null> {
    const config = await loadConfig();
    return config?.googleApiKey || null;
}

//
// Prompts user to configure Google API key for reverse geocoding
//
export async function promptForGoogleApiKey(skipIntro: boolean = false): Promise<string | null> {
    if (!skipIntro) {
        intro(pc.cyan('Google API Key Setup'));
    }
    
    note(
        'Configure your Google API key for reverse geocoding (converting GPS coordinates to location names).\n\n' +
        pc.blue('📖 Setup Guide: https://github.com/ashleydavis/photosphere/wiki/Google-Cloud-Setup'),
        skipIntro ? 'Google API Key Setup' : undefined
    );
    
    const setupNow = await confirm({
        message: 'Would you like to configure reverse geocoding now?',
        initialValue: false
    });
    
    if (isCancel(setupNow) || !setupNow) {
        note(
            pc.yellow('⚠️  Reverse geocoding will be disabled.\n') +
            pc.dim('You can enable it later using: psi config'),
            'Skipping Google API Key'
        );
        return null;
    }
    
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
        return null;
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
    
    return apiKey.trim();
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
// Configures required services based on tags and context
//
export async function configureIfNeeded(tags: string[], context?: { s3Path?: string; yes?: boolean }): Promise<boolean> {
    for (const tag of tags) {
        switch (tag) {
            case 's3':
                // Only configure S3 if we have an S3 path
                if (context?.s3Path && context.s3Path.startsWith('s3:')) {
                    const s3Config = await getS3Config(!context?.yes);
                    if (!s3Config) {
                        console.error(pc.red('\nS3 configuration is required to access your S3-hosted media file database.'));
                        console.error(pc.red('Please run "psi config" to set up your S3 credentials.'));
                        return false;
                    }
                    setS3EnvironmentVariables(s3Config);
                }
                break;
                
            case 'google':
                // Check if Google API key is configured, prompt if not (unless --yes is specified)
                const apiKey = await getGoogleApiKey();
                if (!apiKey && !context?.yes) {
                    console.log(pc.yellow('\nReverse geocoding is available to convert GPS coordinates to location names.'));
                    const result = await promptForGoogleApiKey(false);
                    if (!result) {
                        console.log(pc.dim('Continuing without reverse geocoding...'));
                    }
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