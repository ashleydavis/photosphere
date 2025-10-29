//
// An implementation of storage that operates under a particular prefix.
//

import { IFileInfo, IListResult, IStorage, IWriteLockInfo } from "./storage";
import { pathJoin } from "./storage-factory";

export class StoragePrefixWrapper implements IStorage {

    constructor(private storage: IStorage, private prefix: string) {
        if (prefix === "") {
            throw new Error("Prefix must not be empty.");            
        }
    }

    get location(): string {
        return pathJoin(this.storage.location, this.prefix);
    }

    //
    // Make a full path using the prefix.
    //
    private makeFullPath(path: string): string {
        if (this.prefix.endsWith(":")) {
            return this.prefix + path
        }
        else {
            return pathJoin(this.prefix, path);
        }
    }

    //
    // Returns true if the specified directory is empty.
    //
    isEmpty(path: string): Promise<boolean> {
        return this.storage.isEmpty(this.makeFullPath(path));
    }

    //
    // List files in storage.
    //
    listFiles(path: string, max: number, next?: string): Promise<IListResult> {
        return this.storage.listFiles(this.makeFullPath(path), max, next);
    }

    //
    // List directories in storage.
    //
    listDirs(path: string, max: number, next?: string): Promise<IListResult> {
        return this.storage.listDirs(this.makeFullPath(path), max, next);
    }

    //
    // Returns true if the specified file exists.
    //
    fileExists(filePath: string): Promise<boolean> {
        return this.storage.fileExists(this.makeFullPath(filePath));
    }

    //
    // Returns true if the specified directory exists (contains at least one file or subdirectory).
    //
    dirExists(dirPath: string): Promise<boolean> {
        return this.storage.dirExists(this.makeFullPath(dirPath));
    }

    //
    // Gets info about a file.
    //
    info(filePath: string): Promise<IFileInfo | undefined> {
        return this.storage.info(this.makeFullPath(filePath));
    }

    //
    // Reads a file from storage.
    // Returns undefined if the file doesn't exist.
    //
    read(filePath: string): Promise<Buffer | undefined> {
        return this.storage.read(this.makeFullPath(filePath));
    }

    //
    // Writes a file to storage.
    //
    write(filePath: string, contentType: string | undefined, data: Buffer): Promise<void> {
        return this.storage.write(this.makeFullPath(filePath), contentType, data);
    }

    //
    // Streams a file from stroage.
    //
    readStream(filePath: string): NodeJS.ReadableStream {
        return this.storage.readStream(this.makeFullPath(filePath));
    }

    //
    // Writes an input stream to storage.
    //
    writeStream(filePath: string, contentType: string | undefined, inputStream: NodeJS.ReadableStream, contentLength?: number): Promise<void> {
        return this.storage.writeStream(this.makeFullPath(filePath), contentType, inputStream, contentLength);
    }

    //
    // Deletes the file from storage.
    //
    deleteFile(filePath: string): Promise<void> {
        return this.storage.deleteFile(this.makeFullPath(filePath));
    }

    //
    // Deletes the directory from storage.
    //
    deleteDir(filePath: string): Promise<void> {
        return this.storage.deleteDir(this.makeFullPath(filePath));
    }

    //
    // Copies a file from one location to another.
    //
    copyTo(srcPath: string, destPath: string): Promise<void> {        
        return this.storage.copyTo(this.makeFullPath(srcPath), this.makeFullPath(destPath));
    }

    //
    // Checks if a write lock is acquired for the specified file.
    // Returns the lock information if it exists, undefined otherwise.
    //
    checkWriteLock(filePath: string): Promise<IWriteLockInfo | undefined> {
        return this.storage.checkWriteLock(this.makeFullPath(filePath));
    }

    //
    // Attempts to acquire a write lock for the specified file.
    // Returns true if the lock was acquired, false if it already exists.
    //
    acquireWriteLock(filePath: string, owner: string): Promise<boolean> {
        return this.storage.acquireWriteLock(this.makeFullPath(filePath), owner);
    }

    //
    // Releases a write lock for the specified file.
    //
    releaseWriteLock(filePath: string): Promise<void> {
        return this.storage.releaseWriteLock(this.makeFullPath(filePath));
    }

    //
    // Refreshes a write lock for the specified file, updating its timestamp.
    //
    refreshWriteLock(filePath: string, owner: string): Promise<void> {
        return this.storage.refreshWriteLock(this.makeFullPath(filePath), owner);
    }
}