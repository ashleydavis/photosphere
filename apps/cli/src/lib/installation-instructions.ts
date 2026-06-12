import pc from "picocolors";
import { platform } from "os";
import { log } from "utils";

/**
 * Shows platform-specific installation instructions for missing tools
 */
export function showInstallationInstructions(missingTools: string[]): void {
    log.info('');
    log.info(pc.bold('Installation Instructions:'));
    log.info('');
    
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
    
    log.info('');
    log.info(pc.dim('After installation, run this command again to verify all tools are available.'));
}

function showWindowsInstructions(needsImageMagick: boolean, needsFfmpeg: boolean): void {
    log.info(pc.cyan('Windows:'));
    log.info('');
    
    if (needsImageMagick && needsFfmpeg) {
        log.info(pc.bold('Using Chocolatey') + ' (recommended):');
        log.info('  choco install imagemagick ffmpeg');
        log.info('  Chocolatey: https://chocolatey.org/install');
        log.info('');
        log.info(pc.bold('Using Scoop:'));
        log.info('  scoop install imagemagick ffmpeg');
        log.info('  Scoop: https://scoop.sh');
    } else if (needsImageMagick) {
        log.info(pc.bold('Using Chocolatey') + ' (recommended):');
        log.info('  choco install imagemagick');
        log.info('  Chocolatey: https://chocolatey.org/install');
        log.info('');
        log.info(pc.bold('Using Scoop:'));
        log.info('  scoop install imagemagick');
        log.info('  Scoop: https://scoop.sh');
    } else if (needsFfmpeg) {
        log.info(pc.bold('Using Chocolatey') + ' (recommended):');
        log.info('  choco install ffmpeg');
        log.info('  Chocolatey: https://chocolatey.org/install');
        log.info('');
        log.info(pc.bold('Using Scoop:'));
        log.info('  scoop install ffmpeg');
        log.info('  Scoop: https://scoop.sh');
    }
    
    log.info('');
    log.info(pc.bold('Manual installation:'));
    if (needsImageMagick) {
        log.info('  • ImageMagick:');
        log.info('    1. Download the Windows installer from https://imagemagick.org/script/download.php#windows');
        log.info('    2. Run the installer and tick "Add application directory to your system path"');
        log.info('    3. Also tick "Install legacy utilities (e.g. convert)"');
        log.info('    4. Open a new terminal and run "magick -version" to verify');
    }
    if (needsFfmpeg) {
        log.info('  • ffmpeg:');
        log.info('    1. Download the "release essentials" build from https://www.gyan.dev/ffmpeg/builds/');
        log.info('       (includes ffprobe)');
        log.info('    2. Extract the zip to a folder, e.g. C:\\ffmpeg');
        log.info('    3. Add the bin folder (e.g. C:\\ffmpeg\\bin) to your PATH environment variable');
        log.info('    4. Open a new terminal and run "ffmpeg -version" to verify');
    }
}

function showMacOSInstructions(needsImageMagick: boolean, needsFfmpeg: boolean): void {
    log.info(pc.cyan('macOS:'));
    log.info('');
    
    if (needsImageMagick && needsFfmpeg) {
        log.info(pc.bold('Using Homebrew') + ' (recommended):');
        log.info('  brew install imagemagick ffmpeg');
        log.info('  Homebrew: https://brew.sh');
        log.info('');
        log.info(pc.bold('Using MacPorts:'));
        log.info('  sudo port install ImageMagick +universal');
        log.info('  sudo port install ffmpeg +universal');
        log.info('  MacPorts: https://www.macports.org/install.php');
    } else if (needsImageMagick) {
        log.info(pc.bold('Using Homebrew') + ' (recommended):');
        log.info('  brew install imagemagick');
        log.info('  Homebrew: https://brew.sh');
        log.info('');
        log.info(pc.bold('Using MacPorts:'));
        log.info('  sudo port install ImageMagick +universal');
        log.info('  MacPorts: https://www.macports.org/install.php');
    } else if (needsFfmpeg) {
        log.info(pc.bold('Using Homebrew') + ' (recommended):');
        log.info('  brew install ffmpeg');
        log.info('  Homebrew: https://brew.sh');
        log.info('');
        log.info(pc.bold('Using MacPorts:'));
        log.info('  sudo port install ffmpeg +universal');
        log.info('  MacPorts: https://www.macports.org/install.php');
    }
    
    log.info('');
    log.info(pc.bold('Manual installation:'));
    if (needsImageMagick) {
        log.info('  • ImageMagick:');
        log.info('    1. Download the macOS build from https://imagemagick.org/script/download.php#macosx');
        log.info('    2. Extract it and move the contents to a folder, e.g. /usr/local/imagemagick');
        log.info('    3. Add the bin folder to your PATH, e.g. add this to ~/.zshrc:');
        log.info('       export PATH="/usr/local/imagemagick/bin:$PATH"');
        log.info('    4. Open a new terminal and run "magick -version" to verify');
    }
    if (needsFfmpeg) {
        log.info('  • ffmpeg:');
        log.info('    1. Download ffmpeg and ffprobe from https://evermeet.cx/ffmpeg/');
        log.info('    2. Extract the archives and move both binaries to /usr/local/bin');
        log.info('    3. Open a new terminal and run "ffmpeg -version" to verify');
    }
}

function showLinuxInstructions(needsImageMagick: boolean, needsFfmpeg: boolean): void {
    log.info(pc.cyan('Linux:'));
    log.info('');
    
    if (needsImageMagick && needsFfmpeg) {
        log.info(pc.bold('Ubuntu/Debian:'));
        log.info('  sudo apt update');
        log.info('  sudo apt install imagemagick ffmpeg');
        log.info('');
        log.info(pc.bold('Fedora/RHEL/CentOS:'));
        log.info('  sudo dnf install ImageMagick ffmpeg');
        log.info('');
        log.info(pc.bold('Arch Linux:'));
        log.info('  sudo pacman -S imagemagick ffmpeg');
        log.info('');
        log.info(pc.bold('Alpine Linux:'));
        log.info('  sudo apk add imagemagick ffmpeg');
    } else if (needsImageMagick) {
        log.info(pc.bold('Ubuntu/Debian:'));
        log.info('  sudo apt update');
        log.info('  sudo apt install imagemagick');
        log.info('');
        log.info(pc.bold('Fedora/RHEL/CentOS:'));
        log.info('  sudo dnf install ImageMagick');
        log.info('');
        log.info(pc.bold('Arch Linux:'));
        log.info('  sudo pacman -S imagemagick');
        log.info('');
        log.info(pc.bold('Alpine Linux:'));
        log.info('  sudo apk add imagemagick');
    } else if (needsFfmpeg) {
        log.info(pc.bold('Ubuntu/Debian:'));
        log.info('  sudo apt update');
        log.info('  sudo apt install ffmpeg');
        log.info('');
        log.info(pc.bold('Fedora/RHEL/CentOS:'));
        log.info('  sudo dnf install ffmpeg');
        log.info('');
        log.info(pc.bold('Arch Linux:'));
        log.info('  sudo pacman -S ffmpeg');
        log.info('');
        log.info(pc.bold('Alpine Linux:'));
        log.info('  sudo apk add ffmpeg');
    }
    
    log.info('');
    log.info(pc.bold('Manual/Binary installation:'));
    if (needsImageMagick) {
        log.info('  • ImageMagick:');
        log.info('    1. Download the AppImage from https://imagemagick.org/script/download.php#linux');
        log.info('    2. Make it executable and place it on your PATH:');
        log.info('       chmod +x ImageMagick-*.AppImage && sudo mv ImageMagick-*.AppImage /usr/local/bin/magick');
        log.info('    3. Run "magick -version" to verify');
    }
    if (needsFfmpeg) {
        log.info('  • ffmpeg:');
        log.info('    1. Download a static build from https://github.com/BtbN/FFmpeg-Builds/releases');
        log.info('       (linked from https://ffmpeg.org/download.html - includes ffprobe)');
        log.info('    2. Extract the archive and copy ffmpeg and ffprobe to /usr/local/bin');
        log.info('    3. Run "ffmpeg -version" to verify');
    }
}

function showGenericInstructions(needsImageMagick: boolean, needsFfmpeg: boolean): void {
    log.info('Please install the following tools for your system:');
    log.info('');
    
    if (needsImageMagick) {
        log.info(pc.bold('ImageMagick:'));
        log.info('  Official site: https://imagemagick.org');
        log.info('  Downloads: https://imagemagick.org/script/download.php');
        log.info('  (Provides both modern "magick" and legacy "convert/identify" commands)');
        log.info('');
    }
    if (needsFfmpeg) {
        log.info(pc.bold('ffmpeg (includes ffprobe):'));
        log.info('  Official site: https://ffmpeg.org');
        log.info('  Downloads: https://ffmpeg.org/download.html');
    }
}