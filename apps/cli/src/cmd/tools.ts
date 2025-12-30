import { verifyTools } from "tools";
import { Image } from "tools";
import pc from "picocolors";
import { exit } from "node-utils";
import { confirm, isCancel } from '../lib/clack/prompts';
import { showInstallationInstructions } from "../lib/installation-instructions";
import { log } from "utils";

export interface IToolsCommandOptions {
    //
    // Non-interactive mode - use defaults and command line arguments.
    //
    yes?: boolean;
}

//
// Command that checks for required media processing tools.
//
export async function toolsCommand(options: IToolsCommandOptions = {}): Promise<void> {
    await listTools(options);
}

async function listTools(options: IToolsCommandOptions): Promise<void> {
    log.info('');
    log.info(pc.bold('📦 Media Processing Tools Status\n'));
    
    const toolsStatus = await verifyTools();
    
    // Get ImageMagick type to display the correct command name
    const imageMagickType = Image.getImageMagickType();
    let imageMagickName = 'ImageMagick';
    let imageMagickCommand = 'magick';
    
    if (imageMagickType === 'legacy') {
        imageMagickName = 'ImageMagick (convert/identify)';
        imageMagickCommand = 'convert/identify';
    } else if (imageMagickType === 'modern') {
        imageMagickName = 'ImageMagick (magick)';
        imageMagickCommand = 'magick';
    }
    
    // Show status of each tool
    const tools = [
        { 
            name: imageMagickName, 
            key: 'magick' as const, 
            command: imageMagickCommand,
            description: 'Image processing - resizing, format conversion, metadata extraction' 
        },
        { 
            name: 'ffmpeg', 
            key: 'ffmpeg' as const,
            command: 'ffmpeg',
            description: 'Video processing - format conversion and thumbnail extraction' 
        },
        { 
            name: 'ffprobe', 
            key: 'ffprobe' as const,
            command: 'ffprobe',
            description: 'Video analysis - metadata extraction, duration, dimensions, codecs' 
        }
    ];
    
    let allAvailable = true;
    const missingTools: string[] = [];
    
    log.info(pc.bold('Tool Status:'));
    log.info('');
    
    for (const tool of tools) {
        const status = toolsStatus[tool.key] as any;
        const icon = status.available ? '✅' : '❌';
        const statusText = status.available 
            ? pc.green(`Available${status.version ? ` (v${status.version})` : ''}`)
            : pc.red('Not found');
            
        log.info(`${icon} ${pc.bold(tool.name)}: ${statusText}`);
        log.info(`   ${pc.gray(tool.description)}`);
        
        if (!status.available) {
            allAvailable = false;
            if (tool.key === 'magick') {
                missingTools.push('ImageMagick');
            } else {
                missingTools.push(tool.name);
            }
        }
        log.info('');
    }
    
    if (allAvailable) {
        log.info(pc.green('🎉 All tools are available and ready to use!'));
        await exit(0);
    } else {
        log.info(pc.yellow(`⚠️ ${missingTools.length} tool(s) missing: ${missingTools.join(', ')}`));
        log.info('');
        
        // Ask if user wants to see installation instructions (or show them automatically in --yes mode)
        let showInstructions = true;
        if (!options.yes) {
            const userChoice = await confirm({
                message: 'Would you like to see installation instructions?',
                initialValue: true
            });
            
            if (isCancel(userChoice)) {
                log.info('');
                log.info(pc.dim('Please install the missing tools and try again.'));
                await exit(1);
            }
            showInstructions = userChoice as boolean;
        }
        
        if (!showInstructions) {
            log.info('');
            log.info(pc.dim('Please install the missing tools and try again.'));
            await exit(1);
        }
        
        showInstallationInstructions(missingTools);
        
        await exit(1);
    }
}