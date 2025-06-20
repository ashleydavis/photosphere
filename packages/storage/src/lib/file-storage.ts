import * as fs from "fs-extra";
import * as path from "path";
import { Readable } from "stream";
import { IFileInfo, IListResult, IStorage } from "./storage";

export class FileStorage implements IStorage {

    constructor(public readonly location: string) {
    }

    //
    // Returns true if the specified directory is empty.
    //
    async isEmpty(path: string): Promise<boolean> {
        if (!await fs.pathExists(path)) {
            return true;
        }
        const entries = await fs.readdir(path);
        return entries.length === 0;
    }

    //
    // List files in storage.
    //
    async listFiles(path: string, max: number, next?: string): Promise<IListResult> {
        if (!await fs.pathExists(path)) {
            return {
                names: [],
                next: undefined,
            };
        }

        let entries = await fs.readdir(path, { withFileTypes: true });
        entries = entries.filter(entry => !entry.isDirectory());

        //
        // Alphanumeric sort to simulate the order of file listing from S3.
        // This allows the files to be listed in the same order as they would be listed in S3.
        // This is important for building the hash tree as the order of files affects the hash tree.
        //
        entries.sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));

        return {
            names: entries.map(entry => entry.name),
            next: undefined,
        };
    }

    //
    // List files in storage.
    //
    async listDirs(path: string, max: number, next?: string): Promise<IListResult> {
        if (!await fs.pathExists(path)) {
            return {
                names: [],
                next: undefined,
            };
        }

        let entries = await fs.readdir(path, { withFileTypes: true });
        entries = entries.filter(entry => entry.isDirectory());

        //
        // Alphanumeric sort to simulate the order of file listing from S3.
        // This allows the files to be listed in the same order as they would be listed in S3.
        // This is important for building the hash tree as the order of files affects the hash tree.
        //
        entries.sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));

        return {
            names: entries.map(entry => entry.name),
            next: undefined,
        };
    }

    //
    // Returns true if the specified file exists.
    //
    async fileExists(filePath: string): Promise<boolean> {
        if (!await fs.pathExists(filePath)) {
            return false;
        }
        
        // Ensure it's a file, not a directory
        const stats = await fs.stat(filePath);
        return stats.isFile();
    }
    
    //
    // Returns true if the specified directory exists.
    //
    async dirExists(dirPath: string): Promise<boolean> {
        if (!await fs.pathExists(dirPath)) {
            return false;
        }
        
        // Ensure it's a directory
        const stats = await fs.stat(dirPath);
        return stats.isDirectory();
    }
    
    //
    // Gets info about a file.
    //
    async info(filePath: string): Promise<IFileInfo | undefined> {
        if (!await fs.pathExists(filePath)) {
            return undefined;
        }
        const stat = await fs.stat(filePath);
        if (!stat.isFile()) {
            // If it's not a file, return undefined.
            return undefined;
        }
        return {
            contentType: undefined, // This is not available in file storage.
            length: stat.size,
            lastModified: stat.mtime,
        };
    }

    //
    // Reads a file from storage.
    // Returns undefined if the file doesn't exist.
    //
    async read(filePath: string): Promise<Buffer | undefined> {
        if (!await fs.pathExists(filePath)) {
            // Returns undefined if the file doesn't exist.
            return undefined;
        }

        return await fs.readFile(filePath);
    }

    //
    // Writes a file to storage.
    //
    async write(filePath: string, contentType: string | undefined, data: Buffer): Promise<void> {
        await fs.ensureDir(path.dirname(filePath));
        await fs.writeFile(filePath, data);
    }

    //
    // Streams a file from stroage.
    //
    readStream(filePath: string): Readable {
        return fs.createReadStream(filePath);
    }

    //
    // Writes an input stream to storage.
    //
    writeStream(filePath: string, contentType: string | undefined, inputStream: Readable): Promise<void> {
        return new Promise<void>((resolve, reject) => {
            fs.ensureDir(path.dirname(filePath))
                .then(() => {
                    const fileWriteStream = fs.createWriteStream(filePath);
                    inputStream.pipe(fileWriteStream)
                        .on("error", (err: any) => {
                            reject(err);
                        })
                        .on("finish", () => {
                            resolve();
                        });
                })
                .catch((err) => {
                    reject(err);
                });
        });
    }

    //
    // Deletes a file from storage.
    //
    async deleteFile(filePath: string): Promise<void> {
        try {
            await fs.unlink(filePath);
        } catch (err) {
            // Ignore errors if the file doesn't exist
        }
    }
    
    //
    // Deletes a directory and all its contents from storage.
    //
    async deleteDir(dirPath: string): Promise<void> {
        try {
            await fs.rm(dirPath, { recursive: true, force: true });
        } catch (err) {
            // Ignore errors if the directory doesn't exist
        }
    }

    //
    // Copies a file from one location to another.
    // Src file path is a full path, dest path is relative to the storage root.
    //
    async copyTo(srcPath: string, destPath: string): Promise<void> {
        await fs.ensureDir(path.dirname(destPath));
        await fs.copy(srcPath, destPath);
    }

}
