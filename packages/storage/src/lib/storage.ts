import { Readable } from "stream";

//
// Partial result of the list operation.
//
export interface IListResult {
    //
    // The list of file names found in storage.
    //
    fileNames: string[];

    //
    // If there are more assets to read the contination token is set.
    //
    next?: string;
}

//
// Information about a file.
//
export interface IFileInfo {
    //
    // The content type of the file.
    //
    contentType: string;

    //
    // The length of the file in bytes.
    //
    length: number;
}

export interface IStorage {

    //
    // List files in storage.
    //
    list(path: string, max: number, next?: string): Promise<IListResult>;

    //
    // Returns true if the specified file exists.
    //
    exists(path: string, fileName: string): Promise<boolean>;

    //
    // Gets info about a file.
    //
    info(path: string, fileName: string): Promise<IFileInfo | undefined>;
    
    //
    // Reads a file from storage.
    // Returns undefined if the file doesn't exist.
    //
    read(path: string, fileName: string): Promise<Buffer | undefined>;

    //
    // Writes a file to storage.
    //
    write(path: string, fileName: string, contentType: string, data: Buffer): Promise<void>;

    //
    // Streams a file from stroage.
    //
    readStream(path: string, fileName: string): Readable;

    //
    // Writes an input stream to storage.
    //
    writeStream(path: string, fileName: string, contentType: string, inputStream: Readable, contentLength?: number): Promise<void>;

    //
    // Deletes the file from storage.
    //
    delete(path: string, fileName: string): Promise<void>;
}