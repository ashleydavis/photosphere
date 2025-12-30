import path from "path";
import mime from "mime";
import { log, IUuidGenerator } from "utils";
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
    tempDir: string; // Temporary directory for extracted files from this scanning session
}

//
// Progress callback for scanning operations.
//
export type ScanProgressCallback = (currentlyScanning: string | undefined, state: ScannerState) => void;

//
// Result of scanning a single file
//
export interface FileScannedResult {
    filePath: string; // Actual file path (temporary file path if extracted from zip, otherwise the original file path)
    fileStat: IFileStat;
    contentType: string;
    labels: string[];
    logicalPath: string; // Logical path showing root zip file, parent zip names, and file name (always set - equals filePath for non-zip files)
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
// Formats the full zip path for log messages, showing all parents in the stack
//
function formatZipDisplayPath(zipPathStack: string[]): string {
    return zipPathStack.join(' / ');
}

//
// Constructs a logical path showing root zip file, parent zip names, and file name
// zipPathStack should include the root zip file path as the first element, followed by nested zip names
//
export function constructLogicalPath(zipPathStack: string[], fileName: string): string {
    const logicalPathParts = [...zipPathStack, fileName];
    return logicalPathParts.join('/');
}

//
// Formats a truncated zip path for progress callbacks, showing only root and last nested zip
//
function formatZipProgressPath(zipPathStack: string[]): string {
    if (zipPathStack.length === 0) {
        throw new Error('zipPathStack cannot be empty');
    }
    
    const rootZipName = path.basename(zipPathStack[0]);
    const truncatedRoot = rootZipName.length > 50 
        ? rootZipName.substring(0, 50) 
        : rootZipName;
    
    if (zipPathStack.length === 1) {
        // Just the root zip
        return truncatedRoot;
    }
    else if (zipPathStack.length === 2) {
        // Root + 1 nested zip, no "..."
        const lastNestedZip = path.basename(zipPathStack[1]);
        return `${truncatedRoot} / ${lastNestedZip}`;
    }
    else {
        // More than two entries (root + at least 2 nested), show "..."
        const lastNestedZip = path.basename(zipPathStack[zipPathStack.length - 1]);
        return `${truncatedRoot} / ... / ${lastNestedZip}`;
    }
}

//
// Scans files from a zip file
// zipFilePath is always a valid zip file on disk (either root or extracted temp file)
// zipPathStack is an array representing the zip hierarchy, with the root zip path as the first element
//
async function scanZipFile(
    zipFilePath: string, 
    fileStat: IFileStat, 
    zipPathStack: string[],
    visitFile: SimpleFileCallback, 
    progressCallback: ScanProgressCallback | undefined,
    state: ScannerState,
    options: ScannerOptions,
    tempDir: string,
    uuidGenerator: IUuidGenerator
): Promise<void> {
    const displayPath = formatZipDisplayPath(zipPathStack);
    log.verbose(`Scanning zip file "${displayPath}" for media files.`);

    if (progressCallback) {
        const progressPath = formatZipProgressPath(zipPathStack);
        state.currentlyScanning = progressPath;
        progressCallback(state.currentlyScanning, state);
    }

    const zip = new JSZip();
    let zipBuffer: Buffer;
    try {
        zipBuffer = await fs.readFile(zipFilePath);
    }
    catch (error: any) {
        log.exception(`Failed to read zip file ${displayPath}`, error);
        state.numFilesFailed++;
        return;
    }

    let unpacked;
    try {
        unpacked = await zip.loadAsync(zipBuffer);
    } 
    catch (error: any) {
        log.exception(`Failed to load zip file ${displayPath}`, error);
        state.numFilesFailed++;
        return;
    }
    
    for (const [fileName, zipObject] of Object.entries(unpacked.files)) {
        if (!zipObject.dir) {
            const contentType = mime.getType(fileName);
            if (!contentType) {
                log.verbose(`Ignoring file ${fileName} in zip ${displayPath} with unknown content type.`);
                state.numFilesIgnored++;
                continue;
            } 

            if (!shouldIncludeFile(contentType)) {
                log.verbose(`Ignoring file ${fileName} in zip ${displayPath} with content type "${contentType}".`);
                state.numFilesIgnored++;
                continue;
            }
            
            const zipFileInfo: IFileStat = {
                contentType,
                length: 0, // We can't reliably get the uncompressed size from JSZip.
                lastModified: zipObject.date || fileStat.lastModified,
            };

            if (contentType === "application/zip") {
                // If it's a zip file, extract it to a temporary file, scan it, then delete it
                // Build the path stack for nested zips - add this zip name to the existing stack
                const nestedZipPathStack = zipPathStack.concat([fileName]);
                
                // Extract nested zip from this zip file to temp file
                let tempZipPath: string | undefined;
                try {
                    const nestedZipBuffer = await zipObject.async('nodebuffer');
                    tempZipPath = path.join(tempDir, `${uuidGenerator.generate()}.zip`);
                    log.verbose(`Extracting nested zip file "${fileName}" from ${displayPath} to temporary file "${tempZipPath}"`);
                    await fs.writeFile(tempZipPath, nestedZipBuffer);
                    
                    // Verify the file was written correctly
                    const zipStats = await fs.stat(tempZipPath);
                    if (zipStats.size === 0) {
                        log.error(`Extracted nested zip file "${fileName}" from ${displayPath} is empty (0 bytes), skipping`);
                        state.numFilesFailed++;
                        log.verbose(`Keeping temporary zip file "${tempZipPath}" for inspection due to error`);
                        continue;
                    }
                    
                    // Scan the extracted zip file
                    await scanZipFile(
                        tempZipPath,
                        zipFileInfo,
                        nestedZipPathStack, // Path stack including root zip and nested zips
                        visitFile, 
                        progressCallback,
                        state,
                        options,
                        tempDir,
                        uuidGenerator
                    );
                }
                catch (error) {
                    // Keep file for inspection on error
                    if (tempZipPath) {
                        log.verbose(`Keeping temporary zip file "${tempZipPath}" for inspection due to error`);
                    }
                    throw error;
                }
            }
            else {
                // Extract file from zip to temporary file
                let tempFilePath: string | undefined;
                try {
                    const fileBuffer = await zipObject.async('nodebuffer');
                    const fileExt = path.extname(fileName);
                    tempFilePath = path.join(tempDir, `${uuidGenerator.generate()}${fileExt}`);
                    log.verbose(`Extracting file "${fileName}" from zip ${displayPath} to temporary file "${tempFilePath}"`);
                    await fs.writeFile(tempFilePath, fileBuffer);
                    
                    // Verify the file was written correctly
                    const stats = await fs.stat(tempFilePath);
                    if (stats.size === 0) {
                        log.error(`Extracted file "${fileName}" from zip ${displayPath} is empty (0 bytes), skipping`);
                        state.numFilesFailed++;
                        log.verbose(`Keeping temporary file "${tempFilePath}" for inspection due to error`);
                        continue;
                    }

                    // Create file stat from the actual extracted file
                    const extractedFileInfo: IFileStat = {
                        contentType,
                        length: stats.size,
                        lastModified: stats.mtime,
                    };

                    await visitFile({
                        filePath: tempFilePath, // Temporary file path
                        fileStat: extractedFileInfo,
                        contentType,
                        labels: [],
                        logicalPath: constructLogicalPath(zipPathStack, fileName), // Logical path showing root zip, parent zips, and file name
                    });
                }
                catch (error) {
                    // Keep file for inspection on error
                    if (tempFilePath) {
                        log.verbose(`Keeping temporary file "${tempFilePath}" for inspection due to error`);
                    }
                    throw error;
                }
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
    options: ScannerOptions,
    tempDir: string,
    uuidGenerator: IUuidGenerator
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
            // Start the zip path stack with the root zip file path
            await scanZipFile(filePath, fileInfo, [filePath], visitFile, progressCallback, state, options, tempDir, uuidGenerator);
        } 
        else {
            // Otherwise, process the file directly.
            await visitFile({
                filePath,
                fileStat: fileInfo,
                contentType,
                labels: [],
                logicalPath: filePath, // For non-zip files, logicalPath equals filePath
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
    options: ScannerOptions,
    tempDir: string,
    uuidGenerator: IUuidGenerator
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
            // Start the zip path stack with the root zip file path
            await scanZipFile(
                filePath, 
                fileInfo,
                [filePath], // Zip path stack starting with root zip path
                visitFile, 
                progressCallback,
                state,
                options,
                tempDir,
                uuidGenerator
            );
        } 
        else {
            // Otherwise, process the file directly.
            await visitFile({
                filePath,
                fileStat: fileInfo,
                contentType,
                labels: [],
                logicalPath: filePath, // For non-zip files, logicalPath equals filePath
            });
        }
    } 
    else if (stats.isDirectory()) {
        await scanDirectory(filePath, visitFile, progressCallback, state, options, tempDir, uuidGenerator);
    }
}

//
// Scans a list of files or directories
//
export async function scanPaths(
    paths: string[], 
    visitFile: SimpleFileCallback, 
    progressCallback: ScanProgressCallback | undefined,
    options: ScannerOptions,
    sessionTempDir: string,
    uuidGenerator: IUuidGenerator
): Promise<void> {
    // Create a file-scanner subdirectory under the session temp directory
    const tempDir = path.join(sessionTempDir, 'file-scanner');
    await fs.mkdir(tempDir, { recursive: true });
    log.verbose(`Created temporary directory for file scanning: "${tempDir}"`);
    
    const state: ScannerState = {
        currentlyScanning: undefined,
        numFilesIgnored: 0,
        numFilesFailed: 0,
        tempDir,
    };
    
    for (const path of paths) {
        await scanPathInternal(path, visitFile, progressCallback, state, options, tempDir, uuidGenerator);
    }
}

//
// Convenience function to scan a single path
//
export async function scanPath(
    filePath: string, 
    visitFile: SimpleFileCallback, 
    progressCallback: ScanProgressCallback | undefined,
    options: ScannerOptions,
    sessionTempDir: string,
    uuidGenerator: IUuidGenerator
): Promise<void> {
    // Create a file-scanner subdirectory under the session temp directory
    const tempDir = path.join(sessionTempDir, 'file-scanner');
    await fs.mkdir(tempDir, { recursive: true });
    log.verbose(`Created temporary directory for file scanning: "${tempDir}"`);
    
    const state: ScannerState = {
        currentlyScanning: undefined,
        numFilesIgnored: 0,
        numFilesFailed: 0,
        tempDir,
    };
    
    await scanPathInternal(filePath, visitFile, progressCallback, state, options, tempDir, uuidGenerator);
}