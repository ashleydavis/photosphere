import { Readable } from "stream";

export type AssetType = "thumb" | "display" | "original";

export interface IStorage {

    //
    // Initialises the storage interface.
    //
    init(): Promise<void>;
    
    //
    // Reads an file from stroage.
    //
    read(type: AssetType, assetId: string): Readable;

    //
    // Writes an input stream to storage.
    //
    write(type: AssetType, assetId: string, contentType: string, inputStream: Readable): Promise<void>;
}