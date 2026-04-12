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
import { LARGE_FILE_TIMEOUT } from "./constants";
import dayjs from "dayjs";
import { IAsset } from "defs";
import { IHashedData, addItem } from "merkle-tree";
import { BsonDatabase } from "bdb";
import { acquireWriteLock, releaseWriteLock } from "./write-lock";
import { loadMerkleTree, saveMerkleTree } from "./tree";
import { updateDatabaseConfig } from "./database-config";

//
// Payload for the hash-file task. Contains everything needed to hash the file, check for
// duplicates, and — if the file is new — queue an import-file task with the full context.
//
export interface IHashFileData {
    // Actual path to the file (e.g. temp file when importing from zip).
    filePath: string;

    // File size and modification time.
    fileStat: IFileStat;

    // MIME type of the file.
    contentType: string;

    // Identifies the target database and encryption keys.
    storageDescriptor: IStorageDescriptor;

    // Directory for the hash cache (read-only in the worker).
    hashCacheDir: string;

    // S3 credentials when the database is hosted in cloud storage (optional).
    s3Config?: IS3Credentials;

    // Path used in UI (e.g. path inside a zip).
    logicalPath: string;

    // ID to use for this asset if it is imported.
    assetId: string;

    // Labels to attach to the asset (e.g. folder hierarchy).
    labels: string[];

    // Google Maps API key for reverse geocoding (optional).
    googleApiKey?: string;

    // Unique identifier for the session, used to acquire the write lock.
    sessionId: string;

    // When true, files are scanned and hashed but not written to the database.
    dryRun?: boolean;
}

//
// Handler for importing a single file. Hashes the file, checks for duplicates, then performs
// uploads and writes the asset record and merkle tree directly to the database under the write lock.
//
export async function importFileHandler(data: IHashFileData, context: ITaskContext): Promise<void> {
    if (context.isCancelled()) {
        return;
    }

    context.sendMessage({ type: "import-pending", assetId: data.assetId, logicalPath: data.logicalPath });

    const { filePath, fileStat, contentType, storageDescriptor, hashCacheDir, s3Config, googleApiKey, dryRun, sessionId } = data;
    const { uuidGenerator, timestampProvider } = context;

    const assetId = data.assetId;
    log.verbose(`Importing file ${data.logicalPath} to asset database with asset id ${assetId}`);

    // Load hash cache (read-only)
    const localHashCache = new HashCache(hashCacheDir, true);
    await localHashCache.load();

    // Check cache first
    let hashedFile = await getHashFromCache(filePath, fileStat, localHashCache);

    if (!hashedFile) {
        // Not in cache - compute hash
        hashedFile = await validateAndHash(filePath, fileStat, contentType, data.logicalPath);
        if (!hashedFile) {
            throw new Error(`Failed to validate and hash file ${data.logicalPath} (${assetId})`);
        }
    }

    // Check if file is already in database before doing any work
    const { options: storageOptions } = await loadEncryptionKeys(storageDescriptor.encryptionKeyPaths, false);
    const { storage, rawStorage } = createStorage(storageDescriptor.dbDir, s3Config, storageOptions);
    const database = createMediaFileDatabase(storage, uuidGenerator, timestampProvider);
    const metadataCollection = database.metadataCollection;
    const localHashStr = hashedFile.hash.toString("hex");
    const existingRecordsEarlyCheck = await metadataCollection.sortIndex("hash", "asc").findByValue(localHashStr);
    if (existingRecordsEarlyCheck.length > 0) {
        context.sendMessage({ type: "import-skipped", assetId: data.assetId, logicalPath: data.logicalPath });
        return;
    }

    const expectedHashBuffer = Buffer.from(hashedFile.hash);

    // Extract metadata/details and import (storage already created above)
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

        const assetPath = `asset/${assetId}`; //todo: this relies on the wrapper!
        const thumbPath = `thumb/${assetId}`;
        const displayPath = `display/${assetId}`;

        if (process.env.SIMULATE_FAILURE === "add-file" && Math.random() < 0.1) {
            throw new Error(`Simulated failure during add-file operation for ${fileDisplayPath}`);
        }

        try {
            let wasSkippedConcurrently = false;
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
                await retry(() => storage.writeStream(assetPath, contentType, createReadStream(filePath), fileStat.length), 3, 1_000, 2, LARGE_FILE_TIMEOUT);

                const assetInfo = await retry(() => storage.info(assetPath));
                if (!assetInfo) {
                    throw new Error(`Failed to get info for file ${assetPath} (${assetId})`);
                }

                hashedAsset = await retry(async () => computeAssetHash(await storage.readStream(assetPath), assetInfo), 3, 1_000, 2, LARGE_FILE_TIMEOUT);
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
                    await retry(() => storage.writeStream(thumbPath, assetDetails.thumbnailContentType!, createReadStream(assetDetails.thumbnailPath)), 3, 1_000, 2, LARGE_FILE_TIMEOUT);

                    const thumbInfo = await retry(() => storage.info(thumbPath));
                    if (!thumbInfo) {
                        throw new Error(`Failed to get info for thumbnail ${thumbPath} (${assetId})`);
                    }
                    const hashedThumb = await retry(async () => computeAssetHash(await storage.readStream(thumbPath), thumbInfo), 3, 1_000, 2, LARGE_FILE_TIMEOUT);
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
                    await retry(() => storage.writeStream(displayPath, assetDetails.displayContentType, createReadStream(assetDetails.displayPath!)), 3, 1_000, 2, LARGE_FILE_TIMEOUT);

                    const displayInfo = await retry(() => storage.info(displayPath));
                    if (!displayInfo) {
                        throw new Error(`Failed to get info for display ${displayPath} (${assetId})`);
                    }
                    const hashedDisplay = await retry(async () => computeAssetHash(await storage.readStream(displayPath), displayInfo), 3, 1_000, 2, LARGE_FILE_TIMEOUT);
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

            // Write asset record and merkle tree directly to the database under the write lock.
            await acquireWriteLock(rawStorage, sessionId, 3);

            try {
                if (!dryRun) {
                    // Check for duplicates before touching the merkle tree: another worker may have
                    // imported the same content concurrently (e.g. two files with identical bytes
                    // in the same scan). Re-check under the write lock before doing any work.
                    const bsonDatabase = new BsonDatabase(storage, ".db/bson", uuidGenerator, timestampProvider);
                    const metadataCollection = bsonDatabase.collection<IAsset>("metadata");
                    const existingRecords = await metadataCollection.sortIndex("hash", "asc").findByValue(expectedHashBuffer.toString("hex"));
                    if (existingRecords.length > 0) {
                        log.verbose(`File "${data.logicalPath}" (${assetId}) already inserted by a concurrent import, skipping.`);
                        wasSkippedConcurrently = true;
                        context.sendMessage({ type: "import-skipped", assetId: data.assetId, logicalPath: data.logicalPath });
                    }
                    else {
                        let merkleTree = await retry(() => loadMerkleTree(storage));
                        if (!merkleTree) {
                            throw new Error(`Failed to load merkle tree`);
                        }

                        // Add asset file to merkle tree
                        merkleTree = addItem(merkleTree, {
                            name: assetPath,
                            hash: Buffer.from(hashedAsset.hash.toString("hex"), "hex"),
                            length: hashedAsset.length,
                            lastModified: hashedAsset.lastModified,
                        });

                        // Add thumbnail to merkle tree if present
                        if (assetDetails?.thumbnailPath && thumbHash) {
                            merkleTree = addItem(merkleTree, {
                                name: thumbPath,
                                hash: Buffer.from(thumbHash.toString("hex"), "hex"),
                                length: thumbLength!,
                                lastModified: thumbLastModified!,
                            });
                        }

                        // Add display file to merkle tree if present
                        if (assetDetails?.displayPath && displayHash) {
                            merkleTree = addItem(merkleTree, {
                                name: displayPath,
                                hash: Buffer.from(displayHash.toString("hex"), "hex"),
                                length: displayLength!,
                                lastModified: displayLastModified!,
                            });
                        }

                        // Update filesImported counter in merkle tree metadata
                        if (!merkleTree.databaseMetadata) {
                            merkleTree.databaseMetadata = { filesImported: 0 };
                        }
                        merkleTree.databaseMetadata.filesImported = (merkleTree.databaseMetadata.filesImported ?? 0) + 1;

                        await metadataCollection.insertOne(assetRecord);
                        await retry(() => saveMerkleTree(merkleTree, storage));
                        await bsonDatabase.commit();
                        await updateDatabaseConfig(rawStorage, { lastModifiedAt: new Date().toISOString() });
                    }
                }
            }
            finally {
                await releaseWriteLock(rawStorage);
            }

            if (!wasSkippedConcurrently) {
                log.verbose(dryRun
                    ? `[DRY RUN] Would add file "${data.logicalPath}" to the database with ID "${assetId}" with id ${assetId}.`
                    : `Added file "${data.logicalPath}" to the database with ID "${assetId}" with id ${assetId}.`);

                context.sendMessage({ type: "import-success", assetId: data.assetId, logicalPath: data.logicalPath, micro });
            }
        }
        catch (err: any) {
            log.exception(`Error importing file ${filePath} (${assetId})`, err);
            context.sendMessage({ type: "import-failed", assetId: data.assetId, logicalPath: data.logicalPath });

            // Clean up uploaded files on error, then let exception propagate to task queue
            await retry(() => storage.deleteFile(assetPath));
            await retry(() => storage.deleteFile(thumbPath));
            await retry(() => storage.deleteFile(displayPath));
            throw err;
        }
    }
    finally {
        if (assetTempDir) {
            await swallowError(() => remove(assetTempDir));
        }
    }
}

