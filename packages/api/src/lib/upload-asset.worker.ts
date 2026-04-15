//
// Upload-asset worker handler - uploads a single asset's files to storage and
// returns all data needed by the orchestrator to write the asset to the database.
//

import * as fs from "fs/promises";
import { createReadStream } from "fs";
import { ensureDir, remove } from "node-utils";
import os from "os";
import path from "path";
import { createStorage, loadEncryptionKeys, IStorageDescriptor, IS3Credentials } from "storage";
import type { ITaskContext } from "task-queue";
import { computeAssetHash } from "./hash";
import { IFileStat } from "./file-scanner";
import { IAssetDetails, extractDominantColorFromThumbnail } from "./media-file-database";
import { getVideoDetails } from "./video";
import { getImageDetails } from "./image";
import { ILocation, log, retry, reverseGeocode, swallowError } from "utils";
import { LARGE_FILE_TIMEOUT } from "./constants";
import dayjs from "dayjs";
import { IAsset } from "defs";
import { IHashedData } from "merkle-tree";

//
// Payload for the upload-asset task.
//
export interface IUploadAssetData {
    // Actual path to the file (e.g. temp file when importing from zip).
    filePath: string;

    // File size and modification time.
    fileStat: IFileStat;

    // MIME type of the file.
    contentType: string;

    // Identifies the target database and encryption keys.
    storageDescriptor: IStorageDescriptor;

    // S3 credentials when the database is hosted in cloud storage (optional).
    s3Config?: IS3Credentials;

    // Path used in UI (e.g. path inside a zip).
    logicalPath: string;

    // ID to use for this asset.
    assetId: string;

    // Labels to attach to the asset (e.g. folder hierarchy).
    labels: string[];

    // Google Maps API key for reverse geocoding (optional).
    googleApiKey?: string;

    // Unique identifier for the session.
    sessionId: string;

    // When true, files are scanned and hashed but not written to the database.
    dryRun?: boolean;

    // Pre-computed SHA-256 hash of the file content, supplied by the orchestrator.
    expectedHash: Uint8Array;
}

//
// All data the orchestrator needs to write a single asset to the database.
//
export interface IAssetDatabaseData {
    // ID used for asset/thumb/display storage paths.
    assetId: string;

    // Storage path of the original asset file.
    assetPath: string;

    // Hex-encoded SHA-256 hash of the uploaded asset.
    assetHash: string;

    // Byte length of the uploaded asset.
    assetLength: number;

    // Last-modified date of the uploaded asset.
    assetLastModified: Date;

    // Storage path of the thumbnail (optional).
    thumbPath?: string;

    // Hex-encoded SHA-256 hash of the thumbnail (optional).
    thumbHash?: string;

    // Byte length of the thumbnail (optional).
    thumbLength?: number;

    // Last-modified date of the thumbnail (optional).
    thumbLastModified?: Date;

    // Storage path of the display version (optional).
    displayPath?: string;

    // Hex-encoded SHA-256 hash of the display version (optional).
    displayHash?: string;

    // Byte length of the display version (optional).
    displayLength?: number;

    // Last-modified date of the display version (optional).
    displayLastModified?: Date;

    // Full metadata record ready for metadataCollection.insertOne().
    assetRecord: IAsset;
}

//
// Result returned by the upload-asset task.
//
export interface IUploadAssetResult {
    // All data needed by the orchestrator to write this asset to the database.
    assetData: IAssetDatabaseData;

    // Total byte size of all uploaded files (asset + thumb + display).
    totalSize: number;
}

//
// Handler for uploading a single asset. Extracts metadata, uploads files to storage,
// and returns all data needed by the orchestrator for the database write.
// Does NOT write to the database or acquire the write lock.
//
export async function uploadAssetHandler(data: IUploadAssetData, context: ITaskContext): Promise<IUploadAssetResult | undefined> {
    if (context.isCancelled()) {
        return;
    }

    context.sendMessage({ type: "import-pending", assetId: data.assetId, logicalPath: data.logicalPath });

    const { filePath, fileStat, contentType, storageDescriptor, s3Config, googleApiKey, dryRun } = data;
    const { uuidGenerator, timestampProvider } = context;

    const assetId = data.assetId;
    log.verbose(`Importing file ${data.logicalPath} to asset database with asset id ${assetId}`);

    const expectedHashBuffer = Buffer.from(data.expectedHash);

    const { options: storageOptions } = await loadEncryptionKeys(storageDescriptor.encryptionKeyPaths, false);
    const { storage } = createStorage(storageDescriptor.dbDir, s3Config, storageOptions);

    const assetTempDir = path.join(os.tmpdir(), `photosphere`, `assets`, uuidGenerator.generate());
    await ensureDir(assetTempDir);

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

            if (context.isCancelled()) {
                return;
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

            if (context.isCancelled()) {
                return;
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

            if (context.isCancelled()) {
                return;
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

            if (context.isCancelled()) {
                return;
            }

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

            const totalSize = hashedAsset.length
                + (thumbLength ?? 0)
                + (displayLength ?? 0);

            const assetData: IAssetDatabaseData = {
                assetId,
                assetPath,
                assetHash: hashedAsset.hash.toString("hex"),
                assetLength: hashedAsset.length,
                assetLastModified: hashedAsset.lastModified,
                thumbPath: assetDetails?.thumbnailPath ? thumbPath : undefined,
                thumbHash: thumbHash?.toString("hex"),
                thumbLength,
                thumbLastModified,
                displayPath: assetDetails?.displayPath ? displayPath : undefined,
                displayHash: displayHash?.toString("hex"),
                displayLength,
                displayLastModified,
                assetRecord,
            };

            log.verbose(dryRun
                ? `[DRY RUN] Would add file "${data.logicalPath}" to the database with ID "${assetId}".`
                : `Uploaded file "${data.logicalPath}" with ID "${assetId}".`);

            return { assetData, totalSize };
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

