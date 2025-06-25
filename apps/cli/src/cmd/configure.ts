import { exit } from 'node-utils';
import { promptForS3Config, clearS3Config } from '../lib/s3-config';
import pc from 'picocolors';

export interface IConfigureCommandOptions {
    //
    // The profile name to configure
    //
    profile?: string;
    
    //
    // Clear all configuration
    //
    clear?: boolean;
}

//
// Command that configures S3 credentials
//
export async function configureCommand(options: IConfigureCommandOptions): Promise<void> {
    if (options.clear) {
        const success = await clearS3Config();
        await exit(success ? 0 : 1);
    }
    
    const suggestedProfileName = options.profile || 'default';
    
    const result = await promptForS3Config(suggestedProfileName);
    
    if (!result) {
        console.error(pc.red('Configuration cancelled or failed.'));
        await exit(1);
        return;
    }
    
    console.log(pc.green(`\nProfile '${result.profileName}' configured successfully!`));
    console.log('\nYou can now use S3 storage paths like:');
    console.log('  ' + pc.cyan('psi ui s3:my-bucket/photos'));
    if (result.profileName !== 'default') {
        console.log('  ' + pc.cyan(`psi ui s3:my-bucket/photos --profile ${result.profileName}`));
    }
}