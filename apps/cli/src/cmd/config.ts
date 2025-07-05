import { exit } from 'node-utils';
import { configureS3, clearConfig, getGoogleApiKey, loadConfig, configureGoogleApiKey } from '../lib/config';
import pc from 'picocolors';
import { intro, outro, select, isCancel, note, confirm } from '../lib/clack/prompts';
import { log } from "utils";

export interface IConfigureCommandOptions {
    //
    // Clear all configuration
    //
    clear?: boolean;
}

//
// Command that walks user through configuration setup
//
export async function configureCommand(options: IConfigureCommandOptions): Promise<void> {
    if (options.clear) {
        const success = await clearConfig();
        await exit(success ? 0 : 1);
    }

    log.info('');    
    intro(pc.cyan('🔧 Photosphere Configuration'));
    
    // Configuration loop
    while (true) {
        // Check current configuration status
        const existingConfig = await loadConfig();
        const hasS3Config = existingConfig?.s3;
        const hasGoogleApiKey = !!(await getGoogleApiKey());
        
        note(
            `S3 Credentials: ${hasS3Config ? pc.green('✓ Configured') : pc.yellow('Not configured')}\n` +
            `Google API Key: ${hasGoogleApiKey ? pc.green('✓ Configured') : pc.yellow('Not configured')}`,
            'Current configuration status'
        );
        
        // Ask what they want to configure
        const configChoice = await select({
            message: 'What would you like to configure?',
            options: [
                { value: 's3', label: `S3 Credentials ${hasS3Config ? '(update existing)' : '(for cloud storage)'}` },
                { value: 'google', label: `Google API Key ${hasGoogleApiKey ? '(update existing)' : '(for reverse geocoding)'}` },
                { value: 'clear', label: 'Clear all configuration' },
                { value: 'exit', label: 'Exit' }
            ]
        });
        
        if (isCancel(configChoice)) {
            outro(pc.gray('Configuration cancelled.'));
            await exit(0);
        }
        
        if (configChoice === 'exit') {
            outro(pc.green('Configuration complete.'));
            await exit(0);
        }
        
        if (configChoice === 'clear') {
            const confirmClear = await confirm({
                message: 'Are you sure you want to clear all configuration? This will remove S3 credentials and Google API key.',
                initialValue: false
            });
            
            if (isCancel(confirmClear) || !confirmClear) {
                note(pc.yellow('Configuration clearing cancelled.'));
                continue;
            }
            
            const success = await clearConfig();
            if (!success) {
                await exit(1);
            }
            // Continue loop to show updated status
            continue;
        }
        
        // Configure S3 if requested
        if (configChoice === 's3') {
            const s3Result = await configureS3();
            
            if (s3Result) {
                note(pc.green('✓ S3 credentials configured successfully!'));
            }
            // Continue loop to show updated status
            continue;
        }
        
        // Configure Google API Key if requested
        if (configChoice === 'google') {        
            await configureGoogleApiKey();
            
            // Continue loop to show updated status
            continue;
        }
    }
}