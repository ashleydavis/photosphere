import { scanPaths } from "api";
import { log } from "utils";
import { configureLog } from "../lib/log";
import pc from "picocolors";
import { exit } from "node-utils";
import { getFileInfo, AssetInfo } from "tools";
import path from "path";
import { ensureMediaProcessingTools } from '../lib/ensure-tools';
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { computeHash } from "adb";
import fs from "fs";
import { Readable } from "stream";
import { IFileInfo } from "storage";

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
    fileInfo: IFileInfo;
    assetInfo?: AssetInfo;
    hash?: string;
    error?: string;
}

//
// Command that displays detailed information about media files.
//
export async function infoCommand(paths: string[], options: IInfoCommandOptions): Promise<void> {

    configureLog({
        verbose: options.verbose,
    });

    // Ensure media processing tools are available
    await ensureMediaProcessingTools(options.yes || false);
    
    const results: FileAnalysis[] = [];
    let fileCount = 0;
    
    writeProgress(`Searching for files...`);
    
    // Scan all paths using the new file scanner
    await scanPaths(paths, async (fileResult) => {
        try {
            const analysis = await analyzeFile(fileResult.filePath, fileResult.fileInfo, fileResult.openStream);
            results.push(analysis);
            fileCount++;
        } catch (error) {
            results.push({
                path: fileResult.filePath,
                fileInfo: fileResult.fileInfo,
                error: error instanceof Error ? error.message : String(error)
            });
            fileCount++;
        }
    }, (currentlyScanning) => {
        let progressMessage = `Analyzed: ${pc.green(fileCount.toString())} files`;
        if (currentlyScanning) {
            progressMessage += ` | Scanning ${pc.cyan(currentlyScanning)}`;
        }
        progressMessage += ` | ${pc.gray("Abort with Ctrl-C")}`;
        writeProgress(progressMessage);
    });

    clearProgressMessage();

    // Display detailed information for each file
    console.log(pc.green(`\nAnalyzed ${fileCount} files:\n`));

    for (const result of results) {
        displayFileInfo(result, options);
        console.log(); // Add spacing between files
    }

    await exit(0);
}

async function analyzeFile(filePath: string, fileInfo: IFileInfo, openStream?: () => Readable): Promise<FileAnalysis> {
    const absolutePath = path.resolve(filePath);
    
    let fileAnalysis: FileAnalysis = {
        path: filePath,
        fileInfo,        
    };
    
    // Calculate file hash
    try {
        const fileStream = openStream ? openStream() : fs.createReadStream(absolutePath);
        const hashBuffer = await computeHash(fileStream);
        fileAnalysis.hash = hashBuffer.toString("hex");
    } 
    catch (error) {
        log.verbose(`Failed to calculate hash for ${filePath}: ${error}`);
    }

    // Analyze file content using the unified getFileInfo function
    try {
        const assetInfo = await getFileInfo(absolutePath, fileInfo.contentType!);        
        if (assetInfo) {
            fileAnalysis.assetInfo = assetInfo;
        }
    } 
    catch (error) {
        fileAnalysis.error = `Failed to analyze file: ${error}`;
    }

    return fileAnalysis;
}

function displayFileInfo(analysis: FileAnalysis, options: IInfoCommandOptions) {
    const { path, fileInfo, assetInfo, hash, error } = analysis;
    
    console.log(pc.bold(pc.blue(`📁 ${path}`)));
    
    if (error) {
        console.log(`   ${pc.red(`Error: ${error}`)}`);
        return;
    }

    console.log(`   Type: ${fileInfo.contentType}`);
    
    if (hash) {
        console.log(`   Hash: ${pc.gray(hash)}`);
    }
    
    console.log(`   Size: ${formatBytes(fileInfo.length)}`);
    console.log(`   Modified: ${fileInfo.lastModified.toLocaleString()}`);

    if (assetInfo?.dimensions) {
        console.log(`   Dimensions: ${assetInfo?.dimensions.width} × ${assetInfo?.dimensions.height}`);
    }

    if (analysis.error) {
        console.log(`   ${pc.yellow(`Analysis Error: ${analysis.error}`)}`);
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