import pc from "picocolors";
import { platform } from "os";

/**
 * Shows platform-specific installation instructions for missing tools
 */
export function showInstallationInstructions(missingTools: string[]): void {
    console.log();
    console.log(pc.bold('Installation Instructions:'));
    console.log();
    
    // Check which tools are missing to provide targeted instructions
    const needsImageMagick = missingTools.includes('ImageMagick');
    const needsFfmpeg = missingTools.includes('ffmpeg') || missingTools.includes('ffprobe');
    
    // Provide platform-specific installation instructions
    const currentPlatform = platform();
    
    switch (currentPlatform) {
        case 'win32':
            showWindowsInstructions(needsImageMagick, needsFfmpeg);
            break;
            
        case 'darwin':
            showMacOSInstructions(needsImageMagick, needsFfmpeg);
            break;
            
        case 'linux':
            showLinuxInstructions(needsImageMagick, needsFfmpeg);
            break;
            
        default:
            showGenericInstructions(needsImageMagick, needsFfmpeg);
    }
    
    console.log();
    console.log(pc.dim('After installation, run this command again to verify all tools are available.'));
}

function showWindowsInstructions(needsImageMagick: boolean, needsFfmpeg: boolean): void {
    console.log(pc.cyan('Windows:'));
    console.log();
    
    if (needsImageMagick && needsFfmpeg) {
        console.log(pc.bold('Using Chocolatey') + ' (recommended):');
        console.log('  choco install imagemagick ffmpeg');
        console.log('  Chocolatey: https://chocolatey.org/install');
        console.log();
        console.log(pc.bold('Using Scoop:'));
        console.log('  scoop install imagemagick ffmpeg');
        console.log('  Scoop: https://scoop.sh');
    } else if (needsImageMagick) {
        console.log(pc.bold('Using Chocolatey') + ' (recommended):');
        console.log('  choco install imagemagick');
        console.log('  Chocolatey: https://chocolatey.org/install');
        console.log();
        console.log(pc.bold('Using Scoop:'));
        console.log('  scoop install imagemagick');
        console.log('  Scoop: https://scoop.sh');
    } else if (needsFfmpeg) {
        console.log(pc.bold('Using Chocolatey') + ' (recommended):');
        console.log('  choco install ffmpeg');
        console.log('  Chocolatey: https://chocolatey.org/install');
        console.log();
        console.log(pc.bold('Using Scoop:'));
        console.log('  scoop install ffmpeg');
        console.log('  Scoop: https://scoop.sh');
    }
    
    console.log();
    console.log(pc.bold('Manual installation:'));
    if (needsImageMagick) {
        console.log('  • ImageMagick: https://imagemagick.org/script/download.php#windows');
        console.log('    (Installs both modern "magick" and legacy "convert/identify" commands)');
    }
    if (needsFfmpeg) {
        console.log('  • ffmpeg: https://www.gyan.dev/ffmpeg/builds/');
        console.log('    (Download "release essentials" build - includes ffprobe)');
    }
}

function showMacOSInstructions(needsImageMagick: boolean, needsFfmpeg: boolean): void {
    console.log(pc.cyan('macOS:'));
    console.log();
    
    if (needsImageMagick && needsFfmpeg) {
        console.log(pc.bold('Using Homebrew') + ' (recommended):');
        console.log('  brew install imagemagick ffmpeg');
        console.log('  Homebrew: https://brew.sh');
        console.log();
        console.log(pc.bold('Using MacPorts:'));
        console.log('  sudo port install ImageMagick +universal');
        console.log('  sudo port install ffmpeg +universal');
        console.log('  MacPorts: https://www.macports.org/install.php');
    } else if (needsImageMagick) {
        console.log(pc.bold('Using Homebrew') + ' (recommended):');
        console.log('  brew install imagemagick');
        console.log('  Homebrew: https://brew.sh');
        console.log();
        console.log(pc.bold('Using MacPorts:'));
        console.log('  sudo port install ImageMagick +universal');
        console.log('  MacPorts: https://www.macports.org/install.php');
    } else if (needsFfmpeg) {
        console.log(pc.bold('Using Homebrew') + ' (recommended):');
        console.log('  brew install ffmpeg');
        console.log('  Homebrew: https://brew.sh');
        console.log();
        console.log(pc.bold('Using MacPorts:'));
        console.log('  sudo port install ffmpeg +universal');
        console.log('  MacPorts: https://www.macports.org/install.php');
    }
    
    console.log();
    console.log(pc.bold('Manual installation:'));
    if (needsImageMagick) {
        console.log('  • ImageMagick: https://imagemagick.org/script/download.php#macosx');
        console.log('    (Installs both modern "magick" and legacy "convert/identify" commands)');
    }
    if (needsFfmpeg) {
        console.log('  • ffmpeg: https://evermeet.cx/ffmpeg/');
        console.log('    (Includes ffprobe)');
    }
}

function showLinuxInstructions(needsImageMagick: boolean, needsFfmpeg: boolean): void {
    console.log(pc.cyan('Linux:'));
    console.log();
    
    if (needsImageMagick && needsFfmpeg) {
        console.log(pc.bold('Ubuntu/Debian:'));
        console.log('  sudo apt update');
        console.log('  sudo apt install imagemagick ffmpeg');
        console.log();
        console.log(pc.bold('Fedora/RHEL/CentOS:'));
        console.log('  sudo dnf install ImageMagick ffmpeg');
        console.log();
        console.log(pc.bold('Arch Linux:'));
        console.log('  sudo pacman -S imagemagick ffmpeg');
        console.log();
        console.log(pc.bold('Alpine Linux:'));
        console.log('  sudo apk add imagemagick ffmpeg');
    } else if (needsImageMagick) {
        console.log(pc.bold('Ubuntu/Debian:'));
        console.log('  sudo apt update');
        console.log('  sudo apt install imagemagick');
        console.log();
        console.log(pc.bold('Fedora/RHEL/CentOS:'));
        console.log('  sudo dnf install ImageMagick');
        console.log();
        console.log(pc.bold('Arch Linux:'));
        console.log('  sudo pacman -S imagemagick');
        console.log();
        console.log(pc.bold('Alpine Linux:'));
        console.log('  sudo apk add imagemagick');
    } else if (needsFfmpeg) {
        console.log(pc.bold('Ubuntu/Debian:'));
        console.log('  sudo apt update');
        console.log('  sudo apt install ffmpeg');
        console.log();
        console.log(pc.bold('Fedora/RHEL/CentOS:'));
        console.log('  sudo dnf install ffmpeg');
        console.log();
        console.log(pc.bold('Arch Linux:'));
        console.log('  sudo pacman -S ffmpeg');
        console.log();
        console.log(pc.bold('Alpine Linux:'));
        console.log('  sudo apk add ffmpeg');
    }
    
    console.log();
    console.log(pc.bold('Manual/Binary installation:'));
    if (needsImageMagick) {
        console.log('  • ImageMagick: https://imagemagick.org/script/download.php#linux');
        console.log('    (Both modern "magick" and legacy "convert/identify" commands supported)');
    }
    if (needsFfmpeg) {
        console.log('  • ffmpeg: https://johnvansickle.com/ffmpeg/');
        console.log('    (Static builds for Linux - includes ffprobe)');
    }
}

function showGenericInstructions(needsImageMagick: boolean, needsFfmpeg: boolean): void {
    console.log('Please install the following tools for your system:');
    console.log();
    
    if (needsImageMagick) {
        console.log(pc.bold('ImageMagick:'));
        console.log('  Official site: https://imagemagick.org');
        console.log('  Downloads: https://imagemagick.org/script/download.php');
        console.log('  (Provides both modern "magick" and legacy "convert/identify" commands)');
        console.log();
    }
    if (needsFfmpeg) {
        console.log(pc.bold('ffmpeg (includes ffprobe):'));
        console.log('  Official site: https://ffmpeg.org');
        console.log('  Downloads: https://ffmpeg.org/download.html');
    }
}