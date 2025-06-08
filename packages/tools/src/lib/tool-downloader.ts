import { exec } from 'child_process';
import { promisify } from 'util';
import { existsSync, mkdirSync, chmodSync, writeFileSync, copyFileSync, rmSync } from 'fs';
import { join } from 'path';
import { homedir, platform, arch, tmpdir } from 'os';
import * as p from '@clack/prompts';

const execAsync = promisify(exec);

interface DownloadInfo {
    url: string;
    filename: string;
    executable: string;
    extract?: boolean | 'appimage' | 'macos-imagemagick';
    extractPath?: string;
}

interface ToolUrls {
    magick?: DownloadInfo;
    ffmpeg?: DownloadInfo;
    ffprobe?: DownloadInfo;
}

function getToolUrls(): ToolUrls | null {
    const currentPlatform = platform();
    const currentArch = arch();
    
    const urls: ToolUrls = {};
    
    switch (currentPlatform) {
        case 'win32':
            // Windows x64
            if (currentArch === 'x64') {
                urls.magick = {
                    url: 'https://download.imagemagick.org/archive/binaries/ImageMagick-7.1.1-47-portable-Q16-HDRI-x64.zip',
                    filename: 'ImageMagick-portable.zip',
                    executable: 'magick.exe',
                    extract: true,
                    extractPath: 'ImageMagick-7.1.1-47-portable-Q16-HDRI-x64'
                };
                // ffmpeg package provides both ffmpeg and ffprobe
                const ffmpegInfo = {
                    url: 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip',
                    filename: 'ffmpeg-win64.zip',
                    executable: 'ffmpeg.exe',
                    extract: true,
                    extractPath: 'ffmpeg-master-latest-win64-gpl/bin'
                };
                urls.ffmpeg = ffmpegInfo;
                urls.ffprobe = ffmpegInfo; // Same package, different executable
            }
            break;
            
        case 'darwin':
            // macOS - Use portable AppImage-like approach
            urls.magick = {
                url: 'https://download.imagemagick.org/archive/binaries/ImageMagick-x86_64-apple-darwin20.1.0.tar.gz',
                filename: 'ImageMagick-mac.tar.gz',
                executable: 'magick',
                extract: 'macos-imagemagick'  // Special handling for macOS ImageMagick
            };
            // Use a single ffmpeg build that includes both tools
            const ffmpegInfo = {
                url: 'https://evermeet.cx/ffmpeg/getrelease/zip',
                filename: 'ffmpeg-mac.zip',
                executable: 'ffmpeg',
                extract: true
            };
            urls.ffmpeg = ffmpegInfo;
            urls.ffprobe = ffmpegInfo; // Same package, different executable
            break;
            
        case 'linux':
            // Linux x64
            if (currentArch === 'x64') {
                urls.magick = {
                    url: 'https://download.imagemagick.org/archive/binaries/magick',
                    filename: 'magick',
                    executable: 'magick',
                    extract: 'appimage'  // Special flag for AppImage extraction
                };
                // ffmpeg package provides both ffmpeg and ffprobe
                const ffmpegInfo = {
                    url: 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-linux64-gpl.tar.xz',
                    filename: 'ffmpeg-linux64.tar.xz',
                    executable: 'ffmpeg',
                    extract: true,
                    extractPath: 'ffmpeg-master-latest-linux64-gpl/bin'
                };
                urls.ffmpeg = ffmpegInfo;
                urls.ffprobe = ffmpegInfo; // Same package, different executable
            }
            break;
    }
    
    return Object.keys(urls).length > 0 ? urls : null;
}

function getToolsDirectory(): string {
    const toolsDir = join(homedir(), '.photosphere', 'tools');
    if (!existsSync(toolsDir)) {
        mkdirSync(toolsDir, { recursive: true });
    }
    return toolsDir;
}

async function downloadFile(url: string, outputPath: string): Promise<void> {
    try {
        const response = await fetch(url);
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}: ${response.statusText}`);
        }
        
        const arrayBuffer = await response.arrayBuffer();
        const buffer = Buffer.from(arrayBuffer);
        writeFileSync(outputPath, buffer);
    } catch (error) {
        throw new Error(`Failed to download ${url}: ${error}`);
    }
}

async function extractFile(filePath: string, extractDir: string, extractPath?: string): Promise<void> {
    const filename = filePath.toLowerCase();
    
    try {
        if (filename.endsWith('.zip')) {
            // Use system unzip command
            const command = platform() === 'win32' 
                ? `powershell -command "Expand-Archive -Path '${filePath}' -DestinationPath '${extractDir}' -Force"`
                : `unzip -o "${filePath}" -d "${extractDir}"`;
            await execAsync(command);
        } else if (filename.endsWith('.tar.gz') || filename.endsWith('.tar.xz')) {
            const tarOptions = filename.endsWith('.tar.xz') ? 'xf' : 'xzf';
            await execAsync(`tar ${tarOptions} "${filePath}" -C "${extractDir}"`);
        }
    } catch (error) {
        throw new Error(`Failed to extract ${filePath}: ${error}`);
    }
}

async function extractAppImage(appImagePath: string, extractDir: string): Promise<{binaryPath: string, extractedDir: string}> {
    try {
        // Make the AppImage executable
        chmodSync(appImagePath, '755');
        
        // Extract the AppImage using --appimage-extract
        const { stdout, stderr } = await execAsync(`cd "${extractDir}" && "${appImagePath}" --appimage-extract`);
        
        // AppImage extracts to squashfs-root directory
        const extractedDir = join(extractDir, 'squashfs-root');
        if (!existsSync(extractedDir)) {
            throw new Error('AppImage extraction failed - squashfs-root directory not found');
        }
        
        // Find the magick binary in the extracted directory
        const possibleMagickPaths = [
            join(extractedDir, 'usr', 'bin', 'magick'),
            join(extractedDir, 'bin', 'magick'),
            join(extractedDir, 'magick')
        ];
        
        for (const magickPath of possibleMagickPaths) {
            if (existsSync(magickPath)) {
                return { binaryPath: magickPath, extractedDir };
            }
        }
        
        throw new Error('magick binary not found in extracted AppImage');
    } catch (error) {
        throw new Error(`Failed to extract AppImage ${appImagePath}: ${error}`);
    }
}

async function downloadTool(toolName: string, downloadInfo: DownloadInfo, toolsDir: string): Promise<string[]> {
    // Create temporary directory for downloads and extraction
    const tempDir = join(tmpdir(), `photosphere-download-${Date.now()}-${Math.random().toString(36).substring(2)}`);
    mkdirSync(tempDir, { recursive: true });
    
    const downloadPath = join(tempDir, downloadInfo.filename);
    
    try {
        await downloadFile(downloadInfo.url, downloadPath);
        
        if (downloadInfo.extract === 'macos-imagemagick') {
            // Handle macOS ImageMagick with dylib dependencies
            await extractFile(downloadPath, tempDir, downloadInfo.extractPath);
            
            // Create a dedicated directory for ImageMagick
            const magickDir = join(toolsDir, 'imagemagick-macos');
            if (!existsSync(magickDir)) {
                mkdirSync(magickDir, { recursive: true });
            }
            
            // Find and copy the entire ImageMagick directory
            const { readdirSync, statSync } = require('fs');
            console.log(`Temp directory contents:`);
            const tempContents = readdirSync(tempDir);
            tempContents.forEach((item: string) => {
                const itemPath = join(tempDir, item);
                const isDir = statSync(itemPath).isDirectory();
                console.log(`  ${item} ${isDir ? '(directory)' : '(file)'}`);
            });
            
            const imageMagickDirs = tempContents.filter((item: string) => {
                const itemPath = join(tempDir, item);
                return statSync(itemPath).isDirectory() && item.startsWith('ImageMagick-');
            });
            
            if (imageMagickDirs.length === 0) {
                throw new Error('No ImageMagick directory found in extracted archive');
            }
            
            const sourceDir = join(tempDir, imageMagickDirs[0]);
            console.log(`Copying from: ${sourceDir}`);
            console.log(`Copying to: ${magickDir}`);
            
            // Copy entire ImageMagick directory to preserve structure
            await execAsync(`cp -R "${sourceDir}"/* "${magickDir}"/`);
            
            // Find the magick binary
            const possibleBinaryPaths = [
                join(magickDir, 'bin', 'magick'),
                join(magickDir, 'magick')
            ];
            
            let actualBinaryPath = '';
            for (const path of possibleBinaryPaths) {
                if (existsSync(path)) {
                    actualBinaryPath = path;
                    break;
                }
            }
            
            if (!actualBinaryPath) {
                throw new Error('Could not find magick binary in copied directory');
            }
            
            // Create a wrapper script that sets up library paths
            const wrapperPath = join(toolsDir, downloadInfo.executable);
            const libPath = join(magickDir, 'lib');
            
            const wrapperScript = `#!/bin/bash
# Wrapper script for ImageMagick on macOS
export DYLD_LIBRARY_PATH="${libPath}:$DYLD_LIBRARY_PATH"
export MAGICK_HOME="${magickDir}"
export MAGICK_CONFIGURE_PATH="${magickDir}/lib/ImageMagick/config-Q16HDRI"
export MAGICK_CODER_MODULE_PATH="${magickDir}/lib/ImageMagick/modules-Q16HDRI/coders"
export MAGICK_FILTER_MODULE_PATH="${magickDir}/lib/ImageMagick/modules-Q16HDRI/filters"
exec "${actualBinaryPath}" "$@"
`;
            
            writeFileSync(wrapperPath, wrapperScript);
            chmodSync(wrapperPath, '755');
            
            // Verify the wrapper script works
            try {
                const { stdout } = await execAsync(`"${wrapperPath}" --version`);
                console.log(`✓ ImageMagick wrapper verification successful`);
            } catch (verifyError) {
                throw new Error(`ImageMagick wrapper verification failed: ${verifyError}`);
            }
            
            // Clean up temporary files
            try {
                rmSync(downloadPath, { force: true });
                rmSync(tempDir, { recursive: true, force: true });
            } catch (cleanupError) {
                console.warn(`Warning: Could not clean up temporary files: ${cleanupError}`);
            }
            
            return [wrapperPath];
            
        } else if (downloadInfo.extract === 'appimage') {
            // Handle AppImage extraction
            const { binaryPath, extractedDir } = await extractAppImage(downloadPath, tempDir);
            
            // Create a dedicated directory for this AppImage's files
            const magickDir = join(toolsDir, 'imagemagick-appimage');
            if (!existsSync(magickDir)) {
                mkdirSync(magickDir, { recursive: true });
            }
            
            // Copy the entire extracted directory to preserve library dependencies
            const { stdout: cpOutput } = await execAsync(`cp -r "${extractedDir}"/* "${magickDir}"/`);
            
            // Find the actual binary in the copied directory
            const possibleBinaryPaths = [
                join(magickDir, 'usr', 'bin', 'magick'),
                join(magickDir, 'bin', 'magick'),
                join(magickDir, 'magick')
            ];
            
            let actualBinaryPath = '';
            for (const path of possibleBinaryPaths) {
                if (existsSync(path)) {
                    actualBinaryPath = path;
                    break;
                }
            }
            
            if (!actualBinaryPath) {
                throw new Error('Could not find magick binary in copied directory');
            }
            
            // Create a wrapper script that sets up the library path
            const wrapperPath = join(toolsDir, downloadInfo.executable);
            const libPaths = [
                join(magickDir, 'usr', 'lib'),
                join(magickDir, 'usr', 'lib', 'x86_64-linux-gnu'),
                join(magickDir, 'lib'),
                join(magickDir, 'lib', 'x86_64-linux-gnu')
            ].filter(existsSync).join(':');
            
            const wrapperScript = `#!/bin/bash
# Wrapper script for ImageMagick AppImage
export LD_LIBRARY_PATH="${libPaths}${process.env.LD_LIBRARY_PATH ? ':' + process.env.LD_LIBRARY_PATH : ''}"
export MAGICK_HOME="${magickDir}"
exec "${actualBinaryPath}" "$@"
`;
            
            writeFileSync(wrapperPath, wrapperScript);
            chmodSync(wrapperPath, '755');
            
            // Verify the wrapper script works
            try {
                const { stdout } = await execAsync(`"${wrapperPath}" --version`);
                console.log(`✓ ImageMagick wrapper verification successful`);
            } catch (verifyError) {
                throw new Error(`ImageMagick wrapper verification failed: ${verifyError}`);
            }
            
            // Clean up: remove temporary directory but keep the extracted files
            try {
                rmSync(downloadPath, { force: true });
                rmSync(join(tempDir, 'squashfs-root'), { recursive: true, force: true });
            } catch (cleanupError) {
                console.warn(`Warning: Could not clean up temporary files: ${cleanupError}`);
            }
            
            return [wrapperPath];
            
        } else if (downloadInfo.extract) {
            await extractFile(downloadPath, tempDir, downloadInfo.extractPath);
            
            const copiedExecutables: string[] = [];
            
            // For ffmpeg packages, copy both ffmpeg and ffprobe if they exist
            const executablesToCheck = toolName === 'ffmpeg' || toolName === 'ffprobe' 
                ? ['ffmpeg', 'ffprobe'] 
                : [downloadInfo.executable];
            
            for (const execName of executablesToCheck) {
                let executableInExtracted: string | null = null;
                
                if (downloadInfo.extractPath) {
                    // Use the specific extract path
                    executableInExtracted = join(tempDir, downloadInfo.extractPath, execName + (platform() === 'win32' ? '.exe' : ''));
                    if (!existsSync(executableInExtracted)) {
                        executableInExtracted = null;
                    }
                } else {
                    // Search for the executable in common locations
                    const searchPaths = [
                        join(tempDir, execName),
                        join(tempDir, 'bin', execName),
                        join(tempDir, 'usr', 'bin', execName),
                        join(tempDir, 'usr', 'local', 'bin', execName),
                        // Search in any ImageMagick-* directory
                        ...require('fs').readdirSync(tempDir)
                            .filter((dir: string) => dir.startsWith('ImageMagick-'))
                            .flatMap((dir: string) => [
                                join(tempDir, dir, 'bin', execName),
                                join(tempDir, dir, execName)
                            ])
                    ];
                    
                    if (platform() === 'win32') {
                        searchPaths.push(...searchPaths.map(p => p + '.exe'));
                    }
                    
                    for (const searchPath of searchPaths) {
                        if (existsSync(searchPath)) {
                            executableInExtracted = searchPath;
                            console.log(`Found ${execName} at: ${searchPath}`);
                            break;
                        }
                    }
                }
                
                if (executableInExtracted && existsSync(executableInExtracted)) {
                    // Copy executable to tools directory root
                    const finalExecutablePath = join(toolsDir, execName + (platform() === 'win32' ? '.exe' : ''));
                    copyFileSync(executableInExtracted, finalExecutablePath);
                    
                    // Make executable on Unix systems
                    if (platform() !== 'win32') {
                        chmodSync(finalExecutablePath, '755');
                    }
                    
                    copiedExecutables.push(finalExecutablePath);
                }
            }
            
            if (copiedExecutables.length === 0) {
                // List directory contents for debugging
                console.error(`No executables found. Temp directory contents:`);
                const { readdirSync } = require('fs');
                const listDir = (dir: string, prefix: string = '') => {
                    try {
                        const items = readdirSync(dir);
                        items.forEach((item: string) => {
                            console.error(`${prefix}${item}`);
                            const itemPath = join(dir, item);
                            if (require('fs').statSync(itemPath).isDirectory() && prefix.length < 12) {
                                listDir(itemPath, prefix + '  ');
                            }
                        });
                    } catch (err) {
                        console.error(`${prefix}[Error reading directory]`);
                    }
                };
                listDir(tempDir);
                throw new Error(`No executables found in extracted package`);
            }
            
            // Clean up: remove entire temporary directory
            try {
                rmSync(tempDir, { recursive: true, force: true });
            } catch (cleanupError) {
                // Log cleanup error but don't fail the installation
                console.warn(`Warning: Could not clean up temporary directory: ${tempDir}: ${cleanupError}`);
            }
            
            return copiedExecutables;
        } else {
            // For non-extracted files, copy directly to tools directory
            const finalExecutablePath = join(toolsDir, downloadInfo.executable);
            copyFileSync(downloadPath, finalExecutablePath);
            
            // Make executable on Unix systems
            if (platform() !== 'win32') {
                chmodSync(finalExecutablePath, '755');
            }
            
            // Clean up: remove temporary directory
            try {
                rmSync(tempDir, { recursive: true, force: true });
            } catch (cleanupError) {
                console.warn(`Warning: Could not clean up temporary directory: ${tempDir}: ${cleanupError}`);
            }
            
            return [finalExecutablePath];
        }
    } catch (error) {
        // Clean up temporary directory on error
        try {
            rmSync(tempDir, { recursive: true, force: true });
        } catch (cleanupError) {
            console.warn(`Warning: Could not clean up temporary directory after error: ${tempDir}: ${cleanupError}`);
        }
        
        throw error;
    }
}

function getToolDescription(toolName: string): string {
    const descriptions = {
        'magick': 'magick (ImageMagick) - Required for processing images (resizing, format conversion, metadata extraction)',
        'ffprobe': 'ffprobe - Required for analyzing video files and extracting metadata (duration, dimensions, codecs)',
        'ffmpeg': 'ffmpeg - Required for processing videos and extracting thumbnails from video files'
    };
    return descriptions[toolName as keyof typeof descriptions] || toolName;
}

function getManualInstallInstructions(): string {
    const currentPlatform = platform();
    
    switch (currentPlatform) {
        case 'win32':
            return `Manual Installation Instructions for Windows:

ImageMagick:
  1. Download from: https://imagemagick.org/script/download.php#windows
  2. Choose "Win64 dynamic at 16 bits-per-pixel component"
  3. Install to C:\\ImageMagick or add to PATH
  4. Ensure 'magick.exe' is accessible from command line

ffmpeg & ffprobe:
  1. Download from: https://www.gyan.dev/ffmpeg/builds/
  2. Extract to C:\\ffmpeg or another directory
  3. Add the bin folder to your system PATH
  4. Ensure 'ffmpeg.exe' and 'ffprobe.exe' are accessible

Alternative package managers:
  • Chocolatey: choco install imagemagick ffmpeg
  • Scoop: scoop install imagemagick ffmpeg
  • Winget: winget install ImageMagick.ImageMagick && winget install Gyan.FFmpeg`;

        case 'darwin':
            return `Manual Installation Instructions for macOS:

Using Homebrew (recommended):
  brew install imagemagick ffmpeg

Using MacPorts:
  sudo port install ImageMagick +universal
  sudo port install ffmpeg +universal

Manual Downloads:
ImageMagick:
  1. Download from: https://imagemagick.org/script/download.php#macosx
  2. Install the .pkg file
  3. Ensure 'magick' is accessible from Terminal

ffmpeg & ffprobe:
  1. Download from: https://evermeet.cx/ffmpeg/
  2. Extract and place in /usr/local/bin/
  3. Make executable: chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe`;

        case 'linux':
            return `Manual Installation Instructions for Linux:

Using Package Managers:

Ubuntu/Debian:
  sudo apt update
  sudo apt install imagemagick ffmpeg

CentOS/RHEL/Fedora:
  sudo yum install ImageMagick ffmpeg        # CentOS/RHEL
  sudo dnf install ImageMagick ffmpeg        # Fedora

Arch Linux:
  sudo pacman -S imagemagick ffmpeg

Alpine Linux:
  sudo apk add imagemagick ffmpeg

Manual/Portable Installation:
ImageMagick:
  1. Download from: https://download.imagemagick.org/archive/binaries/
  2. Download the Linux binary for your architecture
  3. Make executable and add to PATH

ffmpeg & ffprobe:
  1. Download from: https://johnvansickle.com/ffmpeg/
  2. Extract and add to PATH
  3. Make executable: chmod +x ffmpeg ffprobe`;

        default:
            return `Please install the following tools for your system:
  • ImageMagick: https://imagemagick.org/script/download.php
  • ffmpeg: https://ffmpeg.org/download.html`;
    }
}

async function handleManualInstallation(missingTools: string[]): Promise<boolean> {
    p.log.info('Manual installation selected.');
    
    // Show installation instructions
    const instructions = getManualInstallInstructions();
    p.note(instructions, '📖 Installation Instructions');
    
    // Show where tools should be placed
    const toolsDir = getToolsDirectory();
    p.log.info(`Tip: You can place portable versions directly in: ${toolsDir}`);
    p.log.info('Photosphere will automatically find tools in this directory.');
    
    // Wait for user to install tools
    while (true) {
        const action = await p.select({
            message: 'What would you like to do?',
            options: [
                { value: 'continue', label: 'Continue - I have installed the tools' },
                { value: 'auto', label: 'This is too hard, just install the missing tools automatically' },
                { value: 'exit', label: 'Exit - I will install tools later' }
            ]
        });
        
        if (p.isCancel(action) || action === 'exit') {
            p.log.info('Exiting. Please install the required tools and try again.');
            return false;
        }
        
        if (action === 'auto') {
            p.log.info('Switching to automatic installation...');
            // Return a special value to indicate we want to switch to auto installation
            return 'auto' as any;
        }
        
        if (action === 'continue') {
            // Check if tools are now available
            p.log.step('Checking for installed tools...');
            
            const toolsToCheck = missingTools.map(tool => {
                if (tool.includes('magick')) return 'magick';
                if (tool.includes('ffprobe')) return 'ffprobe';
                if (tool.includes('ffmpeg')) return 'ffmpeg';
                return tool;
            }).filter(Boolean);
            
            const foundTools: string[] = [];
            const stillMissing: string[] = [];
            
            for (const toolName of toolsToCheck) {
                try {
                    // Try to run the tool to verify it's working
                    await execAsync(`${toolName} -version`);
                    foundTools.push(toolName);
                    p.log.success(`✓ ${toolName} found and working`);
                } catch {
                    stillMissing.push(toolName);
                    p.log.error(`✗ ${toolName} still not found`);
                }
            }
            
            if (stillMissing.length === 0) {
                p.log.success('All required tools are now available!');
                p.outro('🎉 Setup complete!');
                return true;
            } else {
                p.log.warn(`Still missing: ${stillMissing.join(', ')}`);
                p.log.info('Please ensure the tools are properly installed and accessible from the command line.');
                
                const retry = await p.confirm({
                    message: 'Would you like to check again?',
                    initialValue: true
                });
                
                if (p.isCancel(retry) || !retry) {
                    p.log.info('Exiting. Please complete the installation and try again.');
                    return false;
                }
                // Continue the loop to check again
            }
        }
    }
}

export async function promptAndDownloadTools(missingTools: string[], nonInteractive: boolean = false): Promise<boolean> {
    const toolUrls = getToolUrls();
    
    if (!toolUrls) {
        console.error(`Automatic downloads not supported for ${platform()}-${arch()}`);
        return false;
    }
    
    console.log();
    console.log('✗ Missing Tools Detected');
    console.log();
    console.log('🏗️  This is a one-time setup - once the tools are installed, you\'re all set!');
    console.log();

    // Explain why tools are needed
    console.log('The following tools are required for media processing:');
    console.log();

    missingTools.forEach(tool => {
        console.log(`  • ${getToolDescription(tool)}`);
    });

    console.log();

    let installChoice = 'auto';
    
    if (!nonInteractive) {
        p.intro('🔧 Install Missing Tools');
        
        const choice = await p.select({
            message: 'How would you like to install the missing tools?',
            options: [
                { value: 'auto', label: 'Install automatically - Download portable versions to ~/.photosphere/tools' },
                { value: 'manual', label: 'Install manually - Show installation instructions for your system' },
                { value: 'exit', label: 'Exit - I will install tools later and run again' }
            ]
        });
        
        if (p.isCancel(choice)) {
            p.log.info('Installation cancelled.');
            return false;
        }
        
        if (typeof choice === 'string') {
            installChoice = choice;
        }
        
        if (installChoice === 'exit') {
            p.log.info('Exiting. Please install the required tools and try again.');
            return false;
        }
        
        if (installChoice === 'manual') {
            const manualResult = await handleManualInstallation(missingTools);
            if (manualResult === 'auto' as any) {
                // User chose to switch to automatic installation from manual mode
                // Continue to automatic installation below
            } else {
                return manualResult;
            }
        }
    } else {
        p.intro('🔧 Installing tools automatically...');
    }
    
    // Show download details
    const toolsToDownload: Array<{name: string, info: DownloadInfo}> = [];
    const processedUrls = new Set<string>();
    const toolsFromSamePackage: Array<{tools: string[], info: DownloadInfo}> = [];
    
    for (const tool of missingTools) {
        const toolKey = tool.includes('magick') ? 'magick' : 
                       tool.includes('ffprobe') ? 'ffprobe' : 
                       tool.includes('ffmpeg') ? 'ffmpeg' : null;
                       
        if (toolKey && toolUrls[toolKey as keyof ToolUrls]) {
            const info = toolUrls[toolKey as keyof ToolUrls]!;
            // Check if we already have this URL in our tracking
            const existingPackage = toolsFromSamePackage.find(pkg => pkg.info.url === info.url);
            
            if (existingPackage) {
                // Add this tool to the existing package
                existingPackage.tools.push(toolKey);
            } else {
                // New package
                toolsFromSamePackage.push({ tools: [toolKey], info });
            }
            
            // Only add to download list if URL hasn't been processed
            if (!processedUrls.has(info.url)) {
                toolsToDownload.push({ name: toolKey, info });
                processedUrls.add(info.url);
            }
        }
    }
    
    // Show what will be downloaded
    for (const { tools, info } of toolsFromSamePackage) {
        if (tools.length === 1) {
            p.log.info(`  ${tools[0]}: ${info.url}`);
        } else {
            p.log.info(`  ${tools.join(' + ')}: ${info.url}`);
        }
    }
    
    const toolsDir = getToolsDirectory();
    p.log.info(`Installation directory: ${toolsDir}`);
    
    if (!nonInteractive) {
        const confirmDownload = await p.confirm({
            message: 'Proceed with downloading these files to your system?',
            initialValue: true
        });
        
        if (p.isCancel(confirmDownload) || !confirmDownload) {
            p.log.info('Download cancelled.');
            return false;
        }
    }
    
    // Download tools in parallel for faster installation
    const downloadedPaths: string[] = [];
    const downloadedInfo: Array<{name: string, path: string, version?: string}> = [];
    
    // Create a comma-separated list of tools being downloaded
    const toolNames = toolsFromSamePackage.flatMap(pkg => pkg.tools).join(', ');
    
    const spinner = p.spinner();
    
    try {
        spinner.start(`Downloading and installing ${toolNames}...`);
        
        // Download all tools in parallel
        const downloadPromises = toolsToDownload.map(({ name, info }) => 
            downloadTool(name, info, toolsDir)
        );
        
        const downloadResults = await Promise.all(downloadPromises);
        spinner.stop(`Downloaded and installed ${toolNames}`);
        
        p.log.success('🎉 All tools downloaded successfully!');
        
        // Flatten all executable paths
        for (const executablePaths of downloadResults) {
            downloadedPaths.push(...executablePaths);
        }
        
        // Get version information for all downloaded tools
        const versionPromises = downloadedPaths.map(async (executablePath) => {
            const toolName = executablePath.includes('ffmpeg') ? 'ffmpeg' :
                            executablePath.includes('ffprobe') ? 'ffprobe' : 
                            executablePath.includes('magick') ? 'magick' : 'unknown';
            
            try {
                const { stdout } = await execAsync(`"${executablePath}" -version`);
                let version = 'unknown';
                
                if (toolName === 'magick') {
                    const match = stdout.match(/Version: ImageMagick ([\d.-]+)/);
                    version = match ? match[1] : 'unknown';
                } else if (toolName === 'ffprobe' || toolName === 'ffmpeg') {
                    const match = stdout.match(new RegExp(`${toolName} version (\\S+)`));
                    if (match) {
                        version = match[1];
                    } else {
                        const altMatch = stdout.match(/version (\\S+)/);
                        version = altMatch ? altMatch[1] : 'unknown';
                    }
                }
                
                return { name: toolName, path: executablePath, version };
            } catch {
                return { name: toolName, path: executablePath };
            }
        });
        
        const versionResults = await Promise.all(versionPromises);
        downloadedInfo.push(...versionResults);
        
        // Show success messages for all tools
        downloadedInfo.forEach(({ name, version }) => {
            p.log.success(`✓ ${name}${version ? ` v${version}` : ''} installed successfully`);
        });
        
        // Show summary of downloaded tools
        if (downloadedInfo.length > 0) {
            let summary = 'Downloaded Tools Summary:\n';
            downloadedInfo.forEach(({ name, path, version }) => {
                summary += `  • ${name}${version ? ` v${version}` : ''}\n`;
                summary += `    Location: ${path}\n`;
            });
            summary += `\nAll tools installed to: ${toolsDir}`;
            
            p.note(summary, '📦 Installation Complete');
        }
        
        p.outro('🎉 Tools downloaded and configured successfully!');
        return true;
        
    } catch (error) {
        spinner.stop(`Download failed`);
        p.log.error(`Download failed: ${error}`);
        return false;
    }
}

export { getToolsDirectory };