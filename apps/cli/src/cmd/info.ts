import { scanPaths, IFileStat } from "api";
import { configureLog } from "../lib/log";
import pc from "picocolors";
import { exit, writeStreamToFile } from "node-utils";
import { getFileInfo, AssetInfo } from "tools";
import path from "path";
import { ensureMediaProcessingTools } from '../lib/ensure-tools';
import { clearProgressMessage, writeProgress } from '../lib/terminal-utils';
import { computeHash, extractFileFromZipRecursive } from "api";
import * as fs from "fs/promises";
import { createReadStream } from "fs";
import { formatBytes } from "../lib/format";
import { log } from "utils";
import mime from "mime";
import { tmpdir } from "os";
import { randomUUID } from "crypto";

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
}

//
// Command that displays detailed information about media files.
//
export async function infoCommand(paths: string[], options: IInfoCommandOptions): Promise<void> {

    await configureLog({
        verbose: options.verbose,
        tools: options.tools
    });

    // Ensure media processing tools are available
    await ensureMediaProcessingTools(options.yes || false);
    
    const results: FileAnalysis[] = [];
    let fileCount = 0;
    
    writeProgress(`Searching for files...`);
    
    await scanPaths(paths, async (fileResult) => {
        try {
            const analysis = await analyzeFile(fileResult.filePath, fileResult.contentType, fileResult.fileStat, fileResult.zipFilePath);
            results.push(analysis);
            fileCount++;
        } catch (error) {
            results.push({
                path: fileResult.filePath,
                fileStat: fileResult.fileStat,
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
    }, { ignorePatterns: [/\.db/] });

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

async function analyzeFile(filePath: string, contentType: string, fileInfo: IFileStat, zipFilePath?: string): Promise<FileAnalysis> {
    const absolutePath = zipFilePath ? zipFilePath : path.resolve(filePath);
    
    let fileAnalysis: FileAnalysis = {
        path: filePath,
        fileStat: fileInfo,        
    };
    
    let tempFilePath: string | undefined;
    
    try {
        // Calculate file hash
        try {
            const fileStream = zipFilePath 
                ? await extractFileFromZipRecursive(zipFilePath, filePath)
                : createReadStream(absolutePath);
            const hashBuffer = await computeHash(fileStream);
            fileAnalysis.hash = hashBuffer.toString("hex");
        } 
        catch (error) {
            log.verbose(`Failed to calculate hash for ${filePath}: ${error}`);
        }

        // Analyze file content using the unified getFileInfo function
        // For zip files, extract to temporary location first
        let actualFilePath = absolutePath;
        if (zipFilePath) {
            // Extract file from zip to temporary location
            const ext = mime.getExtension(contentType) || path.extname(filePath) || '';
            const tempFileName = `temp_${randomUUID()}${ext ? `.${ext}` : ''}`;
            tempFilePath = path.join(tmpdir(), tempFileName);
            
            const stream = await extractFileFromZipRecursive(zipFilePath, filePath);
            await writeStreamToFile(stream, tempFilePath);
            actualFilePath = tempFilePath;
        }
        
        try {
            const assetInfo = await getFileInfo(actualFilePath, contentType);        
            if (assetInfo) {
                fileAnalysis.assetInfo = assetInfo;
            }
        } 
        catch (error) {
            fileAnalysis.error = `Failed to analyze file: ${error}`;
        }
    } finally {
        // Clean up temporary file if created
        if (tempFilePath) {
            try {
                await fs.unlink(tempFilePath);
            } catch (err) {
                // Ignore cleanup errors
            }
        }
    }

    return fileAnalysis;
}

function displayFileInfo(analysis: FileAnalysis, options: IInfoCommandOptions) {
    const { path, fileStat: fileInfo, assetInfo, hash, error } = analysis;
    
    console.log(pc.bold(pc.blue(`📁 ${path}`)));
    
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
