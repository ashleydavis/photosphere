import path from "path";
import mime from "mime";
import { log } from "utils";
import JSZip from "jszip";
import { buffer } from "node:stream/consumers";
import fs from "fs-extra";

//
// File statistics interface
//
export interface IFileStat {
    contentType?: string;
    length: number;
    lastModified: Date;
}

//
// Progress callback for scanning operations.
//
export type ScanProgressCallback = (currentlyScanning: string | undefined) => void;

//
// Callback for visiting a file when scanning a directory or zip file.
//
export type VisitFileCallback = (filePath: string, fileInfo: IFileStat, fileDate: Date, contentType: string, labels: string[], zipFilePath: string | undefined, progressCallback: ScanProgressCallback) => Promise<void>;

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
// File scanner class that can scan files and directories without requiring a database
//
export class FileScanner {
    private currentlyScanning: string | undefined;
    private numFilesIgnored: number = 0;

    constructor(private readonly options?: ScannerOptions) {
    }

    //
    // Gets the number of files ignored during the last scan
    //
    getNumFilesIgnored(): number {
        return this.numFilesIgnored;
    }

    //
    // Gets the currently scanning path
    //
    getCurrentlyScanning(): string | undefined {
        return this.currentlyScanning;
    }

    //
    // Resets the ignored files counter
    //
    resetIgnoredCounter(): void {
        this.numFilesIgnored = 0;
    }

    //
    // Scans a list of files or directories
    //
    async scanPaths(paths: string[], visitFile: SimpleFileCallback, progressCallback?: ScanProgressCallback): Promise<void> {
        this.resetIgnoredCounter();
        for (const path of paths) {
            await this.scanPath(path, visitFile, progressCallback);
        }
    }

    //
    // Scans a single file or directory
    //
    async scanPath(filePath: string, visitFile: SimpleFileCallback, progressCallback?: ScanProgressCallback): Promise<void> {
        let stats;
        try {
            stats = await fs.stat(filePath);
        } catch (error) {
            log.verbose(`Path "${filePath}" does not exist: ${error instanceof Error ? error.message : String(error)}`);
            return;
        }

        if (stats.isFile()) {
            // It's a file
            const contentType = mime.getType(filePath) || undefined;
            if (!contentType) {
                log.verbose(`Ignoring file "${filePath}" with unknown content type.`);
                this.numFilesIgnored++;
                return;
            }
            
            const fileInfo: IFileStat = {
                contentType,
                length: stats.size,
                lastModified: stats.mtime,
            };

            if (this.shouldIncludeFile(contentType)) {
                if (contentType === "application/zip") {
                    // If it's a zip file, we need to scan its contents.
                    await this.scanZipFile(
                        filePath, 
                        fileInfo, 
                        undefined, // No parent zip
                        undefined, // No relative path in parent
                        visitFile, 
                        progressCallback
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
            else {
                log.verbose(`Ignoring file "${filePath}" with content type "${contentType}".`);
                this.numFilesIgnored++;
            }
        } else if (stats.isDirectory()) {
            await this.scanDirectory(filePath, visitFile, progressCallback);
        }
    }

    //
    // Scans a directory for files
    //
    private async scanDirectory(directoryPath: string, visitFile: SimpleFileCallback, progressCallback?: ScanProgressCallback): Promise<void> {
        log.verbose(`Scanning directory "${directoryPath}" for media files.`);

        if (progressCallback) {
            this.currentlyScanning = path.basename(directoryPath);
            progressCallback(this.currentlyScanning);
        }

        for await (const orderedFile of this.walkDirectory(directoryPath, this.options?.ignorePatterns)) {
            if (progressCallback) {
                this.currentlyScanning = path.basename(path.dirname(orderedFile.fileName));
                progressCallback(this.currentlyScanning);
            }

            const contentType = mime.getType(orderedFile.fileName);
            const filePath = orderedFile.fileName;
            if (!contentType) {
                log.verbose(`Ignoring file "${filePath}" with unknown content type.`);
                this.numFilesIgnored++;
                continue;
            }

            if (this.shouldIncludeFile(contentType)) {
                let stats;
                try {
                    stats = await fs.stat(filePath);
                } catch (error) {
                    log.verbose(`Could not get file info for "${filePath}", skipping: ${error instanceof Error ? error.message : String(error)}`);
                    this.numFilesIgnored++;
                    continue;
                }
                if (!stats.isFile()) {
                    log.verbose(`"${filePath}" is not a file, skipping.`);
                    this.numFilesIgnored++;
                    continue;
                }

                const fileInfo: IFileStat = {
                    contentType,
                    length: stats.size,
                    lastModified: stats.mtime,
                };

                if (contentType === "application/zip") {
                    // If it's a zip file, we need to scan its contents.
                    await this.scanZipFile(filePath, fileInfo, undefined, undefined, visitFile, progressCallback);
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
            else {
                log.verbose(`Ignoring file "${filePath}" with content type "${contentType}".`);
                this.numFilesIgnored++;
            }
        }

        log.verbose(`Finished scanning directory "${directoryPath}" for media files.`);
    }

    //
    // Walks a directory recursively and yields files in alphanumeric order
    //
    private async* walkDirectory(dirPath: string, ignorePatterns: RegExp[] = [/node_modules/, /\.git/, /\.DS_Store/]): AsyncGenerator<IOrderedFile> {
        if (!await fs.pathExists(dirPath)) {
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
            yield* this.walkDirectory(subDirPath, ignorePatterns);
        }
    }

    //
    // Scans files from a zip file
    //
    private async scanZipFile(zipFilePath: string, fileStat: IFileStat, parentZipFilePath: string | undefined, parentZipRelativePath: string | undefined, visitFile: SimpleFileCallback, progressCallback?: ScanProgressCallback): Promise<void> {
        const actualZipPath = parentZipFilePath ? parentZipFilePath : zipFilePath;
        log.verbose(`Scanning zip file "${actualZipPath}"${parentZipRelativePath ? ` (nested: ${parentZipRelativePath})` : ''} for media files.`);

        if (progressCallback) {
            this.currentlyScanning = path.basename(actualZipPath);
            progressCallback(this.currentlyScanning);
        }

        const zip = new JSZip();
        // If parentZipFilePath is provided, we're reading from a nested zip
        let zipStream: NodeJS.ReadableStream;
        if (parentZipFilePath && parentZipRelativePath) {
            zipStream = await this.extractZipFromParent(parentZipFilePath, parentZipRelativePath);
        } else {
            zipStream = fs.createReadStream(zipFilePath);
        }
        const unpacked = await zip.loadAsync(await buffer(zipStream));
        
        for (const [fileName, zipObject] of Object.entries(unpacked.files)) {
            if (!zipObject.dir) {
                const contentType = mime.getType(fileName);
                if (!contentType) {
                    log.verbose(`Ignoring file "${fileName}" in zip with unknown content type.`);
                    this.numFilesIgnored++;
                } else if (this.shouldIncludeFile(contentType)) {
                    const zipFileInfo: IFileStat = {
                        contentType,
                        length: 0, // We can't reliably get the uncompressed size from JSZip.
                        lastModified: zipObject.date || fileStat.lastModified,
                    };

                    if (contentType === "application/zip") {
                        // If it's a zip file, we need to scan its contents recursively.
                        // For nested zips, the actual zip file path is the top-level zip
                        const topLevelZipPath = parentZipFilePath || zipFilePath;
                        await this.scanZipFile(
                            topLevelZipPath, // Top-level zip file path
                            zipFileInfo, 
                            topLevelZipPath, // Parent zip is the top-level zip
                            fileName, // Relative path of nested zip within parent
                            visitFile, 
                            progressCallback
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
                else {
                    log.verbose(`Ignoring file "${fileName}" in zip with content type "${contentType}".`);
                    this.numFilesIgnored++;
                }
            }
        }
    }

    //
    // Extracts a nested zip file from a parent zip
    //
    private async extractZipFromParent(parentZipFilePath: string, nestedZipRelativePath: string): Promise<NodeJS.ReadableStream> {
        const parentZip = new JSZip();
        const parentStream = fs.createReadStream(parentZipFilePath);
        const unpacked = await parentZip.loadAsync(await buffer(parentStream));
        const nestedZipObject = unpacked.files[nestedZipRelativePath];
        if (!nestedZipObject || nestedZipObject.dir) {
            throw new Error(`Nested zip file "${nestedZipRelativePath}" not found in parent zip "${parentZipFilePath}"`);
        }
        return nestedZipObject.nodeStream();
    }

    //
    // Determines if a file should be included based on its content type
    //
    private shouldIncludeFile(contentType: string): boolean {
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
}

//
// Convenience function to scan paths with a simple callback
//
export async function scanPaths(
    paths: string[], 
    visitFile: SimpleFileCallback, 
    progressCallback?: ScanProgressCallback,
    options?: ScannerOptions
): Promise<void> {
    const scanner = new FileScanner(options);
    await scanner.scanPaths(paths, visitFile, progressCallback);
}

//
// Convenience function to scan a single path
//
export async function scanPath(
    filePath: string, 
    visitFile: SimpleFileCallback, 
    progressCallback?: ScanProgressCallback,
    options?: ScannerOptions
): Promise<void> {
    const scanner = new FileScanner(options);
    await scanner.scanPath(filePath, visitFile, progressCallback);
}