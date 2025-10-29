import * as fs from "fs-extra";
import * as path from "path";
import { Readable } from "stream";
import { IFileInfo, IListResult, IStorage, IWriteLockInfo } from "./storage";
import { log } from "utils";

// Write lock timeout in milliseconds (10 seconds)
const WRITE_LOCK_TIMEOUT_MS = 10000;

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

    //
    // Checks if a write lock is acquired for the specified file.
    // Returns the lock information if it exists, undefined otherwise.
    //
    async checkWriteLock(filePath: string): Promise<IWriteLockInfo | undefined> {
        try {
            if (await fs.pathExists(filePath)) {
                const lockContent = await fs.readFile(filePath, 'utf8');
                const lockData = JSON.parse(lockContent.trim());
                return {
                    owner: lockData.owner,
                    acquiredAt: new Date(lockData.acquiredAt),
                    timestamp: lockData.timestamp
                };
            }
            return undefined;
        } catch (err) {
            return undefined;
        }
    }

    //
    // Attempts to acquire a write lock for the specified file.
    // Returns true if the lock was acquired, false if it already exists.
    //
    async acquireWriteLock(filePath: string, owner: string): Promise<boolean> {
        
        const timestamp = Date.now();
        const processId = process.pid;
        
        if (log.verboseEnabled) {
            log.verbose(`[LOCK] ${timestamp},ACQUIRE_ATTEMPT,${processId},${owner},${filePath}`);
        }
        
        try {
            // Check if lock already exists
            if (await fs.pathExists(filePath)) {
                // Check if existing lock has timed out (10 seconds = 10000ms)
                const existingLock = await this.checkWriteLock(filePath);
                if (existingLock) {
                    const lockAge = timestamp - existingLock.timestamp;
                    if (lockAge > WRITE_LOCK_TIMEOUT_MS) {
                        // Lock has timed out, remove it and proceed to acquire new lock
                        if (log.verboseEnabled) {
                            log.verbose(`[LOCK] ${timestamp},ACQUIRE_TIMEOUT_BREAK,${processId},${owner},${filePath},age:${lockAge}ms,oldOwner:${existingLock.owner}`);
                        }
                        await fs.remove(filePath);
                    } else {
                        // Lock is still valid
                        if (log.verboseEnabled) {
                            log.verbose(`[LOCK] ${timestamp},ACQUIRE_FAILED_EXISTS,${processId},${owner},${filePath},age:${lockAge}ms,owner:${existingLock.owner}`);
                        }
                        return false;
                    }
                } else {
                    // Corrupted lock file, remove it
                    if (log.verboseEnabled) {
                        log.verbose(`[LOCK] ${timestamp},ACQUIRE_CORRUPTED_BREAK,${processId},${owner},${filePath}`);
                    }
                    await fs.remove(filePath);
                }
            }
            
            // Ensure directory exists
            await fs.ensureDir(path.dirname(filePath));
            
            // Create lock file with owner and timestamp information
            const lockInfo = {
                owner,
                acquiredAt: new Date().toISOString(),
                timestamp
            };
            await fs.writeFile(filePath, JSON.stringify(lockInfo), { flag: 'wx' }); // 'wx' flag fails if file exists
            
            if (log.verboseEnabled) {
                log.verbose(`[LOCK] ${timestamp},ACQUIRE_SUCCESS,${processId},${owner},${filePath}`);
            }
            return true;
        } catch (err: any) {
            // If file already exists (EEXIST), return false
            if (err.code === 'EEXIST') {
                if (log.verboseEnabled) {
                    log.verbose(`[LOCK] ${timestamp},ACQUIRE_FAILED_RACE,${processId},${owner},${filePath}`);
                }
                return false;
            }
            if (log.verboseEnabled) {
                log.verbose(`[LOCK] ${timestamp},ACQUIRE_FAILED_ERROR,${processId},${owner},${filePath},error:${err.message}`);
            }
            throw err;
        }
    }

    //
    // Releases a write lock for the specified file.
    //
    async releaseWriteLock(filePath: string): Promise<void> {
        
        if (log.verboseEnabled) {
            log.verbose(`[LOCK] ${Date.now()},RELEASE_SUCCESS,${process.pid},unknown,${filePath}`);
        }
        
        try {
            await fs.unlink(filePath);
        } catch (err) {
            // Ignore errors if the lock file doesn't exist
        }
    }

    //
    // Refreshes a write lock for the specified file, updating its timestamp.
    // Throws an error if the lock is no longer owned by the specified owner.
    //
    async refreshWriteLock(filePath: string, owner: string): Promise<void> {
        
        const timestamp = Date.now();
        const processId = process.pid;
        
        if (log.verboseEnabled) {
            log.verbose(`[LOCK] ${timestamp},REFRESH_ATTEMPT,${processId},${owner},${filePath}`);
        }
        
        try {
            // Check if lock exists and we own it
            const existingLock = await this.checkWriteLock(filePath);
            if (!existingLock) {
                throw new Error(`Cannot refresh write lock: lock does not exist for ${filePath}`);
            }
            
            if (existingLock.owner !== owner) {
                throw new Error(`Cannot refresh write lock: lock is owned by ${existingLock.owner}, not ${owner} for ${filePath}`);
            }
            
            // Update the lock with new timestamp
            const lockInfo = {
                owner,
                acquiredAt: new Date().toISOString(),
                timestamp
            };
            await fs.writeFile(filePath, JSON.stringify(lockInfo));
            
            if (log.verboseEnabled) {
                log.verbose(`[LOCK] ${timestamp},REFRESH_SUCCESS,${processId},${owner},${filePath}`);
            }
        } catch (err: any) {
            if (log.verboseEnabled) {
                log.verbose(`[LOCK] ${timestamp},REFRESH_FAILED,${processId},${owner},${filePath},error:${err.message}`);
            }
            throw err;
        }
    }

}
