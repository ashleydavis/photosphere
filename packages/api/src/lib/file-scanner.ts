import path from "path";
import mime from "mime";
import { log } from "utils";
import JSZip from "jszip";
import * as fs from "fs/promises";
import { pathExists } from "node-utils";

//
// File statistics interface
//
export interface IFileStat {
    contentType?: string;
    length: number;
    lastModified: Date;
}

//
// Scanner state that is passed through scanning operations
//
export interface ScannerState {
    currentlyScanning: string | undefined;
    numFilesIgnored: number;
    numFilesFailed: number;
}

//
// Progress callback for scanning operations.
//
export type ScanProgressCallback = (currentlyScanning: string | undefined, state: ScannerState) => void;

//
// Callback for visiting a file when scanning a directory or zip file.
//
export type VisitFileCallback = (filePath: string, fileInfo: IFileStat, fileDate: Date, contentType: string, labels: string[], zipFilePath: string | undefined, progressCallback: ScanProgressCallback, state: ScannerState) => Promise<void>;

//
// Result of scanning a single file
//
export interface FileScannedResult {
    filePath: string; // Relative path within zip if zipFilePath is present, otherwise the actual file path
    fileStat: IFileStat;
    contentType: string;
    labels: string[];
    zipFilePath?: string; // Path to the zip file containing this file, if present
}

//
// Simple callback for visiting each file found during scanning
//
export type SimpleFileCallback = (result: FileScannedResult) => Promise<void>;

//
// Scanner configuration options
//
export interface ScannerOptions {
    //
    // Patterns to ignore during scanning (default: [/\.db/])
    //
    ignorePatterns?: RegExp[];    
}

//
// Interface for ordered file results from directory walking
//
interface IOrderedFile {
    fileName: string;
}


//
// Determines if a file should be included based on its content type
//
function shouldIncludeFile(contentType: string): boolean {
    if (contentType === "video/mp2t") {
        // TypeScript files get detected as video/mp2t, but we don't want to include them.
        // So we don't support .ts video files. If someone wants to add support for .ts files, they can change this later.
        return false;
    }

    if (contentType === "image/vnd.fastbidsheet") {
        // .fbs files are not supported.
        return false;
    }

    if (contentType ===  "image/svg+xml") {
        // SVG files are not supported yet, so we ignore them.
        return false;
    }

    if (contentType === "application/zip") {
        return true;
    }

    if (contentType.startsWith("image/vnd.adobe.photoshop")) {
        // Don't yet know how to validate or process PSD files. This might come later.
        return false;
    }
    
    if (contentType.startsWith("image")) {
        return true;
    }
    
    if (contentType.startsWith("video")) {
        return true;
    }
    
    return false;
}

//
// Extracts a nested zip file from a parent zip
//
async function extractZipFromParent(parentZipFilePath: string, nestedZipRelativePath: string): Promise<Buffer> {
    const parentZip = new JSZip();
    const parentBuffer = await fs.readFile(parentZipFilePath);
    const unpacked = await parentZip.loadAsync(parentBuffer);
    const nestedZipObject = unpacked.files[nestedZipRelativePath];
    if (!nestedZipObject || nestedZipObject.dir) {
        throw new Error(`Nested zip file "${nestedZipRelativePath}" not found in parent zip "${parentZipFilePath}"`);
    }
    return await nestedZipObject.async('nodebuffer');
}

//
// Walks a directory recursively and yields files in alphanumeric order
//
async function* walkDirectory(dirPath: string, ignorePatterns: RegExp[] = [/node_modules/, /\.git/, /\.DS_Store/]): AsyncGenerator<IOrderedFile> {
    if (!await pathExists(dirPath)) {
        return;
    }

    const isIgnored = (name: string): boolean => {
        return ignorePatterns.some(pattern => pattern.test(name));
    };

    // Phase 1: List and yield all files in the current directory
    let entries = await fs.readdir(dirPath, { withFileTypes: true });
    let files = entries.filter(entry => entry.isFile() && !isIgnored(entry.name));
    
    // Alphanumeric sort to simulate the order of file listing from S3
    files.sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));

    for (const file of files) {
        const fileName = path.join(dirPath, file.name);
        yield { fileName };
    }

    // Phase 2: List all subdirectories and recursively walk each one
    let dirs = entries.filter(entry => entry.isDirectory() && !isIgnored(entry.name));
    
    // Alphanumeric sort for consistent ordering
    dirs.sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));

    for (const dir of dirs) {
        const subDirPath = path.join(dirPath, dir.name);
        yield* walkDirectory(subDirPath, ignorePatterns);
    }
}

//
// Scans files from a zip file
//
async function scanZipFile(
    zipFilePath: string, 
    fileStat: IFileStat, 
    parentZipFilePath: string | undefined, 
    parentZipRelativePath: string | undefined, 
    visitFile: SimpleFileCallback, 
    progressCallback: ScanProgressCallback | undefined,
    state: ScannerState,
    options: ScannerOptions
): Promise<void> {
    const actualZipPath = parentZipFilePath ? parentZipFilePath : zipFilePath;
    log.verbose(`Scanning zip file "${actualZipPath}"${parentZipRelativePath ? ` (nested: ${parentZipRelativePath})` : ''} for media files.`);

    if (progressCallback) {
        state.currentlyScanning = path.basename(actualZipPath);
        progressCallback(state.currentlyScanning, state);
    }

    const zip = new JSZip();
    // If parentZipFilePath is provided, we're reading from a nested zip
    let zipBuffer: Buffer;
    if (parentZipFilePath && parentZipRelativePath) {
        zipBuffer = await extractZipFromParent(parentZipFilePath, parentZipRelativePath);
    } 
    else {
        zipBuffer = await fs.readFile(zipFilePath);
    }

    let unpacked;
    try {
        unpacked = await zip.loadAsync(zipBuffer);
    } 
    catch (error: any) {
        log.exception(`Failed to load zip file ${actualZipPath}`, error);
        state.numFilesFailed++;
        return;
    }
    
    for (const [fileName, zipObject] of Object.entries(unpacked.files)) {
        if (!zipObject.dir) {
            const contentType = mime.getType(fileName);
            if (!contentType) {
                log.verbose(`Ignoring file ${fileName} in zip ${actualZipPath} with unknown content type.`);
                state.numFilesIgnored++;
                continue;
            } 

            if (!shouldIncludeFile(contentType)) {
                log.verbose(`Ignoring file ${fileName} in zip with ${actualZipPath} specific content type "${contentType}".`);
                state.numFilesIgnored++;
                continue;
            }
            
            const zipFileInfo: IFileStat = {
                contentType,
                length: 0, // We can't reliably get the uncompressed size from JSZip.
                lastModified: zipObject.date || fileStat.lastModified,
            };

            if (contentType === "application/zip") {
                // If it's a zip file, we need to scan its contents recursively.
                // For nested zips, the actual zip file path is the top-level zip
                const topLevelZipPath = parentZipFilePath || zipFilePath;
                await scanZipFile(
                    topLevelZipPath, // Top-level zip file path
                    zipFileInfo, 
                    topLevelZipPath, // Parent zip is the top-level zip
                    fileName, // Relative path of nested zip within parent
                    visitFile, 
                    progressCallback,
                    state,
                    options
                );
            }
            else {
                await visitFile({
                    filePath: fileName, // Relative path within zip
                    fileStat: zipFileInfo,
                    contentType,
                    labels: [],
                    zipFilePath: actualZipPath, // Actual filesystem path to the zip file containing this file
                });
            } 
        }
    }
}

//
// Scans a directory for files
//
async function scanDirectory(
    directoryPath: string, 
    visitFile: SimpleFileCallback, 
    progressCallback: ScanProgressCallback | undefined,
    state: ScannerState,
    options: ScannerOptions
): Promise<void> {
    log.verbose(`Scanning directory "${directoryPath}" for media files.`);

    if (progressCallback) {
        state.currentlyScanning = path.basename(directoryPath);
        progressCallback(state.currentlyScanning, state);
    }

    for await (const orderedFile of walkDirectory(directoryPath, options.ignorePatterns)) {
        if (progressCallback) {
            state.currentlyScanning = path.basename(path.dirname(orderedFile.fileName));
            progressCallback(state.currentlyScanning, state);
        }

        const contentType = mime.getType(orderedFile.fileName);
        const filePath = orderedFile.fileName;
        if (!contentType) {
            log.verbose(`Ignoring file "${filePath}" with unknown content type.`);
            state.numFilesIgnored++;
            continue;
        }

        if (!shouldIncludeFile(contentType)) {
            log.verbose(`Ignoring file "${filePath}" with specific content type "${contentType}".`);
            state.numFilesIgnored++;
            continue;
        }

        let stats;
        try {
            stats = await fs.stat(filePath);
        } 
        catch (error) {
            log.verbose(`Could not get file info for "${filePath}", skipping: ${error instanceof Error ? error.message : String(error)}`);
            state.numFilesIgnored++;
            continue;
        }

        if (!stats.isFile()) {
            log.verbose(`"${filePath}" is not a file, skipping.`);
            state.numFilesIgnored++;
            continue;
        }

        const fileInfo: IFileStat = {
            contentType,
            length: stats.size,
            lastModified: stats.mtime,
        };

        if (contentType === "application/zip") {
            // If it's a zip file, we need to scan its contents.
            await scanZipFile(filePath, fileInfo, undefined, undefined, visitFile, progressCallback, state, options);
        } 
        else {
            // Otherwise, process the file directly.
            await visitFile({
                filePath,
                fileStat: fileInfo,
                contentType,
                labels: [],
            });
        }
    }

    log.verbose(`Finished scanning directory "${directoryPath}" for media files.`);
}

//
// Scans a single file or directory (internal)
//
async function scanPathInternal(
    filePath: string, 
    visitFile: SimpleFileCallback, 
    progressCallback: ScanProgressCallback | undefined,
    state: ScannerState,
    options: ScannerOptions
): Promise<void> {
    let stats;
    try {
        stats = await fs.stat(filePath);
    } 
    catch (error) {
        log.verbose(`Path "${filePath}" does not exist: ${error instanceof Error ? error.message : String(error)}`);
        return;
    }

    if (stats.isFile()) {
        // It's a file
        const contentType = mime.getType(filePath) || undefined;
        if (!contentType) {
            log.verbose(`Ignoring file "${filePath}" with unknown content type.`);
            state.numFilesIgnored++;
            return;
        }

        if (!shouldIncludeFile(contentType)) {
            log.verbose(`Ignoring file "${filePath}" with specific content type "${contentType}".`);
            state.numFilesIgnored++;
            return;
        }
        
        const fileInfo: IFileStat = {
            contentType,
            length: stats.size,
            lastModified: stats.mtime,
        };

        if (contentType === "application/zip") {
            // If it's a zip file, we need to scan its contents.
            await scanZipFile(
                filePath, 
                fileInfo, 
                undefined, // No parent zip
                undefined, // No relative path in parent
                visitFile, 
                progressCallback,
                state,
                options
            );
        } 
        else {
            // Otherwise, process the file directly.
            await visitFile({
                filePath,
                fileStat: fileInfo,
                contentType,
                labels: [],
            });
        }
    } 
    else if (stats.isDirectory()) {
        await scanDirectory(filePath, visitFile, progressCallback, state, options);
    }
}

//
// Scans a list of files or directories
//
export async function scanPaths(
    paths: string[], 
    visitFile: SimpleFileCallback, 
    progressCallback: ScanProgressCallback | undefined,
    options: ScannerOptions
): Promise<void> {
    const state: ScannerState = {
        currentlyScanning: undefined,
        numFilesIgnored: 0,
        numFilesFailed: 0,
    };
    for (const path of paths) {
        await scanPathInternal(path, visitFile, progressCallback, state, options);
    }
}

//
// Convenience function to scan a single path
//
export async function scanPath(
    filePath: string, 
    visitFile: SimpleFileCallback, 
    progressCallback: ScanProgressCallback | undefined,
    options: ScannerOptions
): Promise<void> {
    const state: ScannerState = {
        currentlyScanning: undefined,
        numFilesIgnored: 0,
        numFilesFailed: 0,
    };
    await scanPathInternal(filePath, visitFile, progressCallback, state, options);
}