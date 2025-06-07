import { verifyTools, promptAndDownloadTools, getToolsDirectory } from "tools";
import pc from "picocolors";
import { exit } from "node-utils";
import { rmSync, existsSync } from "fs";
import * as p from '@clack/prompts';

export interface IToolsCommandOptions {
    //
    // Non-interactive mode - use defaults and command line arguments.
    //
    yes?: boolean;
}

//
// Command that manages media processing tools.
//
export async function toolsCommand(action?: string, options: IToolsCommandOptions = {}): Promise<void> {
    const normalizedAction = action?.toLowerCase() || 'list';
    
    switch (normalizedAction) {
        case 'list':
        case 'ls':
            await listTools(options);
            break;
            
        case 'update':
        case 'up':
            await updateTools(options);
            break;
            
        case 'delete':
        case 'del':
            await deleteTools(options);
            break;
            
        default:
            console.error(pc.red(`Unknown action: ${action}`));
            console.log('Available actions: list/ls, update/up, delete/del');
            exit(1);
    }
}

async function listTools(options: IToolsCommandOptions): Promise<void> {
    console.log(pc.bold('📦 Media Processing Tools Status\n'));
    
    const toolsStatus = await verifyTools();
    const toolsDir = getToolsDirectory();
    
    console.log(`Tools directory: ${pc.cyan(toolsDir)}\n`);
    
    // Show status of each tool
    const tools = [
        { name: 'ImageMagick', key: 'magick' as const, description: 'Image processing (resize, convert, metadata)' },
        { name: 'ffmpeg', key: 'ffmpeg' as const, description: 'Video processing and thumbnail extraction' },
        { name: 'ffprobe', key: 'ffprobe' as const, description: 'Video analysis and metadata extraction' }
    ];
    
    let allAvailable = true;
    const missingTools: string[] = [];
    
    for (const tool of tools) {
        const status = toolsStatus[tool.key] as any;
        const icon = status.available ? '✅' : '❌';
        const statusText = status.available 
            ? pc.green(`Available${status.version ? ` (v${status.version})` : ''}`)
            : pc.red('Missing');
            
        console.log(`${icon} ${pc.bold(tool.name)}: ${statusText}`);
        console.log(`   ${pc.gray(tool.description)}`);
        
        if (!status.available) {
            allAvailable = false;
            missingTools.push(tool.name.toLowerCase());
            if (status.error) {
                console.log(`   ${pc.red(`Error: ${status.error}`)}`);
            }
        }
        console.log();
    }
    
    if (allAvailable) {
        console.log(pc.green('🎉 All tools are available and ready to use!'));
    } else {
        console.log(pc.yellow(`⚠️  ${missingTools.length} tool(s) missing: ${missingTools.join(', ')}`));
        
        if (!options.yes) {
            console.log();
            const shouldInstall = await p.confirm({
                message: 'Would you like to install the missing tools?',
                initialValue: true
            });
            
            if (p.isCancel(shouldInstall)) {
                console.log(pc.gray('Installation cancelled.'));
                exit(0);
            }
            
            if (shouldInstall) {
                const success = await promptAndDownloadTools(missingTools);
                if (success) {
                    console.log(pc.green('✅ Tools installed successfully!'));
                } else {
                    console.log(pc.red('❌ Tool installation failed.'));
                    exit(1);
                }
            }
        }
    }
}

async function updateTools(options: IToolsCommandOptions): Promise<void> {
    console.log(pc.bold('🔄 Updating Media Processing Tools\n'));
    
    const toolsStatus = await verifyTools();
    const availableTools = Object.entries(toolsStatus)
        .filter(([_, status]) => status.available)
        .map(([name, _]) => name);
    
    if (availableTools.length === 0) {
        console.log(pc.yellow('No tools are currently installed.'));
        
        if (!options.yes) {
            const shouldInstall = await p.confirm({
                message: 'Would you like to install all required tools?',
                initialValue: true
            });
            
            if (p.isCancel(shouldInstall) || !shouldInstall) {
                console.log(pc.gray('Installation cancelled.'));
                exit(0);
            }
        }
        
        const success = await promptAndDownloadTools(['magick', 'ffmpeg', 'ffprobe']);
        if (success) {
            console.log(pc.green('✅ Tools installed successfully!'));
        } else {
            console.log(pc.red('❌ Tool installation failed.'));
            exit(1);
        }
        return;
    }
    
    console.log('Currently installed tools:');
    availableTools.forEach(tool => {
        const status = toolsStatus[tool as keyof typeof toolsStatus] as any;
        console.log(`  • ${tool}${status.version ? ` v${status.version}` : ''}`);
    });
    console.log();
    
    if (!options.yes) {
        const shouldUpdate = await p.confirm({
            message: 'Download and install the latest versions of all tools?',
            initialValue: true
        });
        
        if (p.isCancel(shouldUpdate) || !shouldUpdate) {
            console.log(pc.gray('Update cancelled.'));
            exit(0);
        }
    }
    
    // Force reinstall all tools
    const success = await promptAndDownloadTools(['magick', 'ffmpeg', 'ffprobe']);
    if (success) {
        console.log(pc.green('✅ Tools updated successfully!'));
    } else {
        console.log(pc.red('❌ Tool update failed.'));
        exit(1);
    }
}

async function deleteTools(options: IToolsCommandOptions): Promise<void> {
    console.log(pc.bold('🗑️  Delete Media Processing Tools\n'));
    
    const toolsDir = getToolsDirectory();
    
    if (!existsSync(toolsDir)) {
        console.log(pc.yellow('No tools directory found. Nothing to delete.'));
        exit(0);
    }
    
    const toolsStatus = await verifyTools();
    const installedTools = Object.entries(toolsStatus)
        .filter(([_, status]) => status.available)
        .map(([name, _]) => name);
    
    if (installedTools.length === 0) {
        console.log(pc.yellow('No tools are currently installed.'));
        exit(0);
    }
    
    console.log('The following tools will be deleted:');
    installedTools.forEach(tool => {
        const status = toolsStatus[tool as keyof typeof toolsStatus] as any;
        console.log(`  • ${tool}${status.version ? ` v${status.version}` : ''}`);
    });
    console.log();
    console.log(`Tools directory: ${pc.cyan(toolsDir)}`);
    console.log();
    
    if (!options.yes) {
        const shouldDelete = await p.confirm({
            message: pc.red('Are you sure you want to delete all installed tools?'),
            initialValue: false
        });
        
        if (p.isCancel(shouldDelete) || !shouldDelete) {
            console.log(pc.gray('Deletion cancelled.'));
            exit(0);
        }
    }
    
    try {
        rmSync(toolsDir, { recursive: true, force: true });
        console.log(pc.green('✅ All tools have been deleted successfully!'));
        console.log(pc.gray(`Removed directory: ${toolsDir}`));
    } catch (error) {
        console.error(pc.red(`❌ Failed to delete tools: ${error}`));
        exit(1);
    }
}