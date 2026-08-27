import { createHash } from "node:crypto";
import * as nodeCrypto from "node:crypto";
import { IFileStat } from "./file-scanner";
import { createReadStream } from "fs";
import { IHashedData } from "merkle-tree";
import { HashCache } from "./hash-cache";
import { validateFile } from "./validation";
import { log } from "utils";
import { IFileCacheIdentity } from "api/src/lib/import-assets.types";

//
// A readable stream that knows the path of the file it is reading.
//
// Node's `fs.ReadStream` carries this, and so does the mobile worker's shim of it. It is what lets
// a hash of a file that is being read as a stream be taken natively instead.
//
interface IPathBearingStream {
    // The path the stream was opened from, absent on a stream that is not reading a file.
    path?: string;
}

//
// Computes a hash from a stream.
//
export function computeHash(inputStream: NodeJS.ReadableStream): Promise<Buffer> {
    return new Promise<Buffer>((resolve, reject) => {
        const hash = createHash("sha256");

        inputStream.on("data", (chunk: Buffer) => {
            hash.update(chunk);
        });

        inputStream.on("end", () => {
            resolve(hash.digest());
        });

        inputStream.on("error", (error) => {
            reject(error);
        });
    });
}

//
// The one part of the crypto module that is not in Node's own: a whole-file SHA-256 that the mobile
// worker's crypto shim provides and Node does not.
//
// This is how the two hashing paths are told apart. On mobile the bundler resolves every `crypto`
// import to `packages/mobile-worker/src/shims/node-crypto.ts`, which exports `hashFileSync` backed
// by the platform's own SHA-256. Everywhere else `crypto` is Node's, which has no such export, and
// the field is undefined. Nothing has to be told which platform it is on: the module that is
// actually loaded answers the question.
//
interface IFileHashingCrypto {
    // Hashes a whole file natively and returns the digest bytes. Absent outside the mobile worker.
    hashFileSync?: (filePath: string) => Buffer;
}

//
// Whether hashing a whole file natively is available here, and the function when it is.
//
// Exported so the choice can be tested rather than inferred from which platform a test happens to
// run on.
//
export function getNativeFileHasher(): ((filePath: string) => Buffer) | undefined {
    return (nodeCrypto as IFileHashingCrypto).hashFileSync;
}

//
// Computes the SHA-256 of a whole file: through the native hasher when one is handed in, and by
// streaming the file through a JS hash when it is not.
//
// The hasher is passed in rather than looked up in here so that both paths can be tested. Looking
// it up inside would leave the native path unreachable from a test on a desktop machine, and a path
// that has never run is a path nobody has checked.
//
// Both paths must produce identical digests. These are the identity of every asset and the key of
// the hash cache, so a digest that differed by a byte would make every database already written
// look wrong, and it would do it silently: photos would re-import and the cache would never hit.
//
export async function computeFileHash(filePath: string, hashFileNatively: ((filePath: string) => Buffer) | undefined): Promise<Buffer> {
    if (hashFileNatively !== undefined) {
        return hashFileNatively(filePath);
    }

    return computeHash(createReadStream(filePath));
}

//
// Computes the hash of an asset storage file (no caching since data is already in merkle tree).
// Takes a stream directly to avoid reading the file back from storage.
//
export async function computeAssetHash(stream: NodeJS.ReadableStream, fileStat: IFileStat): Promise<IHashedData> {
    //
    // Hashed natively when the stream is reading a file and a native hasher is available, and by
    // streaming it through a JS hash otherwise.
    //
    // This is the same choice `computeFileHash` makes, and it is here for the same reason it is
    // there. Every asset written to storage is read back and hashed to put its hash in the merkle
    // tree, three times per photo for the original, the thumbnail and the display version. On a
    // phone that was the pure-JS SHA-256 over bytes fetched across the engine bridge as base64: it
    // was 54% of an import, and it was invisible until the unmeasured remainder was given a counter.
    //
    // Both paths produce the same digest, which is what makes choosing between them safe: these are
    // the hashes recorded in the merkle tree, and one that differed by a byte would make the tree
    // disagree with the files it describes.
    //
    const sourcePath = (stream as IPathBearingStream).path;
    const hashFileNatively = getNativeFileHasher();
    const hash = typeof sourcePath === "string" && hashFileNatively !== undefined
        ? hashFileNatively(sourcePath)
        : await computeHash(stream);

    return {
        hash,
        lastModified: fileStat.lastModified,
        length: fileStat.length,
    };
}

//
// Gets a hash from the cache if it matches what the file is expected to be.
//
// With no identity the file is looked up under its own path and compared against its own stat,
// which is what every manual import does. With one, the item is looked up under the identity the
// caller supplied and compared against that instead: a photo library item is filed under its source
// id, and the temporary copy it was exported to has a path and a modified time that were both
// minted by the copy and match nothing. See IFileCacheIdentity.
//
export async function getHashFromCache(filePath: string, fileStat: IFileStat, hashCache: HashCache, cacheIdentity: IFileCacheIdentity | undefined): Promise<IHashedData | undefined> {
    const key = cacheIdentity ? cacheIdentity.key : filePath;
    const expectedLength = cacheIdentity ? cacheIdentity.length : fileStat.length;
    const expectedLastModified = cacheIdentity ? cacheIdentity.lastModified : fileStat.lastModified.getTime();

    const cacheEntry = hashCache.getHash(key);
    if (cacheEntry) {
        if (cacheEntry.length === expectedLength && cacheEntry.lastModified.getTime() === expectedLastModified) {
            return {
                hash: cacheEntry.hash,
                lastModified: fileStat.lastModified,
                length: fileStat.length,
            }
        }
    }
    return undefined;
}

//
// Validates and computes the hash of a file for import.
// Returns the hashed file data on success, or undefined on failure.
//
export async function validateAndHash(
    filePath: string, // Actual file path (always a valid file, already extracted if from zip)
    fileStat: IFileStat, 
    contentType: string, 
    logicalPath: string // Logical path for display (always set - equals filePath for non-zip files)
): Promise<IHashedData | undefined> {
    try {
        // filePath is always a valid file (already extracted if from zip)
        // Validate the file
        if (!await validateFile(filePath, contentType, fileStat)) {
            return undefined;
        }
    }
    catch (error: any) {
        // Use logicalPath for display (always set)
        log.exception(`File "${logicalPath}" has failed its validation with error: ${error.message}`, error);
        return undefined;
    }

    // Compute hash using the file (already extracted if from zip)
    const hash = await computeFileHash(filePath, getNativeFileHasher());
    const hashedFile: IHashedData = {
        hash,
        lastModified: fileStat.lastModified,
        length: fileStat.length,
    };

    return hashedFile;
}
