import fs from "fs-extra";
import os from "os";
import path from "path";
import { BsonDatabase, IBsonCollection, getDatabaseRootHash } from "bdb";
import { IStorage, pathJoin, StoragePrefixWrapper } from "storage";
import { validateFile } from "./validation";
import { ILocation, log, retry, reverseGeocode, IUuidGenerator, ITimestampProvider } from "utils";
import dayjs from "dayjs";
import { IAsset } from "defs";
import { Readable } from "stream";
import { getVideoDetails } from "./video";
import { getImageDetails, IResolution } from "./image";
import { computeHash } from "./hash";
import { HashCache } from "./hash-cache";
import { FileScanner, IFileStat } from "./file-scanner";

import customParseFormat from "dayjs/plugin/customParseFormat";
dayjs.extend(customParseFormat);

import { Image } from "tools";
import _ from "lodash";
import { acquireWriteLock, refreshWriteLock, releaseWriteLock } from "./write-lock";
import { computeAssetHash } from "./hash";
import { loadMerkleTree, saveMerkleTree, getFilesRootHash } from "./tree";
import { addItem, createTree, deleteItem, IHashedData, combineHashes, IMerkleTree } from "merkle-tree";

//
// Extract dominant color from thumbnail buffer using ImageMagick
//
export async function extractDominantColorFromThumbnail(inputPath: string): Promise<[number, number, number] | undefined> {
    const image = new Image(inputPath);
    return await image.getDominantColor();
}

//
// A function that validates a file.
//
export type FileValidator = (filePath: string, fileStat: IFileStat, contentType: string, openStream?: () => Readable) => Promise<boolean>;

//
// Progress callback for the add operation.
//
export type ProgressCallback = (currentlyScanning: string | undefined) => void;

//
// Size of the micro thumbnail.
//
export const MICRO_MIN_SIZE = 40;

//
// Quality of the micro thumbnail.
//
export const MICRO_QUALITY = 75;

//
// Size of the thumbnail.
//
export const THUMBNAIL_MIN_SIZE = 300;

//
// Quality of the thumbnail.
//
export const THUMBNAIL_QUALITY = 90;

//
// Size of the display asset.
//
export const DISPLAY_MIN_SIZE = 1000;

//
// Quality of the display asset.
//
export const DISPLAY_QUALITY = 95;

export interface IDatabaseHashes {
    //
    // Full aggregate hash of the tree root (combines files and database hashes).
    //
    fullHash: string;

    //
    // Root hash of the files merkle tree.
    //
    filesHash: string | undefined;

    //
    // Root hash of the BSON database merkle tree.
    //
    databaseHash: string | undefined;
}

export interface IDatabaseSummary {
    //
    // Total number of files imported into the database.
    //
    totalImports: number;

    //
    // Total number of files in the database (including thumbnails, display images, BSON files, etc.).
    //
    totalFiles: number;

    //
    // Total size of all files in bytes.
    //
    totalSize: number;

    //
    // Total number of nodes in the merkle tree.
    //
    totalNodes: number;

    //
    // Full hash of the tree root.
    //
    fullHash: string;

    //
    // Root hash of the files merkle tree.
    //
    filesHash: string | undefined;

    //
    // Root hash of the BSON database merkle tree.
    //
    databaseHash: string | undefined;

    //
    // Database version from merkle tree.
    //
    databaseVersion: number;
}

//
// Database metadata that gets embedded in the merkle tree
//
export interface IDatabaseMetadata {
    // Number of files imported into the database
    filesImported: number;
    // List of asset IDs that have been deleted from the database
    deletedAssetIds?: string[];
}

export interface IAddSummary {
    //
    // The number of files added to the database.
    //
    filesAdded: number;

    //
    // The number of files already in the database.
    //
    filesAlreadyAdded: number;

    //
    // The number of files ignored (because they are not media files).
    //
    filesIgnored: number;

    //
    // The number of files that failed to be added to the database.
    //
    filesFailed: number;

    //
    // The total size of the files added to the database.
    //
    totalSize: number;

    //
    // The average size of the files added to the database.
    //
    averageSize: number;
}

//
// Collects the details of an asset.
//
export interface IAssetDetails {
    //
    // The resolution of the image/video.
    //
    resolution: IResolution;

    //
    // The generated micro thumbnail of the image/video.
    //
    microPath: string;

    //
    // The generated thumbnail of the image/video.
    //
    thumbnailPath: string;

    //
    // The content type of the thumbnail.
    //
    thumbnailContentType: string;

    //
    // The display image.
    //
    displayPath?: string;

    //
    // The content type of the display image.
    //
    displayContentType?: string;

    //
    // Metadata, if any.
    //
    metadata?: any;

    //
    // GPS coordinates of the asset.
    //
    coordinates?: ILocation;

    //
    // Date of the asset.
    //
    photoDate?: string;

    //
    // Duration of the video, if known.
    //
    duration?: number;
}

//
// Creates the README.md file in the database.
// Returns the updated merkle tree with the README.md file added.
//
export async function createReadme(
    assetStorage: IStorage,
    merkleTree: IMerkleTree<IDatabaseMetadata>
): Promise<IMerkleTree<IDatabaseMetadata>> {
    // Create README.md file with warning about manual modifications
    await retry(() => assetStorage.write('README.md', 'text/markdown', Buffer.from(DATABASE_README_CONTENT, 'utf8')));

    const readmeInfo = await retry(() => assetStorage.info('README.md'));
    if (!readmeInfo) {
        throw new Error('README.md file not found after creation.');
    }

    merkleTree = addItem(merkleTree, {
        name: 'README.md',
        hash: await retry(() => computeHash(assetStorage.readStream('README.md'))),
        length: readmeInfo.length,
        lastModified: readmeInfo.lastModified,
    });
    
    return merkleTree;
}

//
// Creates database dependencies
//
export function createMediaFileDatabase(
    assetStorage: IStorage,
    uuidGenerator: IUuidGenerator,
    timestampProvider: ITimestampProvider
) {
    const bsonDatabase = new BsonDatabase({
        storage: new StoragePrefixWrapper(assetStorage, `metadata`),
        uuidGenerator: uuidGenerator,
        timestampProvider: timestampProvider
    });

    const metadataCollection = bsonDatabase.collection<IAsset>("metadata");
    const localFileScanner = new FileScanner({
        ignorePatterns: [/\.db/]
    });

    return {
        assetStorage,
        bsonDatabase,
        metadataCollection,
        localFileScanner,
    };
}

//
// Creates a new media file database.
//
export async function createDatabase(
    assetStorage: IStorage,
    uuidGenerator: IUuidGenerator,
    metadataCollection: IBsonCollection<IAsset>,
    databaseId?: string
): Promise<void> {

    if (!await assetStorage.isEmpty("./")) {
        throw new Error(`Cannot create new media file database in ${assetStorage.location}. This storage location already contains files! Please create your database in a new empty directory.`);
    }

    let merkleTree = createTree<IDatabaseMetadata>(databaseId || uuidGenerator.generate());
    merkleTree.databaseMetadata = { filesImported: 0 };

    await ensureSortIndex(metadataCollection);

    merkleTree = await createReadme(assetStorage, merkleTree);

    await retry(() => saveMerkleTree(merkleTree, assetStorage));

    log.verbose(`Created new media file database.`);
}

//
// Loads the existing media file database.
//
export async function loadDatabase(
    assetStorage: IStorage,
    metadataCollection: IBsonCollection<IAsset>
): Promise<void> {
    await retry(() => metadataCollection.loadSortIndex("hash", "asc", "string"));
    await retry(() => metadataCollection.loadSortIndex("photoDate", "desc", "date"));

    log.verbose(`Loaded existing media file database from: ${assetStorage.location}`);
}

//
// Ensures the sort index exists.
//
export async function ensureSortIndex(metadataCollection: IBsonCollection<IAsset>): Promise<void> {
    await retry(() => metadataCollection.ensureSortIndex("hash", "asc", "string"));
    await retry(() => metadataCollection.ensureSortIndex("photoDate", "desc", "date"));
}

//
// Gets the database hashes (files hash, database hash, and aggregate hash).
//
export async function getDatabaseHashes(assetStorage: IStorage): Promise<IDatabaseHashes> {
    // Get root hashes from both merkle trees
    const filesRootHash = await retry(() => getFilesRootHash(assetStorage));
    const databaseRootHash = await retry(() => getDatabaseRootHash(new StoragePrefixWrapper(assetStorage, "metadata")));
    
    // Compute aggregate root hash
    let fullHash: string;
    if (filesRootHash && databaseRootHash) {
        const aggregateHash = combineHashes(filesRootHash, databaseRootHash);
        fullHash = aggregateHash.toString('hex');
    } else if (filesRootHash) {
        fullHash = filesRootHash.toString('hex');
    } else if (databaseRootHash) {
        fullHash = databaseRootHash.toString('hex');
    } else {
        fullHash = 'empty';
    }
    
    return {
        fullHash,
        filesHash: filesRootHash?.toString('hex'),
        databaseHash: databaseRootHash?.toString('hex'),
    };
}

//
// Gets a summary of the entire database.
//
export async function getDatabaseSummary(assetStorage: IStorage): Promise<IDatabaseSummary> {
    const merkleTree = await retry(() => loadMerkleTree(assetStorage));
    if (!merkleTree) {
        throw new Error(`Failed to load merkle tree.`);
    }
    const filesImported = merkleTree.databaseMetadata?.filesImported || 0;
    
    // Get database hashes
    const hashes = await getDatabaseHashes(assetStorage);
    
    return {
        totalImports: filesImported,
        totalFiles: merkleTree.sort?.leafCount || 0,
        totalSize: merkleTree.sort?.size || 0,
        totalNodes: merkleTree.sort?.nodeCount || 0,
        fullHash: hashes.fullHash,
        filesHash: hashes.filesHash,
        databaseHash: hashes.databaseHash,
        databaseVersion: merkleTree.version
    };
}

//
// Helper functions for file operations
//
async function getHashFromCache(filePath: string, fileStat: IFileStat, hashCache: HashCache): Promise<IHashedData | undefined> {
    const cacheEntry = hashCache.getHash(filePath);
    if (cacheEntry) {
        if (cacheEntry.length === fileStat.length && cacheEntry.lastModified.getTime() === fileStat.lastModified.getTime()) {
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
// Computes the hash of a file for import, validating it first and caching the result in the hash cache.
//
async function computeCachedHash(
    uuidGenerator: IUuidGenerator,
    localHashCache: HashCache,
    localFileScanner: FileScanner,
    filePath: string, 
    fileStat: IFileStat, 
    contentType: string, 
    assetTempDir: string, 
    openStream: (() => NodeJS.ReadableStream) | undefined,
    progressCallback: ProgressCallback,
    summary: IAddSummary
): Promise<{ hashedFile?: IHashedData; summary: IAddSummary }> {
    let updatedSummary = { ...summary };

    if (openStream === undefined) {
        openStream = () => fs.createReadStream(filePath);
    }
    
    try {
        if (!await validateFile(filePath, contentType, assetTempDir, uuidGenerator, openStream)) {
            updatedSummary.filesFailed++;
            if (progressCallback) {
                progressCallback(localFileScanner.getCurrentlyScanning());
            }            
            return { summary: updatedSummary };
        }
    }
    catch (error: any) {
        log.error(`File "${filePath}" has failed its validation with error: ${error.message}`);
        updatedSummary.filesFailed++;
        if (progressCallback) {
            progressCallback(localFileScanner.getCurrentlyScanning());
        }            
        return { summary: updatedSummary };
    }

    const hash = await computeHash(openStream ? openStream() : fs.createReadStream(filePath));
    const hashedFile: IHashedData = {
        hash,
        lastModified: fileStat.lastModified,
        length: fileStat.length,
    };

    localHashCache.addHash(filePath, hashedFile);

    return { hashedFile, summary: updatedSummary };
}

//
// Imports a single file into the media file database, processing it, extracting metadata, and storing it with all variants.
//
async function importFile(
    assetStorage: IStorage,
    googleApiKey: string | undefined,
    uuidGenerator: IUuidGenerator,
    timestampProvider: ITimestampProvider,
    sessionId: string,
    metadataCollection: IBsonCollection<IAsset>,
    localHashCache: HashCache,
    localFileScanner: FileScanner,
    filePath: string,
    fileStat: IFileStat,
    contentType: string,
    labels: string[],
    openStream: (() => NodeJS.ReadableStream) | undefined,
    progressCallback: ProgressCallback,
    summary: IAddSummary
): Promise<IAddSummary> {
    const assetId = uuidGenerator.generate();
    const assetTempDir = path.join(os.tmpdir(), `photosphere`, `assets`, uuidGenerator.generate());
    await fs.ensureDir(assetTempDir);
    
    let updatedSummary = { ...summary };
    
    try {
        let localHashedFile = await getHashFromCache(filePath, fileStat, localHashCache);
        if (!localHashedFile) {
            const hashResult = await computeCachedHash(uuidGenerator, localHashCache, localFileScanner, filePath, fileStat, contentType, assetTempDir, openStream, progressCallback, updatedSummary);
            if (!hashResult.hashedFile) {
                return hashResult.summary;
            }
            localHashedFile = hashResult.hashedFile;
            updatedSummary = hashResult.summary;
        }

        const localHashStr = localHashedFile.hash.toString("hex");
        const records = await metadataCollection.findByIndex("hash", localHashStr);
        if (records.length > 0) {
            log.verbose(`File "${filePath}" with hash "${localHashStr}", matches existing records:\n  ${records.map(r => r._id).join("\n  ")}`);
            updatedSummary.filesAlreadyAdded++;
            if (progressCallback) {
                progressCallback(localFileScanner.getCurrentlyScanning());
            }
            return updatedSummary;
        }
        
        let assetDetails: IAssetDetails | undefined = undefined;
        
        if (contentType?.startsWith("video")) {
            assetDetails = await getVideoDetails(filePath, assetTempDir, contentType, uuidGenerator, openStream);
        }
        else if (contentType?.startsWith("image")) {
            assetDetails = await getImageDetails(filePath, assetTempDir, contentType, uuidGenerator, openStream);
        }

        const assetPath = `asset/${assetId}`;
        const thumbPath = `thumb/${assetId}`;
        const displayPath = `display/${assetId}`;

        if (!await acquireWriteLock(assetStorage, sessionId)) {
            throw new Error(`Failed to acquire write lock.`);
        }

        if (process.env.SIMULATE_FAILURE === "add-file" && Math.random() < 0.1) {
            throw new Error(`Simulated failure during add-file operation for ${filePath}`);
        }

        try {
            let merkleTree = await retry(() => loadMerkleTree(assetStorage));
            if (!merkleTree) {
                throw new Error(`Failed to load media file database.`);
            }

            await retry(() => assetStorage.writeStream(assetPath, contentType, openStream ? openStream() : fs.createReadStream(filePath), fileStat.length));

            const assetInfo = await retry(() => assetStorage.info(assetPath));
            if (!assetInfo) {
                throw new Error(`Failed to get info for file "${assetPath}"`);
            }

            const hashedAsset = await retry(() => computeAssetHash(assetPath, assetInfo, () => assetStorage.readStream(assetPath)));
            if (hashedAsset.hash.toString("hex") !== localHashStr) {
                throw new Error(`Hash mismatch for file "${assetPath}": ${hashedAsset.hash.toString("hex")} != ${localHashStr}`);
            }

            await refreshWriteLock(assetStorage, sessionId);

            merkleTree = addItem(merkleTree, {
                name: assetPath,
                hash: hashedAsset.hash,
                length: hashedAsset.length,
                lastModified: hashedAsset.lastModified,
            });

            if (assetDetails?.thumbnailPath) {
                await retry(() => assetStorage.writeStream(thumbPath, assetDetails.thumbnailContentType!, fs.createReadStream(assetDetails.thumbnailPath)));

                const thumbInfo = await retry(() => assetStorage.info(thumbPath));
                if (!thumbInfo) {
                    throw new Error(`Failed to get info for thumbnail "${thumbPath}"`);
                }
                const hashedThumb = await retry(() => computeAssetHash(thumbPath, thumbInfo, () => fs.createReadStream(assetDetails.thumbnailPath)));

                await refreshWriteLock(assetStorage, sessionId);

                merkleTree = addItem(merkleTree, {
                    name: thumbPath,
                    hash: hashedThumb.hash,
                    length: hashedThumb.length,
                    lastModified: hashedThumb.lastModified,
                });    
            }

            if (assetDetails?.displayPath) {
                await retry(() => assetStorage.writeStream(displayPath, assetDetails.displayContentType, fs.createReadStream(assetDetails.displayPath!)));

                const displayInfo = await retry(() => assetStorage.info(displayPath));
                if (!displayInfo) {
                    throw new Error(`Failed to get info for display "${displayPath}"`);
                }
                const hashedDisplay = await retry(() => computeAssetHash(displayPath, displayInfo, () => fs.createReadStream(assetDetails.displayPath!)));

                await refreshWriteLock(assetStorage, sessionId);

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
                ? (await retry(() => fs.promises.readFile(assetDetails.microPath))).toString("base64")
                : undefined;

            const color = assetDetails 
                ? await extractDominantColorFromThumbnail(assetDetails.thumbnailPath) 
                : undefined;

            await refreshWriteLock(assetStorage, sessionId);

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

            log.verbose(`Added file "${filePath}" to the database with ID "${assetId}".`);

            await refreshWriteLock(assetStorage, sessionId);

            if (!merkleTree.databaseMetadata) {
                merkleTree.databaseMetadata = { filesImported: 0 };
            }
            merkleTree.databaseMetadata.filesImported++;

            updatedSummary.filesAdded++;
            updatedSummary.totalSize += fileStat.length;
            if (progressCallback) {
                progressCallback(localFileScanner.getCurrentlyScanning());
            }

            await retry(() => saveMerkleTree(merkleTree, assetStorage)); 
        }
        catch (err: any) {
            log.exception(`Failed to upload asset data for file "${filePath}"`, err);
            await retry(() => assetStorage.deleteFile(assetPath));
            await retry(() => assetStorage.deleteFile(thumbPath));
            await retry(() => assetStorage.deleteFile(displayPath));
            updatedSummary.filesFailed++;
            if (progressCallback) {
                progressCallback(localFileScanner.getCurrentlyScanning());
            }
        }
        finally {
            await releaseWriteLock(assetStorage);
        }
    }
    finally {            
        await retry(() => fs.remove(assetTempDir));
    }
    
    return updatedSummary;
}

//
// Checks if a file has already been added to the database by computing its hash and looking it up in the metadata collection.
//
async function checkFile(
    uuidGenerator: IUuidGenerator,
    metadataCollection: IBsonCollection<IAsset>,
    localHashCache: HashCache,
    localFileScanner: FileScanner,
    filePath: string,
    fileStat: IFileStat,
    contentType: string,
    openStream: (() => NodeJS.ReadableStream) | undefined,
    progressCallback: ProgressCallback,
    summary: IAddSummary
): Promise<IAddSummary> {
    let updatedSummary = { ...summary };

    let localHashedFile = await getHashFromCache(filePath, fileStat, localHashCache);
    if (!localHashedFile) {          
        const tempDir = path.join(os.tmpdir(), `photosphere`, `check`);
        await fs.ensureDir(tempDir);

        const hashResult = await computeCachedHash(uuidGenerator, localHashCache, localFileScanner, filePath, fileStat, contentType, tempDir, openStream, progressCallback, updatedSummary);
        if (!hashResult.hashedFile) {
            return hashResult.summary;
        }
        localHashedFile = hashResult.hashedFile;
        updatedSummary = hashResult.summary;
    }

    const localHashStr = localHashedFile.hash.toString("hex");
    const records = await metadataCollection.findByIndex("hash", localHashStr);
    if (records.length > 0) {
        log.verbose(`File "${filePath}" with hash "${localHashStr}", matches existing records:\n  ${records.map(r => r._id).join("\n  ")}`);
        updatedSummary.filesAlreadyAdded++;
        return updatedSummary;
    }

    log.verbose(`File "${filePath}" has not been added to the media file database.`);

    updatedSummary.filesAdded++;
    updatedSummary.totalSize += fileStat.length;
    if (progressCallback) {
        progressCallback(localFileScanner.getCurrentlyScanning());
    }
    
    return updatedSummary;
}

//
// Adds a list of files or directories to the media file database.
//
export async function addPaths(
    assetStorage: IStorage,
    googleApiKey: string | undefined,
    uuidGenerator: IUuidGenerator,
    timestampProvider: ITimestampProvider,
    sessionId: string,
    metadataCollection: IBsonCollection<IAsset>,
    localHashCache: HashCache,
    localFileScanner: FileScanner,
    paths: string[],
    progressCallback: ProgressCallback,
    summary: IAddSummary = {
        filesAdded: 0,
        filesAlreadyAdded: 0,
        filesIgnored: 0,
        filesFailed: 0,
        totalSize: 0,
        averageSize: 0,
    }
): Promise<IAddSummary> {
    let updatedSummary = { ...summary };

    await localFileScanner.scanPaths(paths, async (result) => {
        updatedSummary = await importFile(
            assetStorage,
            googleApiKey,
            uuidGenerator,
            timestampProvider,
            sessionId,
            metadataCollection,
            localHashCache,
            localFileScanner,
            result.filePath,
            result.fileStat,
            result.contentType,
            result.labels,
            result.openStream,
            progressCallback,
            updatedSummary
        );
        
        if (updatedSummary.filesAdded % 100 === 0) {
            await retry(() => localHashCache.save());
        }
    }, progressCallback);

    updatedSummary.filesIgnored += localFileScanner.getNumFilesIgnored();
    await retry(() => localHashCache.save());

    updatedSummary.averageSize = updatedSummary.filesAdded > 0 ? Math.floor(updatedSummary.totalSize / updatedSummary.filesAdded) : 0;
    return updatedSummary;
}

//
// Checks a list of files or directories to find files already added to the media file database.
//
export async function checkPaths(
    uuidGenerator: IUuidGenerator,
    metadataCollection: IBsonCollection<IAsset>,
    localHashCache: HashCache,
    localFileScanner: FileScanner,
    paths: string[],
    progressCallback: ProgressCallback,
    summary: IAddSummary = {
        filesAdded: 0,
        filesAlreadyAdded: 0,
        filesIgnored: 0,
        filesFailed: 0,
        totalSize: 0,
        averageSize: 0,
    }
): Promise<IAddSummary> {
    let updatedSummary = { ...summary };

    await localFileScanner.scanPaths(paths, async (result) => {
        updatedSummary = await checkFile(
            uuidGenerator,
            metadataCollection,
            localHashCache,
            localFileScanner,
            result.filePath,
            result.fileStat,
            result.contentType,
            result.openStream,
            progressCallback,
            updatedSummary
        );
        
        if (updatedSummary.filesAdded % 100 === 0) {
            await retry(() => localHashCache.save());
        }
    }, progressCallback);

    await retry(() => localHashCache.save());
    updatedSummary.averageSize = updatedSummary.filesAdded > 0 ? Math.floor(updatedSummary.totalSize / updatedSummary.filesAdded) : 0;
    return updatedSummary;
}

//
// Streams an asset from the database.
// This is used by the REST API server to read assets.
//
export function streamAsset(assetStorage: IStorage, assetId: string, assetType: string): NodeJS.ReadableStream {
    const assetPath = `${assetType}/${assetId}`;
    return assetStorage.readStream(assetPath);
}

//
// Writes an asset from a buffer with a specific asset ID.
// This is used by the REST API server to add assets uploaded via HTTP.
//
export async function writeAsset(
    assetStorage: IStorage,
    sessionId: string,
    assetId: string,
    assetType: string,
    contentType: string,
    buffer: Buffer
): Promise<void> {
    const assetPath = `${assetType}/${assetId}`;

    if (!await acquireWriteLock(assetStorage, sessionId)) {
        throw new Error(`Failed to acquire write lock.`);
    }

    try {
        let merkleTree = await retry(() => loadMerkleTree(assetStorage));
        if (!merkleTree) {
            throw new Error(`Failed to load media file database.`);
        }

        await retry(() => assetStorage.write(assetPath, contentType, buffer));

        const assetInfo = await retry(() => assetStorage.info(assetPath));
        if (!assetInfo) {
            throw new Error(`Failed to get info for file "${assetPath}"`);
        }

        const hashedAsset = await retry(() => computeAssetHash(assetPath, assetInfo, () => assetStorage.readStream(assetPath)));

        await refreshWriteLock(assetStorage, sessionId);

        merkleTree = addItem(merkleTree, {
            name: assetPath,
            hash: hashedAsset.hash,
            length: hashedAsset.length,
            lastModified: hashedAsset.lastModified,
        });

        if (assetType === "asset") {
            if (!merkleTree.databaseMetadata) {
                merkleTree.databaseMetadata = { filesImported: 0 };
            }
            merkleTree.databaseMetadata.filesImported++;
        }

        await retry(() => saveMerkleTree(merkleTree, assetStorage));
    }
    catch (err: any) {
        log.exception(`Failed to add asset "${assetPath}" from buffer`, err);
        await retry(() => assetStorage.deleteFile(assetPath));
        throw err;
    }
    finally {
        await releaseWriteLock(assetStorage);
    }
}

//
// Removes an asset by ID, including all associated files and metadata.
// This is the comprehensive removal method that handles storage cleanup.
//
export async function removeAsset(
    assetStorage: IStorage,
    sessionId: string,
    metadataCollection: IBsonCollection<IAsset>,
    assetId: string
): Promise<void> {
    if (!await acquireWriteLock(assetStorage, sessionId)) {
        throw new Error(`Failed to acquire write lock.`);
    }

    try {
        let merkleTree = await retry(() => loadMerkleTree(assetStorage));
        if (!merkleTree) {
            throw new Error(`Failed to load media file database.`);
        }

        const removed = await metadataCollection.deleteOne(assetId);
        if (removed) {
            if (!merkleTree.databaseMetadata) {
                merkleTree.databaseMetadata = { filesImported: 0 };
            }
            if (merkleTree.databaseMetadata.filesImported > 0) {
                merkleTree.databaseMetadata.filesImported--;
            }
            
            if (!merkleTree.databaseMetadata.deletedAssetIds) {
                merkleTree.databaseMetadata.deletedAssetIds = [];
            }
            if (!merkleTree.databaseMetadata.deletedAssetIds.includes(assetId)) {
                merkleTree.databaseMetadata.deletedAssetIds.push(assetId);
            }
        }

        await assetStorage.deleteFile(pathJoin("asset", assetId));
        await assetStorage.deleteFile(pathJoin("display", assetId));
        await assetStorage.deleteFile(pathJoin("thumb", assetId));

        deleteItem<IDatabaseMetadata>(merkleTree, pathJoin("asset", assetId));
        deleteItem<IDatabaseMetadata>(merkleTree, pathJoin("display", assetId));
        deleteItem<IDatabaseMetadata>(merkleTree, pathJoin("thumb", assetId));

        await retry(() => saveMerkleTree(merkleTree, assetStorage)); 
    }
    finally {
        await releaseWriteLock(assetStorage);
    }    
}

//
// README content for database directories
//
const DATABASE_README_CONTENT = `# Photosphere Database Directory

⚠️  **WARNING: Do not modify any files in this directory manually!**

This directory contains a Photosphere media file database. The files and folders here are managed automatically by the Photosphere CLI tool (\`psi\`).

## Important rules

- **Never edit, delete, or move files in this directory manually**
- **Always use the \`psi\` command-line tool to make changes to your database**
- **Manual modifications can corrupt your database and cause data loss**

## Common operations

To work with your media database, use these commands:

- Add photos/videos: \`psi add <source-directory>\`
- View database summary: \`psi summary\`
- Check database integrity: \`psi verify\`
- Backup/replicate: \`psi replicate --dest <destination>\`
- Compare databases: \`psi compare --dest <other-database>\`

For more help: \`psi --help\`

---
*This file was automatically generated by Photosphere CLI*
`;
