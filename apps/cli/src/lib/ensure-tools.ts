import { ensureToolsAvailable, verifyTools } from 'tools';
import pc from "picocolors";
import { exit } from 'node-utils';
import { confirm, isCancel } from "@clack/prompts";
import { platform } from "os";

//
// Ensures tools are available for commands that need media processing.
// Shows user-friendly error and exits if tools are missing.
//
export async function ensureMediaProcessingTools(nonInteractive: boolean = false): Promise<void> {
    const toolsStatus = await verifyTools();
    
    if (toolsStatus.allAvailable) {
        return; // All tools are available, continue
    }
    
    // Tools are missing, show error and ask for installation instructions
    console.error(pc.red('❌ Required media processing tools are not available.'));
    console.log();
    
    const missingTools = toolsStatus.missingTools;
    console.log(pc.yellow(`Missing tools: ${missingTools.join(', ')}`));
    console.log();
    
    // Ask if user wants to see installation instructions (or show them automatically in non-interactive mode)
    let showInstructions = true;
    if (!nonInteractive) {
        const userChoice = await confirm({
            message: 'Would you like to see installation instructions?',
            initialValue: true
        });
        
        if (isCancel(userChoice)) {
            console.log();
            console.log(pc.dim('Please install the missing tools and try again.'));
            console.log(pc.dim('You can also run: ') + pc.cyan('psi tools') + pc.dim(' to see installation instructions'));
            exit(1);
        }
        showInstructions = userChoice as boolean;
    }
    
    if (!showInstructions) {
        console.log();
        console.log(pc.dim('Please install the missing tools and try again.'));
        console.log(pc.dim('You can also run: ') + pc.cyan('psi tools') + pc.dim(' to see installation instructions'));
        exit(1);
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
            console.log('  • ffmpeg: ' + pc.gray('https://johnvansickle.com/ffmpeg/'));
            console.log('    (Static builds for Linux)');
            break;
            
        default:
            console.log('Please install the following tools for your system:');
            console.log();
            console.log(pc.bold('ImageMagick:'));
            console.log('  Official site: ' + pc.gray('https://imagemagick.org'));
            console.log('  Downloads: ' + pc.gray('https://imagemagick.org/script/download.php'));
            console.log();
            console.log(pc.bold('ffmpeg (includes ffprobe):'));
            console.log('  Official site: ' + pc.gray('https://ffmpeg.org'));
            console.log('  Downloads: ' + pc.gray('https://ffmpeg.org/download.html'));
    }
    
    console.log();
    console.log(pc.dim('After installation, run this command again to verify all tools are available.'));
    
    exit(1);
}