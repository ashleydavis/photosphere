//
// Partial result of the list operation.
//

import type { Readable } from 'stream';

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
    // This is returned from cloud storage, but not from file storage.
    //
    contentType: string | undefined;

    //
    // The length of the file in bytes.
    //
    length: number;

    //
    // The last modified date of the file.
    //
    lastModified: Date;
}

//
// Information about a write lock.
//
export interface IWriteLockInfo {
    //
    // The owner of the lock.
    //
    owner: string;

    //
    // The time when the lock was acquired.
    //
    acquiredAt: Date;

    //
    // The unix timestamp when the lock was acquired.
    //
    timestamp: number;
}

export interface IStorage {

    //
    // Gets the location of the storage.
    //
    readonly location: string;

    //
    // Returns true if the specified directory is empty.
    //
    isEmpty(path: string): Promise<boolean>;

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
    // Writes a stream whose SHA-256 the caller already knows, so nothing has to compute it.
    //
    // A store that can check the bytes against it does (S3 is handed the hash and refuses a write
    // whose body does not match it, which is a stronger guarantee than checking afterwards), and one
    // that cannot ignores it and writes the stream as usual.
    //
    // It exists because computing the hash is the expensive part on a phone. The AWS SDK hashes
    // whatever it is asked to checksum in the embedded engine's pure JavaScript SHA-256, which runs
    // at well under a megabyte a second: measured on a Pixel 6, one 100MB video held the upload for
    // over a quarter of an hour without a byte reaching the server. The sync already knows every
    // file's hash, because it is what the merkle tree is made of.
    //
    // Returns true when the store checked the bytes against the hash as it wrote them, so the caller
    // needs nothing further to know the copy is right. False when it could not, and the caller checks
    // the copy itself.
    //
    writeStreamHashed(filePath: string, contentType: string | undefined, inputStream: NodeJS.ReadableStream, contentLength: number, sha256: Buffer): Promise<boolean>;

    //
    // The SHA-256 of a stored file, when the store can say what it is without sending the file's
    // bytes back. Undefined when it cannot, and undefined for a file that is not there.
    //
    // This exists so a copy can be checked without being read back. S3 computes and keeps a SHA-256
    // of every object written through here, and answers with it in a HEAD request, so comparing a
    // copy against what was sent costs one small request instead of the whole file again. A store
    // with no such answer says so, and the caller reads the file back and hashes it as before.
    //
    // On a phone that difference is the difference between working and not: the sync's verification
    // read-back downloads every file a second time and hashes it with the embedded engine's pure
    // JavaScript SHA-256, which runs at well under a megabyte a second.
    //
    storedHash(filePath: string): Promise<Buffer | undefined>;

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
    // Returns a Node Readable stream (has destroy() for early termination).
    //
    readStream(filePath: string): Promise<Readable>;

    //
    // Writes an input stream to storage.
    //
    writeStream(filePath: string, contentType: string | undefined, inputStream: NodeJS.ReadableStream, contentLength?: number): Promise<void>;

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

    //
    // Checks if a write lock is acquired for the specified file.
    // Returns the lock information if it exists, undefined otherwise.
    //
    checkWriteLock(filePath: string): Promise<IWriteLockInfo | undefined>;

    //
    // Attempts to acquire a write lock for the specified file.
    // Returns true if the lock was acquired, false if it already exists.
    //
    acquireWriteLock(filePath: string, owner: string): Promise<boolean>;

    //
    // Releases a write lock for the specified file.
    //
    releaseWriteLock(filePath: string): Promise<void>;

    //
    // Refreshes a write lock for the specified file, updating its timestamp.
    // Throws an error if the lock is no longer owned by the specified owner.
    //
    refreshWriteLock(filePath: string, owner: string): Promise<void>;
}