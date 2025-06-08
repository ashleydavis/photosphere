import { verifyTools } from "tools";
import { Image } from "tools";
import pc from "picocolors";
import { exit } from "node-utils";
import { platform } from "os";
import { confirm, isCancel } from "@clack/prompts";

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
    console.log(pc.bold('📦 Media Processing Tools Status\n'));
    
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
    
    console.log(pc.bold('Tool Status:'));
    console.log();
    
    for (const tool of tools) {
        const status = toolsStatus[tool.key] as any;
        const icon = status.available ? '✅' : '❌';
        const statusText = status.available 
            ? pc.green(`Available${status.version ? ` (v${status.version})` : ''}`)
            : pc.red('Not found');
            
        console.log(`${icon} ${pc.bold(tool.name)}: ${statusText}`);
        console.log(`   ${pc.gray(tool.description)}`);
        
        if (!status.available) {
            allAvailable = false;
            if (tool.key === 'magick') {
                missingTools.push('ImageMagick');
            } else {
                missingTools.push(tool.name);
            }
        }
        console.log();
    }
    
    if (allAvailable) {
        console.log(pc.green('🎉 All tools are available and ready to use!'));
    } else {
        console.log(pc.yellow(`⚠️  ${missingTools.length} tool(s) missing: ${missingTools.join(', ')}`));
        console.log();
        
        // Ask if user wants to see installation instructions (or show them automatically in --yes mode)
        let showInstructions = true;
        if (!options.yes) {
            const userChoice = await confirm({
                message: 'Would you like to see installation instructions?',
                initialValue: true
            });
            
            if (isCancel(userChoice)) {
                console.log();
                console.log(pc.dim('Please install the missing tools and try again.'));
                await exit(1);
            }
            showInstructions = userChoice as boolean;
        }
        
        if (!showInstructions) {
            console.log();
            console.log(pc.dim('Please install the missing tools and try again.'));
            await exit(1);
        }
        
        console.log();
        console.log(pc.bold('Installation Instructions:'));
        console.log();
        
        // Provide platform-specific installation instructions
        const currentPlatform = platform();
        
        switch (currentPlatform) {
            case 'win32':
                console.log(pc.cyan('Windows:'));
                console.log();
                console.log(pc.bold('Using Chocolatey') + ' (recommended):');
                console.log('  ' + pc.gray('choco install imagemagick ffmpeg'));
                console.log('  Chocolatey: ' + pc.gray('https://chocolatey.org/install'));
                console.log();
                console.log(pc.bold('Using Scoop:'));
                console.log('  ' + pc.gray('scoop install imagemagick ffmpeg'));
                console.log('  Scoop: ' + pc.gray('https://scoop.sh'));
                console.log();
                console.log(pc.bold('Manual installation:'));
                console.log('  • ImageMagick: ' + pc.gray('https://imagemagick.org/script/download.php#windows'));
                console.log('    (Installs both modern "magick" and legacy "convert/identify" commands)');
                console.log('  • ffmpeg: ' + pc.gray('https://www.gyan.dev/ffmpeg/builds/'));
                console.log('    (Download "release essentials" build)');
                break;
                
            case 'darwin':
                console.log(pc.cyan('macOS:'));
                console.log();
                console.log(pc.bold('Using Homebrew') + ' (recommended):');
                console.log('  ' + pc.gray('brew install imagemagick ffmpeg'));
                console.log('  Homebrew: ' + pc.gray('https://brew.sh'));
                console.log();
                console.log(pc.bold('Using MacPorts:'));
                console.log('  ' + pc.gray('sudo port install ImageMagick +universal'));
                console.log('  ' + pc.gray('sudo port install ffmpeg +universal'));
                console.log('  MacPorts: ' + pc.gray('https://www.macports.org/install.php'));
                console.log();
                console.log(pc.bold('Manual installation:'));
                console.log('  • ImageMagick: ' + pc.gray('https://imagemagick.org/script/download.php#macosx'));
                console.log('    (Installs both modern "magick" and legacy "convert/identify" commands)');
                console.log('  • ffmpeg: ' + pc.gray('https://evermeet.cx/ffmpeg/'));
                break;
                
            case 'linux':
                console.log(pc.cyan('Linux:'));
                console.log();
                console.log(pc.bold('Ubuntu/Debian:'));
                console.log('  ' + pc.gray('sudo apt update'));
                console.log('  ' + pc.gray('sudo apt install imagemagick ffmpeg'));
                console.log();
                console.log(pc.bold('Fedora/RHEL/CentOS:'));
                console.log('  ' + pc.gray('sudo dnf install ImageMagick ffmpeg'));
                console.log();
                console.log(pc.bold('Arch Linux:'));
                console.log('  ' + pc.gray('sudo pacman -S imagemagick ffmpeg'));
                console.log();
                console.log(pc.bold('Alpine Linux:'));
                console.log('  ' + pc.gray('sudo apk add imagemagick ffmpeg'));
                console.log();
                console.log(pc.bold('Manual/Binary installation:'));
                console.log('  • ImageMagick: ' + pc.gray('https://imagemagick.org/script/download.php#linux'));
                console.log('    (Both modern "magick" and legacy "convert/identify" commands supported)');
                console.log('  • ffmpeg: ' + pc.gray('https://johnvansickle.com/ffmpeg/'));
                console.log('    (Static builds for Linux)');
                break;
                
            default:
                console.log('Please install the following tools for your system:');
                console.log();
                console.log(pc.bold('ImageMagick:'));
                console.log('  Official site: ' + pc.gray('https://imagemagick.org'));
                console.log('  Downloads: ' + pc.gray('https://imagemagick.org/script/download.php'));
                console.log('  (Provides both modern "magick" and legacy "convert/identify" commands)');
                console.log();
                console.log(pc.bold('ffmpeg (includes ffprobe):'));
                console.log('  Official site: ' + pc.gray('https://ffmpeg.org'));
                console.log('  Downloads: ' + pc.gray('https://ffmpeg.org/download.html'));
        }
        
        console.log();
        console.log(pc.dim('After installation, run this command again to verify all tools are available.'));
        
        await exit(1);
    }
}