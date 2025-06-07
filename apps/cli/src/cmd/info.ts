import { scanPaths } from "api";
import { log } from "utils";
import { configureLog } from "../lib/log";
import pc from "picocolors";
import { exit } from "node-utils";
import { Image, Video } from "tools";
import path from "path";

export interface IInfoCommandOptions { 
    //
    // Set the path to the database metadata.
    //
    meta?: string;

    //
    // Sets the path to private key file for encryption.
    //
    key?: string;

    //
    // Enables verbose logging.
    //
    verbose?: boolean;

    //
    // Non-interactive mode - use defaults and command line arguments.
    //
    yes?: boolean;

    //
    // Show raw EXIF/metadata properties.
    //
    raw?: boolean;
}

interface FileAnalysis {
    path: string;
    contentType: string;
    details?: any;
    error?: string;
}

//
// Command that displays detailed information about media files.
//
export async function infoCommand(dbDir: string, paths: string[], options: IInfoCommandOptions): Promise<void> {

    configureLog({
        verbose: options.verbose,
    });

    console.log(`Analyzing ${paths.length} path(s)...`);
    
    const results: FileAnalysis[] = [];
    let fileCount = 0;
    
    // Scan all paths using the new file scanner
    await scanPaths(paths, async (fileResult) => {
        try {
            const analysis = await analyzeFile(fileResult.filePath, fileResult.contentType, fileResult.openStream);
            results.push(analysis);
            fileCount++;
        } catch (error) {
            results.push({
                path: fileResult.filePath,
                contentType: fileResult.contentType,
                error: error instanceof Error ? error.message : String(error)
            });
            fileCount++;
        }
    }, (currentlyScanning) => {
        if (process.stdout.clearLine) {
            process.stdout.clearLine(0);
            process.stdout.cursorTo(0);
        } else {
            process.stdout.write('\r');
        }
        process.stdout.write(`Analyzed: ${pc.green(fileCount.toString())} files`);
        if (currentlyScanning) {
            process.stdout.write(` | Scanning ${pc.cyan(currentlyScanning)}`);
        }
        process.stdout.write(` | ${pc.gray("Abort with Ctrl-C")}`);
    });

    if (process.stdout.clearLine) {
        process.stdout.clearLine(0);
        process.stdout.cursorTo(0);
    } else {
        process.stdout.write('\r');
    }

    // Display detailed information for each file
    console.log(pc.green(`\nAnalyzed ${fileCount} files:\n`));

    for (const result of results) {
        displayFileInfo(result, options);
        console.log(); // Add spacing between files
    }

    exit(0);
}

async function analyzeFile(filePath: string, contentType: string, openStream?: () => NodeJS.ReadableStream): Promise<FileAnalysis> {
    const absolutePath = path.resolve(filePath);
    
    let details: any = {
        contentType
    };

    // Analyze file content based on type
    if (contentType.startsWith('image/')) {
        try {
            const image = new Image(absolutePath);
            const imageInfo = await image.getInfo();
            const exifData = await image.getExifData();
            
            details = {
                ...details,
                type: 'image',
                format: imageInfo.format,
                dimensions: imageInfo.dimensions,
                colorSpace: imageInfo.colorSpace,
                fileSize: imageInfo.fileSize,
                createdAt: imageInfo.createdAt,
                modifiedAt: imageInfo.modifiedAt,
                exif: exifData
            };
        } catch (error) {
            details.analysisError = `Failed to analyze image: ${error}`;
        }
    } else if (contentType.startsWith('video/')) {
        try {
            const video = new Video(absolutePath);
            const videoInfo = await video.getInfo();
            
            details = {
                ...details,
                type: 'video',
                format: videoInfo.format,
                dimensions: videoInfo.dimensions,
                duration: videoInfo.duration,
                fps: videoInfo.fps,
                bitrate: videoInfo.bitrate,
                hasAudio: videoInfo.hasAudio,
                fileSize: videoInfo.fileSize,
                createdAt: videoInfo.createdAt,
                modifiedAt: videoInfo.modifiedAt
            };
        } catch (error) {
            details.analysisError = `Failed to analyze video: ${error}`;
        }
    }

    return {
        path: filePath,
        contentType,
        details
    };
}

function displayFileInfo(analysis: FileAnalysis, options: IInfoCommandOptions) {
    const { path, contentType, details, error } = analysis;
    
    console.log(pc.bold(pc.blue(`📁 ${path}`)));
    
    if (error) {
        console.log(`   ${pc.red(`Error: ${error}`)}`);
        return;
    }

    console.log(`   Type: ${contentType}`);
    
    if (details.fileSize) {
        console.log(`   Size: ${formatBytes(details.fileSize)}`);
    }
    
    if (details.modifiedAt) {
        console.log(`   Modified: ${details.modifiedAt.toLocaleString()}`);
    }

    if (details.type === 'image') {
        if (details.dimensions) {
            console.log(`   Dimensions: ${details.dimensions.width} × ${details.dimensions.height}`);
        }
        console.log(`   Format: ${details.format.toUpperCase()}`);
        if (details.colorSpace) {
            console.log(`   Color Space: ${details.colorSpace}`);
        }
        
        if (details.exif && Object.keys(details.exif).length > 0) {
            console.log(`   EXIF Data: ${Object.keys(details.exif).length} properties`);
            
            // Show key EXIF properties
            if (details.exif.DateTimeOriginal) {
                console.log(`   📅 Date Taken: ${details.exif.DateTimeOriginal}`);
            }
            if (details.exif.GPSLatitude && details.exif.GPSLongitude) {
                console.log(`   📍 GPS: ${details.exif.GPSLatitude}, ${details.exif.GPSLongitude}`);
            }
            if (details.exif.Model) {
                console.log(`   📷 Camera: ${details.exif.Model}`);
            }
            
            if (options.raw) {
                console.log(`   Raw EXIF:`);
                for (const [key, value] of Object.entries(details.exif)) {
                    console.log(`     ${key}: ${value}`);
                }
            }
        }
    } else if (details.type === 'video') {
        if (details.dimensions) {
            console.log(`   Dimensions: ${details.dimensions.width} × ${details.dimensions.height}`);
        }
        console.log(`   Format: ${details.format.toUpperCase()}`);
        if (details.duration) {
            console.log(`   Duration: ${formatDuration(details.duration)}`);
        }
        if (details.fps) {
            console.log(`   Frame Rate: ${details.fps} fps`);
        }
        if (details.bitrate) {
            console.log(`   Bitrate: ${formatBitrate(details.bitrate)}`);
        }
        if (details.hasAudio !== undefined) {
            console.log(`   Audio: ${details.hasAudio ? 'Yes' : 'No'}`);
        }
    }

    if (details.analysisError) {
        console.log(`   ${pc.yellow(`Analysis Error: ${details.analysisError}`)}`);
    }
}

function formatBytes(bytes: number): string {
    if (bytes === 0) return '0 Bytes';
    const k = 1024;
    const sizes = ['Bytes', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
}

function formatDuration(seconds: number): string {
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    const secs = Math.floor(seconds % 60);
    
    if (hours > 0) {
        return `${hours}:${minutes.toString().padStart(2, '0')}:${secs.toString().padStart(2, '0')}`;
    } else {
        return `${minutes}:${secs.toString().padStart(2, '0')}`;
    }
}

function formatBitrate(bitrate: number): string {
    if (bitrate >= 1000000) {
        return `${(bitrate / 1000000).toFixed(1)} Mbps`;
    } else if (bitrate >= 1000) {
        return `${(bitrate / 1000).toFixed(1)} Kbps`;
    } else {
        return `${bitrate} bps`;
    }
}