import { Readable } from "stream";
import { IFileInfo, IListResult, IStorage } from "storage";
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
        const info = await this.storage.info(filePath);
        if (!info) {
            throw new Error(`Failed to get info for file "${filePath}"`);
        }
        const hash = await computeHash(this.storage.readStream(filePath));
        this.assetDatabase.addFile(filePath, {
            hash,
            contentType: info.contentType,
            lastModified: info.lastModified,
            length: info.length,
        });

        console.log(`Updated the merkle tree for file "${filePath}"`);
    }

    get location(): string {
        return this.storage.location;
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
        await this.updateMerkleTree(filePath);
    }

    //
    // Streams a file from stroage.
    //
    readStream(filePath: string): Readable {
        return this.storage.readStream(filePath);
    }

    //
    // Writes an input stream to storage.
    //
    async writeStream(filePath: string, contentType: string | undefined, inputStream: Readable, contentLength?: number): Promise<void> {        
        await this.storage.writeStream(filePath, contentType, inputStream, contentLength);
        await this.updateMerkleTree(filePath);
    }

    //
    // Deletes a file from storage.
    //
    async deleteFile(filePath: string): Promise<void> {
        await this.assetDatabase.deleteFile(filePath);
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

        //todo: update merkle tree.
    }
}