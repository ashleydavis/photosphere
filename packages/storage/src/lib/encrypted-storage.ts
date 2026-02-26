import { Readable } from "stream";
import { IFileInfo, IListResult, IStorage, IWriteLockInfo } from "./storage";
import { KeyObject } from "node:crypto";
import { decryptBuffer, encryptBuffer } from "./encrypt-buffer";
import { createDecryptionStream, createEncryptionStream } from "./encrypt-stream";
import type { IPrivateKeyMap } from "./encryption-types";

//
// A type of storage that wraps another storage and encrypts it.
//
export class EncryptedStorage implements IStorage {

    private readonly decryptionKeyMap: IPrivateKeyMap;
    private readonly encryptionPublicKey: KeyObject;

    constructor(public readonly location: string, private storage: IStorage, decryptionKeyMap: IPrivateKeyMap, encryptionPublicKey: KeyObject) {
        this.decryptionKeyMap = decryptionKeyMap;
        this.encryptionPublicKey = encryptionPublicKey;
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
        const data = await this.storage.read(filePath);
        if (!data) {
            return undefined;
        }

        return decryptBuffer(data, this.decryptionKeyMap);
    }

    //
    // Writes a file to storage.
    //
    async write(filePath: string, contentType: string | undefined, data: Buffer): Promise<void> {               
        await this.storage.write(filePath, contentType, await encryptBuffer(this.encryptionPublicKey, data));
    }

    //
    // Streams a file from stroage.
    //
    readStream(filePath: string): Readable {
        const decryptionStream = createDecryptionStream(this.decryptionKeyMap);
        const readStream = this.storage.readStream(filePath);
        readStream.pipe(decryptionStream);
        return decryptionStream;
    }

    //
    // Writes an input stream to storage.
    //
    async writeStream(filePath: string, contentType: string | undefined, inputStream: Readable, contentLength?: number): Promise<void> {
        const encryptionStream = createEncryptionStream(this.encryptionPublicKey);
        inputStream.pipe(encryptionStream);
        await this.storage.writeStream(filePath, contentType, encryptionStream, contentLength);
    }

    //
    // Deletes a file from storage.
    //
    async deleteFile(filePath: string): Promise<void> {
        return this.storage.deleteFile(filePath);
    }

    //
    // Deletes a directory from storage.
    //
    async deleteDir(dirPath: string): Promise<void> {
        return this.storage.deleteDir(dirPath);
    }

    //
    // Copies a file from one location to another.
    //
    copyTo(srcPath: string, destPath: string): Promise<void> {
        return this.storage.copyTo(srcPath, destPath);
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