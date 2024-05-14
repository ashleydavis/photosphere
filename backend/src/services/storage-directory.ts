import { Readable } from "stream";
import { IAssetInfo, IListResult, IStorage } from "./storage";

//
// Represents a nested directory in the storage system. 
//
export class StorageDirectory implements IStorage {

    constructor(private storage: IStorage, private path: string) {
    }

    //
    // List files in storage.
    //
    list(path: string, max: number, continuationToken?: string): Promise<IListResult> {
        return this.storage.list(`${this.path}/${path}`, max, continuationToken);
    }

    //
    // Returns true if the specified asset exists.
    //
    exists(path: string, assetId: string): Promise<boolean> {
        return this.storage.exists(`${this.path}/${path}`, assetId);
    }

    //
    // Gets info about an asset.
    //
    info(path: string, assetId: string): Promise<IAssetInfo> {
        return this.storage.info(`${this.path}/${path}`, assetId);
    }
    
    //
    // Reads a file from storage.
    // Returns undefined if the file doesn't exist.
    //
    read(path: string, assetId: string): Promise<Buffer | undefined> {
        return this.storage.read(`${this.path}/${path}`, assetId);
    }

    //
    // Writes a file to storage.
    //
    write(path: string, assetId: string, contentType: string, data: Buffer): Promise<void> {
        return this.storage.write(`${this.path}/${path}`, assetId, contentType, data);
    }

    //
    // Streams a file from stroage.
    //
    readStream(path: string, assetId: string): Readable {
        return this.storage.readStream(`${this.path}/${path}`, assetId);    
    }

    //
    // Writes an input stream to storage.
    //
    writeStream(path: string, assetId: string, contentType: string, inputStream: Readable): Promise<void> {
        return this.storage.writeStream(`${this.path}/${path}`, assetId, contentType, inputStream);
    }

    //
    // Deletes the file from storage.
    //
    delete(path: string, assetId: string): Promise<void> {
        return this.storage.delete(`${this.path}/${path}`, assetId);
    }
}