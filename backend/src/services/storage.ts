import { Readable } from "stream";

export interface IStorage {

    //
    // Initialises the storage interface.
    //
    init(): Promise<void>;
    
    //
    // Reads an file from stroage.
    //
    read(type: string, assetId: string): Readable;

    //
    // Writes an input stream to storage.
    //
    write(type: string, assetId: string, contentType: string, inputStream: Readable): Promise<void>;
}