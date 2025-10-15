import { IFileInfo, IListResult, IStorage, IWriteLockInfo } from "storage";
import { IAssetDatabase } from "./asset-database";
import { computeHash } from "./hash";

//
// A type of storage that updates the asset database merkle tree when files are added or removed.
//
export class AssetDatabaseStorage implements IStorage {

    constructor(private readonly storage: IStorage, private readonly assetDatabase: IAssetDatabase) {
    }

    //
    // Updates the merkle tree when a file is added or removed.
    //    
    private async updateMerkleTree(filePath: string): Promise<void> {
        if (this.storage.isReadonly) {
            // Skip merkle tree updates in readonly mode
            return;
        }
        
        const info = await this.storage.info(filePath);
        if (!info) {
            throw new Error(`Failed to get info for file "${filePath}"`);
        }
        const hash = await computeHash(this.storage.readStream(filePath));
        const hashedFile = {
            hash,
            lastModified: info.lastModified,
            length: info.length,
        };
        this.assetDatabase.addFile(filePath, hashedFile);

        // console.log(`Updated the merkle tree for file "${filePath}"`);
    }

    get location(): string {
        return this.storage.location;
    }

    get isReadonly(): boolean {
        return this.storage.isReadonly;
    }

    //
    // Returns true if the specified directory is empty.
    //
    isEmpty(path: string): Promise<boolean> {
        return this.storage.isEmpty(path);
    }        

    //
    // List files in storage.
    //
    listFiles(path: string, max: number, next?: string): Promise<IListResult> {
        return this.storage.listFiles(path, max, next);
    }

    //
    // List directories in storage.
    //
    listDirs(path: string, max: number, next?: string): Promise<IListResult> {
        return this.storage.listDirs(path, max, next);
    }

    //
    // Returns true if the specified file exists.
    //
    fileExists(filePath: string): Promise<boolean> {
        return this.storage.fileExists(filePath);
    }

    //
    // Returns true if the specified directory exists (contains at least one file or subdirectory).
    //
    dirExists(dirPath: string): Promise<boolean> {
        return this.storage.dirExists(dirPath);
    }

    //
    // Gets info about a file.
    //
    info(filePath: string): Promise<IFileInfo | undefined> {
        return this.storage.info(filePath);
    }

    //
    // Reads a file from storage.
    // Returns undefined if the file doesn't exist.
    //
    async read(filePath: string): Promise<Buffer | undefined> {
        return await this.storage.read(filePath);
    }

    //
    // Writes a file to storage.
    //
    async write(filePath: string, contentType: string | undefined, data: Buffer): Promise<void> {           
        await this.storage.write(filePath, contentType, data);
        if (filePath.startsWith('metadata/')) {
            return; // Skip metadata files
        }

        await this.updateMerkleTree(filePath);
    }

    //
    // Streams a file from stroage.
    //
    readStream(filePath: string): NodeJS.ReadableStream {
        return this.storage.readStream(filePath);
    }

    //
    // Writes an input stream to storage.
    //
    async writeStream(filePath: string, contentType: string | undefined, inputStream: NodeJS.ReadableStream, contentLength?: number): Promise<void> {
        await this.storage.writeStream(filePath, contentType, inputStream, contentLength);
        if (filePath.startsWith('metadata/')) {
            return; // Skip metadata files
        }

        await this.updateMerkleTree(filePath);
    }

    //
    // Deletes a file from storage.
    //
    async deleteFile(filePath: string): Promise<void> {
        this.assetDatabase.deleteFile(filePath);
        await this.storage.deleteFile(filePath);
    }

    //
    // Deletes a directory from storage.
    //
    async deleteDir(dirPath: string): Promise<void> {
        await this.assetDatabase.deleteDir(dirPath);
        await this.storage.deleteDir(dirPath);
    }

    //
    // Copies a file from one location to another.
    //
    async copyTo(srcPath: string, destPath: string): Promise<void> {
        await this.storage.copyTo(srcPath, destPath);
        if (destPath.startsWith('metadata/')) {
            return; // Skip metadata files
        }
        
        await this.updateMerkleTree(destPath); //TODO: This won't work unless dest path is relative to this storage.
    }

    //
    // Checks if a write lock is acquired for the specified file.
    // Returns the lock information if it exists, undefined otherwise.
    //
    checkWriteLock(filePath: string): Promise<IWriteLockInfo | undefined> {
        return this.storage.checkWriteLock(filePath);
    }

    //
    // Attempts to acquire a write lock for the specified file.
    // Returns true if the lock was acquired, false if it already exists.
    //
    acquireWriteLock(filePath: string, owner: string): Promise<boolean> {
        return this.storage.acquireWriteLock(filePath, owner);
    }

    //
    // Releases a write lock for the specified file.
    //
    releaseWriteLock(filePath: string): Promise<void> {
        return this.storage.releaseWriteLock(filePath);
    }

    //
    // Refreshes a write lock for the specified file, updating its timestamp.
    //
    refreshWriteLock(filePath: string, owner: string): Promise<void> {
        return this.storage.refreshWriteLock(filePath, owner);
    }
}