import { intro, outro, text, password, confirm, select, isCancel } from '@clack/prompts';
import fs from 'fs/promises';
import path from 'path';
import os from 'os';
import pc from 'picocolors';

export interface IS3Profile {
    endpoint?: string;
    region: string;
    accessKeyId: string;
    secretAccessKey: string;
}

export interface IS3Config {
    profiles: {
        [name: string]: IS3Profile;
    };
}

//
// Gets the path to the Photosphere configuration directory
//
function getConfigDir(): string {
    const homeDir = os.homedir();
    return path.join(homeDir, '.photosphere');
}

//
// Gets the path to the credentials file
//
function getCredentialsPath(): string {
    return path.join(getConfigDir(), '.photosphere.json');
}

//
// Gets the path to local credentials file in current directory
//
function getLocalCredentialsPath(): string {
    return path.join(process.cwd(), '.photosphere.json');
}

//
// Loads S3 configuration from file
//
export async function loadS3Config(): Promise<IS3Config | null> {
    try {
        // Try local credentials first (.photosphere.json)
        const localPath = getLocalCredentialsPath();
        try {
            const data = await fs.readFile(localPath, 'utf-8');
            return JSON.parse(data);
        } catch {
            // Try legacy name (.photosphere)
            try {
                const legacyPath = path.join(process.cwd(), '.photosphere');
                const data = await fs.readFile(legacyPath, 'utf-8');
                return JSON.parse(data);
            } catch {
                // Local file doesn't exist, try global
            }
        }

        // Try global credentials
        const globalPath = getCredentialsPath();
        const data = await fs.readFile(globalPath, 'utf-8');
        return JSON.parse(data);
    } catch {
        return null;
    }
}

//
// Saves S3 configuration to file
//
async function saveS3Config(config: IS3Config, saveLocally: boolean): Promise<void> {
    const configPath = saveLocally ? getLocalCredentialsPath() : getCredentialsPath();
    const dir = path.dirname(configPath);
    
    // Ensure directory exists
    await fs.mkdir(dir, { recursive: true });
    
    // Write config file
    await fs.writeFile(configPath, JSON.stringify(config, null, 2), 'utf-8');
    
    // Set restrictive permissions on non-Windows systems
    if (process.platform !== 'win32') {
        await fs.chmod(configPath, 0o600);
    }
}

//
// Prompts user for S3 configuration
//
export async function promptForS3Config(suggestedProfileName: string = 'default'): Promise<{ profile: IS3Profile; profileName: string } | null> {
    intro(pc.cyan('S3 Configuration Setup'));
    console.log(pc.dim('Configure credentials to access your S3-hosted media file database.'));
    
    const profileName = await text({
        message: 'Profile name:',
        placeholder: 'default',
        initialValue: suggestedProfileName,
        validate: (value) => {
            if (!value || value.trim() === '') {
                return 'Profile name is required';
            }
            if (!/^[a-zA-Z0-9_-]+$/.test(value.trim())) {
                return 'Profile name can only contain letters, numbers, hyphens, and underscores';
            }
        }
    });
    
    if (isCancel(profileName)) {
        outro(pc.red('Setup cancelled'));
        return null;
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
        outro(pc.red('Setup cancelled'));
        return null;
    }
    
    const region = await text({
        message: 'Region (this should be us-east-1 for Digitial Ocean Spaces or the actual region name for AWS S3):',
        placeholder: 'us-east-1',
        validate: (value) => {
            if (!value || value.trim() === '') {
                return 'Region is required';
            }
        }
    });
    
    if (isCancel(region)) {
        outro(pc.red('Setup cancelled'));
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
        outro(pc.red('Setup cancelled'));
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
        outro(pc.red('Setup cancelled'));
        return null;
    }
    
    const saveLocation = await select({
        message: 'Where would you like to save the credentials?',
        options: [
            { value: 'local', label: 'Current directory (.photosphere.json)' },
            { value: 'global', label: `Home directory (${getCredentialsPath()})` }
        ]
    });
    
    if (isCancel(saveLocation)) {
        outro(pc.red('Setup cancelled'));
        return null;
    }
    
    const profile: IS3Profile = {
        region: region.trim(),
        accessKeyId: accessKeyId.trim(),
        secretAccessKey: secretAccessKey.trim()
    };
    
    if (endpoint && endpoint.trim() !== '') {
        profile.endpoint = endpoint.trim();
    }
    
    // Load existing config or create new one
    const existingConfig = await loadS3Config() || { profiles: {} };
    existingConfig.profiles[profileName.trim()] = profile;
    
    // Save config
    await saveS3Config(existingConfig, saveLocation === 'local');
    
    const savedPath = saveLocation === 'local' ? getLocalCredentialsPath() : getCredentialsPath();
    outro(pc.green(`Credentials saved to ${savedPath}`));
    
    return { profile, profileName: profileName.trim() };
}

//
// Gets S3 configuration for a profile, prompting if necessary
//
export async function getS3Config(profileName: string = 'default'): Promise<IS3Profile | null> {
    const config = await loadS3Config();
    
    if (config && config.profiles[profileName]) {
        return config.profiles[profileName];
    }
    
    // No config exists, prompt user
    console.log(pc.yellow(`\nYou are trying to access a media file database hosted in S3.`));
    console.log(pc.yellow(`No S3 configuration found for profile '${profileName}'.`));
    const shouldConfigure = await confirm({
        message: 'Would you like to configure S3 credentials now?',
        initialValue: true
    });
    
    if (isCancel(shouldConfigure) || !shouldConfigure) {
        return null;
    }
    
    const result = await promptForS3Config(profileName);
    return result ? result.profile : null;
}

//
// Sets environment variables from S3 profile
//
export function setS3EnvironmentVariables(profile: IS3Profile): void {
    process.env.AWS_ACCESS_KEY_ID = profile.accessKeyId;
    process.env.AWS_SECRET_ACCESS_KEY = profile.secretAccessKey;
    process.env.AWS_DEFAULT_REGION = profile.region;
    
    if (profile.endpoint) {
        process.env.AWS_ENDPOINT = profile.endpoint;
    }
}

//
// Checks if a path is an S3 path and configures S3 if needed
//
export async function configureS3IfNeeded(path: string, profileName: string = 'default'): Promise<boolean> {
    if (!path.startsWith('s3:')) {
        return true; // Not an S3 path, no configuration needed
    }
    
    const profile = await getS3Config(profileName);
    if (!profile) {
        console.error(pc.red('\nS3 configuration is required to access your S3-hosted media file database.'));
        console.error(pc.red('Please run "psi configure" to set up your S3 credentials.'));
        return false;
    }
    
    setS3EnvironmentVariables(profile);
    return true;
}

//
// Clears all S3 configuration files
//
export async function clearS3Config(): Promise<boolean> {
    intro(pc.cyan('Clear S3 Configuration'));
    
    // Check what files exist
    const filesToDelete: string[] = [];
    const localPath = getLocalCredentialsPath();
    const legacyLocalPath = path.join(process.cwd(), '.photosphere');
    const globalPath = getCredentialsPath();
    
    try {
        await fs.access(localPath);
        filesToDelete.push(localPath);
    } catch {
        // File doesn't exist
    }
    
    try {
        await fs.access(legacyLocalPath);
        filesToDelete.push(legacyLocalPath);
    } catch {
        // File doesn't exist
    }
    
    try {
        await fs.access(globalPath);
        filesToDelete.push(globalPath);
    } catch {
        // File doesn't exist
    }
    
    if (filesToDelete.length === 0) {
        outro(pc.yellow('No configuration files found.'));
        return true;
    }
    
    console.log(pc.yellow('\nThe following configuration files will be deleted:'));
    filesToDelete.forEach(file => {
        console.log(pc.dim(`  - ${file}`));
    });
    
    console.log(pc.red('\n⚠️  Warning: This action cannot be undone!'));
    console.log(pc.red('Your S3 credentials will be permanently deleted.'));
    
    const confirmText = await text({
        message: 'Type "confirm" to delete all configuration:',
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
    
    // Delete all configuration files
    for (const file of filesToDelete) {
        try {
            await fs.unlink(file);
            console.log(pc.green(`✓ Deleted ${file}`));
        } catch (err) {
            console.error(pc.red(`✗ Failed to delete ${file}: ${err}`));
        }
    }
    
    outro(pc.green('Configuration files deleted successfully.'));
    return true;
}