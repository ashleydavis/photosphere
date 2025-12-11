import * as fs from "fs/promises";
import { createReadStream } from "fs";
import { ensureDir, remove } from "node-utils";
import os from "os";
import path from "path";
import { IBsonCollection } from "bdb";
import { IStorage } from "storage";
import { ILocation, log, retry, reverseGeocode, IUuidGenerator, ITimestampProvider } from "utils";
import dayjs from "dayjs";
import { IAsset } from "defs";
import { getVideoDetails } from "./video";
import { getImageDetails } from "./image";
import { computeAssetHash, getHashFromCache, validateAndHash } from "./hash";
import { HashCache } from "./hash-cache";
import { IFileStat, scanPaths } from "./file-scanner";
import { extractFileFromZipRecursive } from "./zip-utils";

import customParseFormat from "dayjs/plugin/customParseFormat";
dayjs.extend(customParseFormat);

import { acquireWriteLock, refreshWriteLock, releaseWriteLock } from "./write-lock";
import { loadMerkleTree, saveMerkleTree } from "./tree";
import { addItem } from "merkle-tree";
import { extractDominantColorFromThumbnail, ProgressCallback, IAddSummary, IAssetDetails } from "./media-file-database";

//
// Progress callback for addPaths that includes the current summary
//
export type AddPathsProgressCallback = (currentlyScanning: string | undefined, summary: IAddSummary) => void;

//
// Imports a single file into the media file database, processing it, extracting metadata, and storing it with all variants.
//
async function importFile(
    assetStorage: IStorage,
    metadataStorage: IStorage,
    googleApiKey: string | undefined,
    uuidGenerator: IUuidGenerator,
    timestampProvider: ITimestampProvider,
    sessionId: string,
    metadataCollection: IBsonCollection<IAsset>,
    localHashCache: HashCache,
    filePath: string, // Actual file path (always a valid file, possibly temp file from zip)
    fileStat: IFileStat,
    contentType: string,
    labels: string[],
    logicalPath: string, // Logical path for display (always set - equals filePath for non-zip files)
    summary: IAddSummary
): Promise<IAddSummary> {
    const assetId = uuidGenerator.generate();
    const assetTempDir = path.join(os.tmpdir(), `photosphere`, `assets`, uuidGenerator.generate());
    await ensureDir(assetTempDir);
    
    // Use logicalPath for display (always set)
    const fileDisplayPath = logicalPath;
    
    try {
        let localHashedFile = await getHashFromCache(filePath, fileStat, localHashCache);
        if (!localHashedFile) {
            // filePath is always a valid file (already extracted if from zip)
            localHashedFile = await validateAndHash(filePath, fileStat, contentType, logicalPath);
            if (!localHashedFile) {
                summary.filesFailed++;
                summary.filesProcessed++;
                return summary;
            }
            // Add hash to cache after computation
            localHashCache.addHash(filePath, localHashedFile);
        }

        const localHashStr = localHashedFile.hash.toString("hex");
        const records = await metadataCollection.findByIndex("hash", localHashStr);
        if (records.length > 0) {
            log.verbose(`File "${fileDisplayPath}" with hash "${localHashStr}", matches existing records:\n  ${records.map(r => r._id).join("\n  ")}`);
            summary.filesAlreadyAdded++;
            summary.filesProcessed++;
            return summary;
        }

        log.verbose(`File ${fileDisplayPath} with hash ${localHashStr} has not been added to the media file database. Going to add it now.`);
        
        let assetDetails: IAssetDetails | undefined = undefined;
        
        // filePath is always a valid file (already extracted if from zip)
        if (contentType?.startsWith("video")) {
            assetDetails = await getVideoDetails(filePath, assetTempDir, contentType, uuidGenerator, logicalPath);
        }
        else if (contentType?.startsWith("image")) {
            assetDetails = await getImageDetails(filePath, assetTempDir, contentType, uuidGenerator, logicalPath);
        }

        const assetPath = `asset/${assetId}`;
        const thumbPath = `thumb/${assetId}`;
        const displayPath = `display/${assetId}`;

        if (!await acquireWriteLock(metadataStorage, sessionId)) {
            throw new Error(`Failed to acquire write lock.`);
        }

        if (process.env.SIMULATE_FAILURE === "add-file" && Math.random() < 0.1) {
            throw new Error(`Simulated failure during add-file operation for ${fileDisplayPath}`);
        }

        try {
            let merkleTree = await retry(() => loadMerkleTree(metadataStorage));
            if (!merkleTree) {
                throw new Error(`Failed to load media file database.`);
            }

            // filePath is always a valid file (already extracted if from zip)
            const stream = createReadStream(filePath);
            await retry(() => assetStorage.writeStream(assetPath, contentType, stream, fileStat.length));

            const assetInfo = await retry(() => assetStorage.info(assetPath));
            if (!assetInfo) {
                throw new Error(`Failed to get info for file "${assetPath}"`);
            }

            const hashedAsset = await retry(() => computeAssetHash(assetStorage.readStream(assetPath), assetInfo));
            if (hashedAsset.hash.toString("hex") !== localHashStr) {
                throw new Error(`Hash mismatch for file "${assetPath}": ${hashedAsset.hash.toString("hex")} != ${localHashStr}`);
            }

            await refreshWriteLock(metadataStorage, sessionId);

            merkleTree = addItem(merkleTree, {
                name: assetPath,
                hash: hashedAsset.hash,
                length: hashedAsset.length,
                lastModified: hashedAsset.lastModified,
            });

            if (assetDetails?.thumbnailPath) {
                await retry(() => assetStorage.writeStream(thumbPath, assetDetails.thumbnailContentType!, createReadStream(assetDetails.thumbnailPath)));

                const thumbInfo = await retry(() => assetStorage.info(thumbPath));
                if (!thumbInfo) {
                    throw new Error(`Failed to get info for thumbnail "${thumbPath}"`);
                }
                const hashedThumb = await retry(() => computeAssetHash(assetStorage.readStream(thumbPath), thumbInfo));

                await refreshWriteLock(metadataStorage, sessionId);

                merkleTree = addItem(merkleTree, {
                    name: thumbPath,
                    hash: hashedThumb.hash,
                    length: hashedThumb.length,
                    lastModified: hashedThumb.lastModified,
                });    
            }

            if (assetDetails?.displayPath) {
                await retry(() => assetStorage.writeStream(displayPath, assetDetails.displayContentType, createReadStream(assetDetails.displayPath!)));

                const displayInfo = await retry(() => assetStorage.info(displayPath));
                if (!displayInfo) {
                    throw new Error(`Failed to get info for display "${displayPath}"`);
                }
                const hashedDisplay = await retry(() => computeAssetHash(assetStorage.readStream(displayPath), displayInfo));

                await refreshWriteLock(metadataStorage, sessionId);

                merkleTree = addItem(merkleTree, {
                    name: displayPath,
                    hash: hashedDisplay.hash,
                    length: hashedDisplay.length,
                    lastModified: hashedDisplay.lastModified,
                });
            }

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
            labels = labels.concat(
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

            await refreshWriteLock(metadataStorage, sessionId);

            await metadataCollection.insertOne({
                _id: assetId,
                width: assetDetails?.resolution.width ?? 0,
                height: assetDetails?.resolution.height ?? 0,
                origFileName: path.basename(filePath),
                origPath: fileDir,
                contentType: contentType || "",
                hash: localHashStr,
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
            });

            log.verbose(`Added file "${fileDisplayPath}" to the database with ID "${assetId}".`);

            await refreshWriteLock(metadataStorage, sessionId);

            if (!merkleTree.databaseMetadata) {
                merkleTree.databaseMetadata = { filesImported: 0 };
            }
            merkleTree.databaseMetadata.filesImported++;

            summary.filesAdded++;
            summary.filesProcessed++;
            summary.totalSize += fileStat.length;

            await retry(() => saveMerkleTree(merkleTree, metadataStorage)); 
        }
        catch (err: any) {
            log.exception(`Failed to upload asset data for file "${fileDisplayPath}"`, err);
            await retry(() => assetStorage.deleteFile(assetPath));
            await retry(() => assetStorage.deleteFile(thumbPath));
            await retry(() => assetStorage.deleteFile(displayPath));
            summary.filesFailed++;
            summary.filesProcessed++;
        }
        finally {
            await releaseWriteLock(metadataStorage);
        }
    }
    finally {            
        await retry(() => remove(assetTempDir));
    }
    
    return summary;
}

//
// Adds a list of files or directories to the media file database.
//
export async function addPaths(
    assetStorage: IStorage,
    metadataStorage: IStorage,
    googleApiKey: string | undefined,
    uuidGenerator: IUuidGenerator,
    timestampProvider: ITimestampProvider,
    sessionId: string,
    metadataCollection: IBsonCollection<IAsset>,
    localHashCache: HashCache,
    paths: string[],
    progressCallback: AddPathsProgressCallback | undefined,
    sessionTempDir: string
): Promise<IAddSummary> {
    const summary: IAddSummary = {
        filesAdded: 0,
        filesAlreadyAdded: 0,
        filesIgnored: 0,
        filesFailed: 0,
        filesProcessed: 0,
        totalSize: 0,
        averageSize: 0,
    };

    await scanPaths(paths, async (result) => {
        await importFile(
            assetStorage,
            metadataStorage,
            googleApiKey,
            uuidGenerator,
            timestampProvider,
            sessionId,
            metadataCollection,
            localHashCache,
            result.filePath, // Use filePath for checking (always a valid file, possibly temp file from zip)
            result.fileStat,
            result.contentType,
            result.labels,
            result.logicalPath, // Use logicalPath for display to user
            summary
        );
        
        if (summary.filesAdded % 100 === 0) {
            await retry(() => localHashCache.save());
        }
    }, (currentlyScanning, state) => {
        summary.filesIgnored = state.numFilesIgnored;
        if (progressCallback) {
            progressCallback(currentlyScanning, summary);
        }
    }, { ignorePatterns: [/\.db/] }, sessionTempDir, uuidGenerator);
    
    await retry(() => localHashCache.save());

    summary.averageSize = summary.filesAdded > 0 ? Math.floor(summary.totalSize / summary.filesAdded) : 0;
    return summary;
}

