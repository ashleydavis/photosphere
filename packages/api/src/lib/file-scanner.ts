import fs from "fs";
import fsPromises from "fs/promises";
import path from "path";
import { BsonDatabase, FileStorage, IBsonCollection, IFileInfo, IStorage, StoragePrefixWrapper, walkDirectory } from "storage";
import mime from "mime";
import { ILog, log } from "utils";
import { Readable } from "stream";
import JSZip from "jszip";
import { buffer } from "node:stream/consumers";

//
// Progress callback for scanning operations.
//
export type ScanProgressCallback = (currentlyScanning: string | undefined) => void;

//
// Callback for visiting a file when scanning a directory or zip file.
//
export type VisitFileCallback = (filePath: string, fileInfo: IFileInfo, fileDate: Date, contentType: string, labels: string[], openStream: (() => Readable) | undefined, progressCallback: ScanProgressCallback) => Promise<void>;

//
// Result of scanning a single file
//
export interface FileScannedResult {
    filePath: string;
    fileInfo: IFileInfo;
    fileDate: Date;
    contentType: string;
    labels: string[];
    openStream?: () => Readable;
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
    
    //
    // Whether to include zip files for scanning (default: true)
    //
    includeZipFiles?: boolean;
    
    //
    // Whether to include image files (default: true)
    //
    includeImages?: boolean;
    
    //
    // Whether to include video files (default: true)
    //
    includeVideos?: boolean;
}

//
// File scanner class that can scan files and directories without requiring a database
//
export class FileScanner {
    private currentlyScanning: string | undefined;
    private options: Required<ScannerOptions>;

    constructor(options: ScannerOptions = {}) {
        this.options = {
            ignorePatterns: options.ignorePatterns || [/\.db/],
            includeZipFiles: options.includeZipFiles ?? true,
            includeImages: options.includeImages ?? true,
            includeVideos: options.includeVideos ?? true
        };
    }

    //
    // Scans a list of files or directories
    //
    async scanPaths(paths: string[], visitFile: SimpleFileCallback, progressCallback?: ScanProgressCallback): Promise<void> {
        for (const path of paths) {
            await this.scanPath(path, visitFile, progressCallback);
        }
    }

    //
    // Scans a single file or directory
    //
    async scanPath(filePath: string, visitFile: SimpleFileCallback, progressCallback?: ScanProgressCallback): Promise<void> {
        const fileStat = await fsPromises.stat(filePath);
        
        if (fileStat.isFile()) {
            const contentType = mime.getType(filePath) || undefined;
            if (!contentType) {
                log.verbose(`Ignoring file "${filePath}" with unknown content type.`);
                return;
            }
            
            if (this.shouldIncludeFile(contentType)) {
                const fileInfo: IFileInfo = {
                    contentType,
                    length: fileStat.size,
                    lastModified: fileStat.mtime,
                };
                
                await visitFile({
                    filePath,
                    fileInfo,
                    fileDate: fileStat.birthtime,
                    contentType,
                    labels: [],
                    // Don't provide openStream for regular files - they can be read directly
                });
            } else {
                log.verbose(`Ignoring file "${filePath}" with content type "${contentType}".`);
            }
        } else if (fileStat.isDirectory()) {
            await this.scanDirectory(filePath, visitFile, progressCallback);
        } else {
            throw new Error(`Unsupported file type: ${filePath}`);
        }
    }

    //
    // Scans a directory for files
    //
    private async scanDirectory(directoryPath: string, visitFile: SimpleFileCallback, progressCallback?: ScanProgressCallback): Promise<void> {
        log.verbose(`Scanning directory "${directoryPath}" for media files.`);

        this.currentlyScanning = path.basename(directoryPath);
        if (progressCallback) {
            progressCallback(this.currentlyScanning);
        }

        for await (const orderedFile of walkDirectory(new FileStorage("fs:"), directoryPath, this.options.ignorePatterns)) {
            this.currentlyScanning = path.basename(path.dirname(orderedFile.fileName));
            if (progressCallback) {
                progressCallback(this.currentlyScanning);
            }

            const contentType = mime.getType(orderedFile.fileName);
            const filePath = orderedFile.fileName;
            if (!contentType) {
                log.verbose(`Ignoring file "${filePath}" with unknown content type.`);
                continue;
            }

            if (this.shouldIncludeFile(contentType)) {
                const fileStat = await fsPromises.stat(filePath);
                
                const fileInfo: IFileInfo = {
                    contentType,
                    length: fileStat.size,
                    lastModified: fileStat.mtime,
                };

                if (contentType === "application/zip" && this.options.includeZipFiles) {
                    await this.scanZipFile(filePath, fileInfo, fileStat.birthtime, () => fs.createReadStream(filePath), visitFile, progressCallback);
                } else {
                    await visitFile({
                        filePath,
                        fileInfo,
                        fileDate: fileStat.birthtime,
                        contentType,
                        labels: [],
                        // Don't provide openStream for regular files - they can be read directly
                    });
                }
            } else {
                log.verbose(`Ignoring file "${filePath}" with content type "${contentType}".`);
            }
        }

        log.verbose(`Finished scanning directory "${directoryPath}" for media files.`);
    }

    //
    // Scans files from a zip file
    //
    private async scanZipFile(filePath: string, fileInfo: IFileInfo, fileDate: Date, openStream: () => Readable, visitFile: SimpleFileCallback, progressCallback?: ScanProgressCallback): Promise<void> {
        log.verbose(`Scanning zip file "${filePath}" for media files.`);

        this.currentlyScanning = path.basename(filePath);
        if (progressCallback) {
            progressCallback(this.currentlyScanning);
        }

        const zip = new JSZip();
        const unpacked = await zip.loadAsync(await buffer(openStream()));
        
        for (const [fileName, zipObject] of Object.entries(unpacked.files)) {
            if (!zipObject.dir) {
                const contentType = mime.getType(fileName);
                if (contentType && this.shouldIncludeFile(contentType)) {
                    const zipFileInfo: IFileInfo = {
                        contentType,
                        length: 0, // We can't reliably get the uncompressed size from JSZip
                        lastModified: zipObject.date || fileDate,
                    };

                    await visitFile({
                        filePath: path.join(filePath, fileName),
                        fileInfo: zipFileInfo,
                        fileDate: zipObject.date || fileDate,
                        contentType,
                        labels: [],
                        // Provide openStream for zip files since they need to be extracted
                        openStream: () => {
                            const stream = new Readable();
                            zipObject.async('nodebuffer').then(data => {
                                stream.push(data);
                                stream.push(null);
                            }).catch(err => stream.emit('error', err));
                            return stream;
                        }
                    });
                }
            }
        }
    }

    //
    // Determines if a file should be included based on its content type
    //
    private shouldIncludeFile(contentType: string): boolean {
        if (contentType === "application/zip") {
            return this.options.includeZipFiles;
        }
        
        if (contentType.startsWith("image/")) {
            return this.options.includeImages;
        }
        
        if (contentType.startsWith("video/")) {
            return this.options.includeVideos;
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