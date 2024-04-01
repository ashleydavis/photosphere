import { Readable } from "stream";

//
// Partial result of the list operation.
//
export interface IListResult {
    //
    // The IDs of assets that were found.
    //
    assetIds: string[];

    //
    // If there are more assets to read the contination token is set.
    //
    continuation?: string;
}

//
// Information about an asset.
//
export interface IAssetInfo {
    //
    // The content type of the asset.
    //
    contentType: string;

    //
    // The length of the asset in bytes.
    //
    length: number;
}

export interface IStorage {

    //
    // List files in storage.
    //
    list(path: string, max: number, continuationToken?: string): Promise<IListResult>;

    //
    // Returns true if the specified asset exists.
    //
    exists(path: string, assetId: string): Promise<boolean>;

    //
    // Gets info about an asset.
    //
    info(path: string, assetId: string): Promise<IAssetInfo>;
    
    //
    // Reads a file from storage.
    // Returns undefined if the file doesn't exist.
    //
    read(path: string, assetId: string): Promise<Buffer | undefined>;

    //
    // Writes a file to storage.
    //
    write(path: string, assetId: string, contentType: string, data: Buffer): Promise<void>;

    //
    // Streams a file from stroage.
    //
    readStream(path: string, assetId: string): Readable;

    //
    // Writes an input stream to storage.
    //
    writeStream(path: string, assetId: string, contentType: string, inputStream: Readable): Promise<void>;
}