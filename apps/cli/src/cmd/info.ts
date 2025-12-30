import { scanPaths, IFileStat } from "api";
import { ICommandContext } from "../lib/init-cmd";
import { configureLog } from "../lib/log";
import pc from "picocolors";
import { exit } from "node-utils";
import { getFileInfo, AssetInfo } from "tools";
import path from "path";
import { ensureMediaProcessingTools } from '../lib/ensure-tools';
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { computeHash } from "api";
import { createReadStream } from "fs";
import { formatBytes } from "../lib/format";
import { log } from "utils";
import mime from "mime";

export interface IInfoCommandOptions { 
    //
    // Enables verbose logging.
    //
    verbose?: boolean;

    //
    // Enables tool output logging.
    //
    tools?: boolean;

    //
    // Non-interactive mode - use defaults and command line arguments.
    //
    yes?: boolean;
}

interface FileAnalysis {
    path: string;
    fileStat: IFileStat;
    assetInfo?: AssetInfo;
    hash?: string;
    error?: string;
    logicalPath: string; // Logical path showing root zip file, parent zip names, and file name (always set)
}

//
// Command that displays detailed information about media files.
//
export async function infoCommand(context: ICommandContext, paths: string[], options: IInfoCommandOptions): Promise<void> {
    const { uuidGenerator, sessionTempDir } = context;

    // Ensure media processing tools are available
    await ensureMediaProcessingTools(options.yes || false);
    
    const results: FileAnalysis[] = [];
    let fileCount = 0;
    
    writeProgress(`Searching for files...`);
    
    await scanPaths(paths, async (fileResult) => {
        try {
            const analysis = await analyzeFile(fileResult.filePath, fileResult.contentType, fileResult.fileStat, fileResult.logicalPath);
            results.push(analysis);
            fileCount++;
        } catch (error) {
            results.push({
                path: fileResult.filePath,
                fileStat: fileResult.fileStat,
                logicalPath: fileResult.logicalPath,
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
    }, { ignorePatterns: [/\.db/] }, sessionTempDir, uuidGenerator);

    clearProgressMessage();

    log.info(`\nInfo for ${fileCount} files:\n`);

    for (const result of results) {
        displayFileInfo(result, options);
        log.info('');
    }

    log.info(pc.green(`\nDisplayed info for ${fileCount} files.`));
    log.info('');

    await exit(0);
}

async function analyzeFile(filePath: string, contentType: string, fileInfo: IFileStat, logicalPath: string): Promise<FileAnalysis> {
    // filePath is either the temporary unpacked file path or the original source file path
    let fileAnalysis: FileAnalysis = {
        path: filePath,
        fileStat: fileInfo,
        logicalPath, // Include logical path if provided (shows location in zip files)
    };
    
    try {
        // Calculate file hash
        try {
            const fileStream = createReadStream(filePath);
            const hashBuffer = await computeHash(fileStream);
            fileAnalysis.hash = hashBuffer.toString("hex");
        } 
        catch (error) {
            log.verbose(`Failed to calculate hash for ${filePath}: ${error}`);
        }

        // Analyze file content using the unified getFileInfo function
        // Files are already unpacked, so we can use the file path directly
        try {
            const assetInfo = await getFileInfo(filePath, contentType);        
            if (assetInfo) {
                fileAnalysis.assetInfo = assetInfo;
            }
        } 
        catch (error) {
            fileAnalysis.error = `Failed to analyze file: ${error}`;
        }
    } catch (error) {
        fileAnalysis.error = `Failed to analyze file: ${error instanceof Error ? error.message : String(error)}`;
    }

    return fileAnalysis;
}

function displayFileInfo(analysis: FileAnalysis, options: IInfoCommandOptions) {
    const { path, fileStat: fileInfo, assetInfo, hash, error, logicalPath } = analysis;
    
    // Use logicalPath for display (always set)
    console.log(pc.bold(pc.blue(`📁 ${logicalPath}`)));
    
    if (error) {
        console.log(`   ${pc.red(`Error: ${error}`)}`);
        return;
    }

    // Get MIME type from fileInfo.contentType or infer from file extension
    const mimeType = fileInfo.contentType || mime.getType(path) || 'application/octet-stream';
    console.log(`   Type: ${mimeType}`);
    
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
