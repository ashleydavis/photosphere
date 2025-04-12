import { Readable } from "stream";
import { IFileInfo, IListResult, IStorage } from "./storage";
import { KeyObject } from "node:crypto";
import { decryptBuffer, encryptBuffer } from "./encrypt-buffer";
import { createDecryptionStream, createEncryptionStream } from "./encrypt-stream";


// A type of storage that wraps another storage and encrypts it.
//
export class EncryptedStorage implements IStorage {

    constructor(private storage: IStorage, private publicKey: KeyObject, private privateKey: KeyObject) { }

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

        return decryptBuffer(this.privateKey, data);
    }

    //
    // Writes a file to storage.
    //
    async write(filePath: string, contentType: string | undefined, data: Buffer): Promise<void> {               
        await this.storage.write(filePath, contentType, await encryptBuffer(this.publicKey, data));
    }

    //
    // Streams a file from stroage.
    //
    readStream(filePath: string): Readable {
        const decryptionStream = createDecryptionStream(this.privateKey);
        const readStream = this.storage.readStream(filePath)
        readStream.pipe(decryptionStream);
        return decryptionStream;
    }

    //
    // Writes an input stream to storage.
    //
    async writeStream(filePath: string, contentType: string | undefined, inputStream: Readable, contentLength?: number): Promise<void> {
        const encryptionStream = createEncryptionStream(this.publicKey);
        inputStream.pipe(encryptionStream);
        await this.storage.writeStream(filePath, contentType, encryptionStream, contentLength);
    }

    //
    // Deletes the file from storage.
    //
    async deleteFile(filePath: string): Promise<void> {
        return this.storage.deleteFile(filePath);
    }

    //
    // Deletes the directory from storage.
    //
    async deleteDir(filePath: string): Promise<void> {
        return this.storage.deleteDir(filePath);
    }

    //
    // Copies a file from one location to another.
    //
    copyTo(srcPath: string, destPath: string): Promise<void> {
        //TODO: This might have to decrypt and recrypt the file.
        return this.storage.copyTo(srcPath, destPath);
    }
}