//
// An implementation of storage that operates under a particular prefix.
//

import { Readable } from "stream";
import { IFileInfo, IListResult, IStorage } from "./storage";

export class StoragePrefixWrapper implements IStorage {

    constructor(private storage: IStorage, private prefix: string) {
    }

    //
    // List files in storage.
    //
    listFiles(path: string, max: number, next?: string): Promise<IListResult> {
        return this.storage.listFiles(this.prefix + path, max, next);
    }

    //
    // List directories in storage.
    //
    listDirs(path: string, max: number, next?: string): Promise<IListResult> {
        return this.storage.listDirs(this.prefix + path, max, next);
    }

    //
    // Returns true if the specified file exists.
    //
    fileExists(filePath: string): Promise<boolean> {
        return this.storage.fileExists(this.prefix + filePath);
    }

    //
    // Returns true if the specified directory exists (contains at least one file or subdirectory).
    //
    dirExists(dirPath: string): Promise<boolean> {
        return this.storage.dirExists(this.prefix + dirPath);
    }

    //
    // Gets info about a file.
    //
    info(filePath: string): Promise<IFileInfo | undefined> {
        return this.storage.info(this.prefix + filePath);
    }

    //
    // Reads a file from storage.
    // Returns undefined if the file doesn't exist.
    //
    read(filePath: string): Promise<Buffer | undefined> {
        return this.storage.read(this.prefix + filePath);
    }

    //
    // Writes a file to storage.
    //
    write(filePath: string, contentType: string | undefined, data: Buffer): Promise<void> {
        return this.storage.write(this.prefix + filePath, contentType, data);
    }

    //
    // Streams a file from stroage.
    //
    readStream(filePath: string): Readable {
        return this.storage.readStream(this.prefix + filePath);
    }

    //
    // Writes an input stream to storage.
    //
    writeStream(filePath: string, contentType: string | undefined, inputStream: Readable, contentLength?: number): Promise<void> {
        return this.storage.writeStream(this.prefix + filePath, contentType, inputStream, contentLength);
    }

    //
    // Deletes the file from storage.
    //
    delete(filePath: string): Promise<void> {
        return this.storage.delete(this.prefix + filePath);
    }

    //
    // Copies a file from one location to another.
    //
    copyTo(srcPath: string, destPath: string): Promise<void> {
        return this.storage.copyTo(this.prefix + srcPath, this.prefix + destPath);
    }
}