import { Readable } from "stream";
import { IFileInfo, IListResult, IStorage } from "./storage";

//
// Represents a nested directory in the storage system. 
//
export class StorageDirectory implements IStorage {

    constructor(private storage: IStorage, private path: string) {
    }

    //
    // List files in storage.
    //
    list(path: string, max: number, next?: string): Promise<IListResult> {
        return this.storage.list(`${this.path}/${path}`, max, next);
    }

    //
    // Returns true if the specified file exists.
    //
    exists(path: string, fileName: string): Promise<boolean> {
        return this.storage.exists(`${this.path}/${path}`, fileName);
    }

    //
    // Gets info about a file.
    //
    info(path: string, fileName: string): Promise<IFileInfo> {
        return this.storage.info(`${this.path}/${path}`, fileName);
    }
    
    //
    // Reads a file from storage.
    // Returns undefined if the file doesn't exist.
    //
    read(path: string, fileName: string): Promise<Buffer | undefined> {
        return this.storage.read(`${this.path}/${path}`, fileName);
    }

    //
    // Writes a file to storage.
    //
    write(path: string, fileName: string, contentType: string, data: Buffer): Promise<void> {
        return this.storage.write(`${this.path}/${path}`, fileName, contentType, data);
    }

    //
    // Streams a file from stroage.
    //
    readStream(path: string, fileName: string): Readable {
        return this.storage.readStream(`${this.path}/${path}`, fileName);    
    }

    //
    // Writes an input stream to storage.
    //
    writeStream(path: string, fileName: string, contentType: string, inputStream: Readable): Promise<void> {
        return this.storage.writeStream(`${this.path}/${path}`, fileName, contentType, inputStream);
    }

    //
    // Deletes the file from storage.
    //
    delete(path: string, fileName: string): Promise<void> {
        return this.storage.delete(`${this.path}/${path}`, fileName);
    }
}