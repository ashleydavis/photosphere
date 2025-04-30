import { Readable } from "stream";

//
// Partial result of the list operation.
//
export interface IListResult {
    //
    // The list of file or directories names found in storage.
    //
    names: string[];

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
    contentType: string | undefined;

    //
    // The length of the file in bytes.
    //
    length: number;
}

export interface IStorage {

    //
    // List files in storage.
    //
    listFiles(path: string, max: number, next?: string): Promise<IListResult>;

    //
    // List directories in storage.
    //
    listDirs(path: string, max: number, next?: string): Promise<IListResult>;

    //
    // Returns true if the specified file exists.
    //
    fileExists(filePath: string): Promise<boolean>;

    //
    // Returns true if the specified directory exists (contains at least one file or subdirectory).
    //
    dirExists(dirPath: string): Promise<boolean>;

    //
    // Gets info about a file.
    //
    info(filePath: string): Promise<IFileInfo | undefined>;

    //
    // Reads a file from storage.
    // Returns undefined if the file doesn't exist.
    //
    read(filePath: string): Promise<Buffer | undefined>;

    //
    // Writes a file to storage.
    //
    write(filePath: string, contentType: string | undefined, data: Buffer): Promise<void>;

    //
    // Streams a file from stroage.
    //
    readStream(filePath: string): Readable;

    //
    // Writes an input stream to storage.
    //
    writeStream(filePath: string, contentType: string | undefined, inputStream: Readable, contentLength?: number): Promise<void>;

    //
    // Deletes a file from storage.
    //
    deleteFile(filePath: string): Promise<void>;
    
    //
    // Deletes a directory and all its contents from storage.
    //
    deleteDir(dirPath: string): Promise<void>;

    //
    // Copies a file from one location to another.
    //
    copyTo(srcPath: string, destPath: string): Promise<void>;
}