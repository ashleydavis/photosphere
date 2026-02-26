//
// Import worker handler - handles file import tasks
//

import * as fs from "fs/promises";
import { createReadStream } from "fs";
import { ensureDir, remove } from "node-utils";
import os from "os";
import path from "path";
import { createStorage, loadEncryptionKeys, IStorageDescriptor, IS3Credentials } from "storage";
import type { ITaskContext } from "task-queue";
import { validateAndHash, getHashFromCache, computeAssetHash } from "./hash";
import { HashCache } from "./hash-cache";
import { IFileStat } from "./file-scanner";
import { createMediaFileDatabase, extractDominantColorFromThumbnail } from "./media-file-database";
import { getVideoDetails } from "./video";
import { getImageDetails } from "./image";
import { IAssetDetails } from "./media-file-database";
import { ILocation, log, retry, reverseGeocode, swallowError } from "utils";
import dayjs from "dayjs";
import { IAsset } from "defs";
import { IHashedData } from "merkle-tree";

//
// Payload for the hash-file task. Contains only what is needed to hash the file and check
// whether that hash already exists in the database (no labels, API keys, or import-only fields).
//
export interface IHashFileData {
    filePath: string; // Actual path to the file (e.g. temp file when importing from zip).
    fileStat: IFileStat;
    contentType: string;
    storageDescriptor: IStorageDescriptor;
    hashCacheDir: string; // Directory for the hash cache (read-only in the worker).
    s3Config?: IS3Credentials;
    logicalPath: string; // Path used in UI (e.g. path inside a zip).
    assetId: string; // ID to use for this asset if it is imported.
}

//
// Payload for the import-file task. Includes everything needed to run the import (metadata,
// uploads, labels, etc.) and must include expectedHash from the hash-file result when queued by the main thread.
// so the worker skips hashing and duplicate check.
//
export interface IImportFileData {
    filePath: string;
    fileStat: IFileStat;
    contentType: string;
    storageDescriptor: IStorageDescriptor;
    hashCacheDir: string;
    s3Config?: IS3Credentials;
    logicalPath: string;
    assetId: string;
    labels: string[];
    googleApiKey?: string; // Used for reverse geocoding when present.
    sessionId: string;
    dryRun?: boolean;
    expectedHash: ArrayBuffer; // The hash of the file. It's an ArrayBuffer because that is transferred efficiently via postMessage.
}

//
// Result of the hash-file task. Returned to the main thread so it can decide whether to queue
// an import-file task (only when filesAlreadyAdded is false) and update summary stats.
//
export interface IHashFileResult {
    filesAlreadyAdded: boolean; // True if this hash is already in the database (skip import).
    hash: ArrayBuffer; // The hash of the file. It's an ArrayBuffer because that is transferred efficiently via postMessage.
    hashFromCache: boolean; // True if the hash was loaded from cache, false if computed.
}

//
// Data produced by the import-file worker for the main thread to apply to the database
// (merkle tree updates and metadata insert). Built after uploads succeed.
//
export interface IImportFileDatabaseData {
    assetId: string;
    assetPath: string;
    assetHash: string; // Hex string.
    assetLength: number;
    assetLastModified: Date;
    thumbPath?: string;
    thumbHash?: string; // Hex string.
    thumbLength?: number;
    thumbLastModified?: Date;
    displayPath?: string;
    displayHash?: string; // Hex string.
    displayLength?: number;
    displayLastModified?: Date;
    assetRecord: IAsset; // Full asset record to insert into the metadata collection.
}

//
// Result of the import-file task. Returned to the main thread so it can queue a database update.
// Import is only queued for files not already in the database. Hash cache was updated when
// the hash-file task completed, so this result only carries what the main thread needs for the DB.
//
export interface IImportFileResult {
    totalSize: number;
    assetData: IImportFileDatabaseData; // Uploads succeeded; main thread applies this to the database.
}

//
// Handler for hashing a file and checking if it is already in the database.
// Returns hash details and filesAlreadyAdded so the main thread can conditionally queue an import task.
//
export async function hashFileHandler(data: IHashFileData, context: ITaskContext): Promise<IHashFileResult> {
    const { filePath, fileStat, contentType, storageDescriptor, hashCacheDir, s3Config } = data;
    const { uuidGenerator, timestampProvider } = context;
    const assetId = data.assetId;

    log.verbose(`Hashing file ${data.logicalPath} (asset id ${assetId})`);

    // Load hash cache (read-only)
    //TODO: It might be cheaper just to load this once in the main thread and don't even add a task when we already have the hash.
    const localHashCache = new HashCache(hashCacheDir, true); // readonly = true
    await localHashCache.load();

    // Check cache first
    let hashedFile = await getHashFromCache(filePath, fileStat, localHashCache);
    const hashFromCache = !!hashedFile;

    if (!hashedFile) {
        // Not in cache - compute hash
        // filePath is always a valid file (already extracted if from zip)
        hashedFile = await validateAndHash(filePath, fileStat, contentType, data.logicalPath);
        if (!hashedFile) {
            throw new Error(`Failed to validate and hash file ${data.logicalPath} (${assetId})`);
        }
    }

    // Recreate storage and metadata collection in the worker (for checking if file exists)
    const { options: storageOptions } = await loadEncryptionKeys(storageDescriptor.encryptionKeyPaths, false);
    const { storage: assetStorage } = createStorage(storageDescriptor.dbDir, s3Config, storageOptions);
    const database = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);
    const metadataCollection = database.metadataCollection;

    // Check if file is already in database
    const localHashStr = hashedFile.hash.toString("hex");
    const records = await metadataCollection.findByIndex("hash", localHashStr); //TODO: If this lookup were fast (I need to optimize it) then we could do it after the has is returned to the main thread.

    // Buffer is backed by ArrayBuffer; slice so it can be transferred (Buffer itself is not transferable).
    const hashArrayBuffer = hashedFile.hash.buffer.slice(
        hashedFile.hash.byteOffset,
        hashedFile.hash.byteOffset + hashedFile.hash.byteLength
    ) as ArrayBuffer;
    return {
        filesAlreadyAdded: records.length > 0,
        hash: hashArrayBuffer,
        hashFromCache,
    };
}

//
// Handler for importing a single file (after hash-file has run and determined the file is not already in the database).
// Expects data.expectedHash from the hash-file task; hashing and duplicate check are done there.
// Note: Hash cache is loaded read-only in workers. Saving is handled in the main thread.
// This handler does CPU-intensive work and file uploads. Database updates are handled in the main thread.
//
export async function importFileHandler(data: IImportFileData, context: ITaskContext): Promise<IImportFileResult> {
    const { filePath, fileStat, contentType, storageDescriptor, s3Config, googleApiKey, dryRun } = data;
    const { uuidGenerator, timestampProvider } = context;

    const assetId = data.assetId;
    log.verbose(`Importing file ${data.logicalPath} to asset database with asset id ${assetId}`);

    const expectedHashBuffer = Buffer.from(data.expectedHash);

    // Extract metadata/details and import (storage needed for uploads)
    const { options: storageOptions } = await loadEncryptionKeys(storageDescriptor.encryptionKeyPaths, false);
    const { storage: assetStorage } = createStorage(storageDescriptor.dbDir, s3Config, storageOptions);
    const assetTempDir = path.join(os.tmpdir(), `photosphere`, `assets`, uuidGenerator.generate());
    await ensureDir(assetTempDir);
    
    // Use logicalPath for display (always set)
    const fileDisplayPath = data.logicalPath;
    
    try {
        let assetDetails: IAssetDetails | undefined = undefined;
        
        // filePath is always a valid file (already extracted if from zip)
        //TODO: We should be able to get this information from the validation phase instead of getting it again here.
        if (contentType?.startsWith("video")) {
            assetDetails = await getVideoDetails(filePath, assetTempDir, contentType, uuidGenerator, data.logicalPath);
        }
        else if (contentType?.startsWith("image")) {
            assetDetails = await getImageDetails(filePath, assetTempDir, contentType, uuidGenerator, data.logicalPath);
        }

        const assetPath = `asset/${assetId}`;
        const thumbPath = `thumb/${assetId}`;
        const displayPath = `display/${assetId}`;

        if (process.env.SIMULATE_FAILURE === "add-file" && Math.random() < 0.1) {
            throw new Error(`Simulated failure during add-file operation for ${fileDisplayPath}`);
        }

        try {
            let hashedAsset: IHashedData;

            // Upload files (no database writes here - that's done in main thread)
            // filePath is always a valid file (already extracted if from zip)
            if (dryRun) {
                // Mock hashed asset.
                hashedAsset = {
                    hash: expectedHashBuffer,
                    length: fileStat.length,
                    lastModified: fileStat.lastModified,
                };
            }
            else {
                await retry(() => assetStorage.writeStream(assetPath, contentType, createReadStream(filePath), fileStat.length));

                const assetInfo = await retry(() => assetStorage.info(assetPath));
                if (!assetInfo) {
                    throw new Error(`Failed to get info for file ${assetPath} (${assetId})`);
                }

                hashedAsset = await retry(() => computeAssetHash(assetStorage.readStream(assetPath), assetInfo));
                if (Buffer.compare(hashedAsset.hash, expectedHashBuffer) !== 0) {
                    throw new Error(`Hash mismatch for file ${assetPath} (${assetId}): ${hashedAsset.hash.toString("hex")} != ${expectedHashBuffer.toString("hex")}`);
                }
            }

            let thumbHash: Buffer | undefined = undefined;
            let thumbLength: number | undefined = undefined;
            let thumbLastModified: Date | undefined = undefined;

            if (assetDetails?.thumbnailPath) {
                if (dryRun) {
                    // Mock hashed thumbnail.
                    thumbHash = expectedHashBuffer;
                    thumbLength = fileStat.length;
                    thumbLastModified = fileStat.lastModified;
                }
                else {
                    await retry(() => assetStorage.writeStream(thumbPath, assetDetails.thumbnailContentType!, createReadStream(assetDetails.thumbnailPath)));

                    const thumbInfo = await retry(() => assetStorage.info(thumbPath));
                    if (!thumbInfo) {
                        throw new Error(`Failed to get info for thumbnail ${thumbPath} (${assetId})`);
                    }
                    const hashedThumb = await retry(() => computeAssetHash(assetStorage.readStream(thumbPath), thumbInfo));
                    thumbHash = hashedThumb.hash;
                    thumbLength = hashedThumb.length;
                    thumbLastModified = hashedThumb.lastModified;
                }
            }

            let displayHash: Buffer | undefined = undefined;
            let displayLength: number | undefined = undefined;
            let displayLastModified: Date | undefined = undefined;

            if (assetDetails?.displayPath) {
                if (dryRun) {
                    // Mock hashed display.
                    displayHash = expectedHashBuffer;
                    displayLength = fileStat.length;
                    displayLastModified = fileStat.lastModified;
                }
                else {
                    await retry(() => assetStorage.writeStream(displayPath, assetDetails.displayContentType, createReadStream(assetDetails.displayPath!)));

                    const displayInfo = await retry(() => assetStorage.info(displayPath));
                    if (!displayInfo) {
                        throw new Error(`Failed to get info for display ${displayPath} (${assetId})`);
                    }
                    const hashedDisplay = await retry(() => computeAssetHash(assetStorage.readStream(displayPath), displayInfo));
                    displayHash = hashedDisplay.hash;
                    displayLength = hashedDisplay.length;
                    displayLastModified = hashedDisplay.lastModified;
                }
            }

            // Prepare metadata for database insert (done in main thread)
            const properties: any = {};
            if (assetDetails?.metadata) {
                properties.metadata = assetDetails.metadata;
            }

            let coordinates: ILocation | undefined = undefined;
            let location: string | undefined = undefined;
            if (assetDetails?.coordinates) {
                coordinates = assetDetails.coordinates;
                if (googleApiKey) {
                    const reverseGeocodingResult = await retry(() => reverseGeocode(assetDetails.coordinates!, googleApiKey), 3, 1500);
                    if (reverseGeocodingResult) {
                        location = reverseGeocodingResult.location;
                        properties.reverseGeocoding = {
                            type: reverseGeocodingResult.type,
                            fullResult: reverseGeocodingResult.fullResult,
                        };
                    }
                }
            }

            const fileDir = path.dirname(filePath);
            const labels = data.labels.concat(
                fileDir.replace(/\\/g, "/")
                    .split("/")
                    .filter(label => label)
            );

            const description = "";
            const micro = assetDetails?.microPath
                ? (await retry(() => fs.readFile(assetDetails.microPath))).toString("base64")
                : undefined;

            const color = assetDetails 
                ? await extractDominantColorFromThumbnail(assetDetails.thumbnailPath) 
                : undefined;

            const assetRecord: IAsset = {
                _id: assetId,
                width: assetDetails?.resolution.width ?? 0,
                height: assetDetails?.resolution.height ?? 0,
                origFileName: path.basename(filePath),
                origPath: fileDir,
                contentType: contentType || "",
                hash: expectedHashBuffer.toString("hex"),
                coordinates,
                location,
                duration: assetDetails?.duration,
                fileDate: dayjs(fileStat.lastModified).toISOString(),
                photoDate: assetDetails?.photoDate || dayjs(fileStat.lastModified).toISOString(),
                uploadDate: dayjs(timestampProvider.dateNow()).toISOString(),
                properties,
                labels,
                description: description || "",
                micro: micro || "",
                color: color || [0, 0, 0],
            };

            return {
                totalSize: fileStat.length,
                assetData: {
                    assetId,
                    assetPath,
                    assetHash: hashedAsset.hash.toString("hex"),
                    assetLength: hashedAsset.length,
                    assetLastModified: hashedAsset.lastModified,
                    thumbPath: assetDetails?.thumbnailPath ? thumbPath : undefined,
                    thumbHash: thumbHash ? thumbHash.toString("hex") : undefined,
                    thumbLength,
                    thumbLastModified,
                    displayPath: assetDetails?.displayPath ? displayPath : undefined,
                    displayHash: displayHash ? displayHash.toString("hex") : undefined,
                    displayLength,
                    displayLastModified,
                    assetRecord,
                },
            };
        }
        catch (err: any) {
            log.exception(`Error importing file ${filePath} (${assetId})`, err);

            // Clean up uploaded files on error, then let exception propagate to task queue
            await retry(() => assetStorage.deleteFile(assetPath));
            await retry(() => assetStorage.deleteFile(thumbPath));
            await retry(() => assetStorage.deleteFile(displayPath));
            throw err;
        }
    }
    finally {
        if (assetTempDir) {
            await swallowError(() => remove(assetTempDir));
        }
    }
}

