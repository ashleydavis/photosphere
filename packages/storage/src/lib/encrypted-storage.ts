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
    async list(path: string, max: number, next?: string): Promise<IListResult> {
        return this.storage.list(path, max, next);
    }

    //
    // Returns true if the specified file exists.
    //
    async exists(path: string, fileName: string): Promise<boolean> {
        return this.storage.exists(path, fileName);
    }

    //
    // Gets info about an asset.
    //
    async info(path: string, fileName: string): Promise<IFileInfo | undefined> {
        return this.storage.info(path, fileName);
    }

    //
    // Reads a file from storage.
    // Returns undefined if the file doesn't exist.
    //
    async read(path: string, fileName: string): Promise<Buffer | undefined> {
        const data = await this.storage.read(path, fileName);
        if (!data) {
            return undefined;
        }

        return decryptBuffer(this.privateKey, data);
    }

    //
    // Writes a file to storage.
    //
    async write(path: string, fileName: string, contentType: string, data: Buffer): Promise<void> {               
        await this.storage.write(path, fileName, contentType, await encryptBuffer(this.publicKey, data));
    }

    //
    // Streams a file from stroage.
    //
    readStream(path: string, fileName: string): Readable {
        const decryptionStream = createDecryptionStream(this.privateKey);
        const readStream = this.storage.readStream(path, fileName)
        readStream.pipe(decryptionStream);
        return decryptionStream;
    }

    //
    // Writes an input stream to storage.
    //
    async writeStream(path: string, fileName: string, contentType: string, inputStream: Readable, contentLength?: number): Promise<void> {
        const encryptionStream = createEncryptionStream(this.publicKey);
        inputStream.pipe(encryptionStream);
        await this.storage.writeStream(path, fileName, contentType, encryptionStream, contentLength);
    }

    //
    // Deletes the file from storage.
    //
    async delete(path: string, fileName: string): Promise<void> {
        return this.storage.delete(path, fileName);
    }
}