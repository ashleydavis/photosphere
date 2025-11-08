import fs from "fs-extra";
import os from "os";
import path from "path";
import { BsonDatabase, IBsonCollection, IRecord, getDatabaseRootHash } from "bdb";
import type { IBsonDatabase } from "bdb";
import { FileStorage, IStorage, pathJoin, StoragePrefixWrapper } from "storage";
import { validateFile } from "./validation";
import { ILocation, log, retry, reverseGeocode, IUuidGenerator, ITimestampProvider } from "utils";
import dayjs from "dayjs";
import { IAsset } from "defs";
import { Readable } from "stream";
import { getVideoDetails } from "./video";
import { getImageDetails, IResolution } from "./image";
import { computeHash, HashCache } from "adb";
import { FileScanner, IFileStat } from "./file-scanner";

import customParseFormat from "dayjs/plugin/customParseFormat";
dayjs.extend(customParseFormat);

import { Image } from "tools";
import _ from "lodash";
import { acquireWriteLock, refreshWriteLock, releaseWriteLock } from "./write-lock";
import { computeAssetHash } from "./hash";
import { loadMerkleTree, saveMerkleTree, getFilesRootHash } from "./tree";
import { addItem, buildMerkleTree, createTree, deleteItem, IHashedData, combineHashes } from "merkle-tree";

//
// Extract dominant color from thumbnail buffer using ImageMagick
//
async function extractDominantColorFromThumbnail(inputPath: string): Promise<[number, number, number] | undefined> {
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
    
    // Additional metadata can be added here in the future
    [key: string]: any;
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
// Implements the Photosphere media file database.
//
export class MediaFileDatabase {

    //
    // For interacting with the bson database.
    //
    private readonly bsonDatabase: BsonDatabase;

    //
    // For interacting with the metadata collection.
    //
    private readonly metadataCollection: IBsonCollection<IAsset>;

    //
    // The hash cache for the local file system.
    // This is used to speed up the hashing of files that are already known locally.
    //
    private readonly localHashCache: HashCache;

    //
    // The file scanner for scanning directories and files.
    //
    private readonly localFileScanner: FileScanner;

    //
    // The UUID generator for creating asset IDs.
    //
    public readonly uuidGenerator: IUuidGenerator; //todo: Shouldn't be public.

    //
    // The session ID for this instance (used for write lock identification).
    //
    public readonly sessionId: string; //todo: Shouldn't be public.

    //
    // The summary of files added to the database.
    //
    private readonly addSummary: IAddSummary = {
        filesAdded: 0,
        filesAlreadyAdded: 0,
        filesIgnored: 0,
        filesFailed: 0,
        totalSize: 0,
        averageSize: 0,
    };

    constructor(
        private readonly assetStorage: IStorage,
        private readonly metadataStorage: IStorage,
        private readonly googleApiKey: string | undefined,
        uuidGenerator: IUuidGenerator,
        private readonly timestampProvider: ITimestampProvider,
        sessionId?: string
            ) {
        
        const localHashCachePath = path.join(os.tmpdir(), `photosphere`);
        this.localHashCache = new HashCache(new FileStorage(localHashCachePath), localHashCachePath);

        this.bsonDatabase = new BsonDatabase({
            storage: new StoragePrefixWrapper(this.assetStorage, `metadata`),
            uuidGenerator: uuidGenerator,
            timestampProvider: timestampProvider
        });

        this.metadataCollection = this.bsonDatabase.collection("metadata");
        this.localFileScanner = new FileScanner({
            ignorePatterns: [/\.db/]
        });

        // Use the provided UUID generator
        this.uuidGenerator = uuidGenerator;

        // Set session ID for write lock identification
        this.sessionId = sessionId || this.uuidGenerator.generate();
    }

    //
    // Gets the asset storage for reading and writing files.
    //
    getAssetStorage(): IStorage {
        return this.assetStorage;
    }

    //
    // Gets the timestamp provider.
    //
    getTimestampProvider(): ITimestampProvider {
        return this.timestampProvider;
    }

    //
    // Gets the metadata storage for reading and writing metadata.
    //
    getMetadataStorage(): IStorage {
        return this.metadataStorage;
    }

    //
    // Gets the database for reading and writing metadata for assets.
    //
    getMetadataDatabase(): BsonDatabase {
        return this.bsonDatabase;
    }

    //
    // Creates a new media file database.
    //
    async create(): Promise<void> {
        await retry(() => this.localHashCache.load());

        if (!await this.assetStorage.isEmpty("./")) {
            throw new Error(`Cannot create new media file database in ${this.assetStorage.location}. This storage location already contains files! Please create your database in a new empty directory.`);
        }

        let merkleTree = createTree<IDatabaseMetadata>(this.uuidGenerator.generate());
        merkleTree.databaseMetadata = { filesImported: 0 };

        await this.ensureSortIndex();

        // Create README.md file with warning about manual modifications
        await retry(() => this.assetStorage.write('README.md', 'text/markdown', Buffer.from(DATABASE_README_CONTENT, 'utf8')));

        const readmeInfo = await retry(() => this.assetStorage.info('README.md'));
        if (!readmeInfo) {
            throw new Error('README.md file not found after creation.');
        }

        merkleTree = addItem(merkleTree, {
            name: 'README.md',
            hash: await retry(() => computeHash(this.assetStorage.readStream('README.md'))),
            length: readmeInfo.length,
            lastModified: readmeInfo.lastModified,
        });

        await retry(() => saveMerkleTree(merkleTree, this.metadataStorage));

        log.verbose(`Created new media file database.`);
    }

    //
    // Loads the existing media file database.
    //
    async load(): Promise<void> {
        await retry(() => this.localHashCache.load());

        await retry(() => this.metadataCollection.loadSortIndex("hash", "asc", "string"));
        await retry(() => this.metadataCollection.loadSortIndex("photoDate", "desc", "date"));

        log.verbose(`Loaded existing media file database from: ${this.assetStorage.location} / ${this.metadataStorage.location}`);
    }

    //
    // Loads the existing media file database, or creates it if it doesn't exist.
    //
    async loadOrCreate(): Promise<void> {
        const treeExists = await retry(() => this.metadataStorage.fileExists("tree.dat"));
        if (treeExists) {
            await this.load();
        } else {
            await this.create();
        }
    }

    //
    // Ensures the sort index exists.
    //
    async ensureSortIndex() {
        await retry(() => this.metadataCollection.ensureSortIndex("hash", "asc", "string"));
        await retry(() => this.metadataCollection.ensureSortIndex("photoDate", "desc", "date")) ;
    }

    //
    // Gets the summary of files added to the database.
    //
    getAddSummary(): IAddSummary {
        this.addSummary.averageSize = this.addSummary.filesAdded > 0 ? Math.floor(this.addSummary.totalSize / this.addSummary.filesAdded) : 0;
        return this.addSummary;
    }

    //
    // Gets the database hashes (files hash, database hash, and aggregate hash).
    //
    async getDatabaseHashes(): Promise<IDatabaseHashes> {
        // Get root hashes from both merkle trees
        const filesRootHash = await retry(() => getFilesRootHash(this.metadataStorage));
        const databaseRootHash = await retry(() => getDatabaseRootHash(new StoragePrefixWrapper(this.assetStorage, "metadata")));
        
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
    async getDatabaseSummary(): Promise<IDatabaseSummary> {
        const merkleTree = await retry(() => loadMerkleTree(this.metadataStorage));
        if (!merkleTree) {
            throw new Error(`Failed to load merkle tree.`);
        }
        const filesImported = merkleTree.databaseMetadata?.filesImported || 0;
        
        // Get database hashes
        const hashes = await this.getDatabaseHashes();
        
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
    // Gets a BSON collection for database operations
    //
    getCollection<T extends IRecord = IRecord>(name: string): IBsonCollection<T> {
        return this.bsonDatabase.collection<T>(name);
    }

    //
    // Gets the BSON database interface
    //
    getBsonDatabase(): IBsonDatabase {
        return this.bsonDatabase;
    }

    //
    // Adds a list of files or directories to the media file database.
    //
    async addPaths(paths: string[], progressCallback: ProgressCallback): Promise<void> {
        await this.localFileScanner.scanPaths(paths, async (result) => {
            await this.importFile(
                result.filePath,
                result.fileStat,
                result.contentType,
                result.labels,
                result.openStream,
                progressCallback
            );
            
            if (this.addSummary.filesAdded % 100 === 0) { // Save hash caches progressively to make the next run faster.
                await retry(() => this.localHashCache.save()); // Saving hashes locally makes if faster next time.
            }

        }, progressCallback);

        // Update the number of ignored files after scanning
        this.addSummary.filesIgnored += this.localFileScanner.getNumFilesIgnored();

        //
        // Commit any additions that were made.
        //
        await retry(() => this.localHashCache.save()); // Saving hashes locally makes if faster next time.
    }

    //
    // Checks a list of files or directories to find files already added to the media file database.
    //
    async checkPaths(paths: string[], progressCallback: ProgressCallback): Promise<void> {
        await this.localFileScanner.scanPaths(paths, async (result) => {
            await this.checkFile(
                result.filePath,
                result.fileStat,
                result.contentType,
                result.openStream,
                progressCallback
            );
            
            if (this.addSummary.filesAdded % 100 === 0) { // Save hash caches progressively to make the next run faster.
                await retry(() => this.localHashCache.save()); // Saving hashes locally makes if faster next time.
            }

        }, progressCallback);

         await retry(() => this.localHashCache.save()); // Saving hashes locally makes if faster next time.
    }

    //
    // Imports a file to the media file database.
    //
    private importFile = async (filePath: string, fileStat: IFileStat, contentType: string, labels: string[], openStream: (() => NodeJS.ReadableStream) | undefined, progressCallback: ProgressCallback): Promise<void> => {

        const assetId = this.uuidGenerator.generate();

        //
        // Create a temporary directory for generating files like the thumbnail, display asset, etc.
        //
        const assetTempDir = path.join(os.tmpdir(), `photosphere`, `assets`, this.uuidGenerator.generate());
        await fs.ensureDir(assetTempDir);
       
        try {
            let localHashedFile = await this.getHash(filePath, fileStat, this.localHashCache);
            if (!localHashedFile) {
                //
                // Validate, compute and cache the hash of the file.
                //
                localHashedFile = await this.computeLocalHash(filePath, fileStat, contentType, assetTempDir, openStream, progressCallback);
                if (!localHashedFile) {
                    // Failed validation.
                    return;
                }
            }
    
            const metadataCollection = this.bsonDatabase.collection("metadata");
    
            log.verbose(`Checking if file "${filePath}" with hash "${localHashedFile.hash.toString("hex")}" is already in the media file database.`);
    
            const localHashStr = localHashedFile.hash.toString("hex");
            const records = await metadataCollection.findByIndex("hash", localHashStr);
            if (records.length > 0) {
                //
                // The file is already in the database.
                //
                log.verbose(`File "${filePath}" with hash "${localHashStr}", matches existing records:\n  ${records.map(r => r._id).join("\n  ")}`);
                this.addSummary.filesAlreadyAdded++;
                if (progressCallback) {
                    progressCallback(this.localFileScanner.getCurrentlyScanning());
                }
                return;
            }
            
            let assetDetails: IAssetDetails | undefined = undefined;
            
            if (contentType?.startsWith("video")) {
                assetDetails = await getVideoDetails(filePath, assetTempDir, contentType, this.uuidGenerator, openStream);
            }
            else if (contentType?.startsWith("image")) {
                assetDetails = await getImageDetails(filePath, assetTempDir, contentType, this.uuidGenerator, openStream);
            }
    
            const assetPath = `asset/${assetId}`;
            const thumbPath = `thumb/${assetId}`;
            const displayPath = `display/${assetId}`;

            //
            // Acquire the write lock before writing shared files in the database.
            // Ideally we would upload new files before acquiring the lock and then update the merkle tree and BSON database,
            // but the way the code is currently structured is that file uploads and merkle tree changes are intertwined.
            //
            if (!await acquireWriteLock(this.assetStorage, this.sessionId)) {
                throw new Error(`Failed to acquire write lock.`);
            }

            // Simulate failure for testing (10% chance when SIMULATE_FAILURE=add-file)
            // This occurs while holding the write lock to test lock recovery scenarios
            if (process.env.SIMULATE_FAILURE === "add-file" && Math.random() < 0.1) {
                throw new Error(`Simulated failure during add-file operation for ${filePath}`);
            }

            try {
                //
                // Always load the database after acquiring the write lock to ensure we have the latest tree.
                //
                let merkleTree = await retry(() => loadMerkleTree(this.metadataStorage));
                if (!merkleTree) {
                    throw new Error(`Failed to load media file database.`);
                }

                //
                // Uploads the full asset.
                // No write lock is needed to write new assets as the asset UUID is unique.
                //
                await retry(() => this.assetStorage.writeStream(assetPath, contentType, openStream ? openStream() : fs.createReadStream(filePath), fileStat.length));

                const assetInfo = await retry(() => this.assetStorage.info(assetPath));
                if (!assetInfo) {
                    throw new Error(`Failed to get info for file "${assetPath}"`);
                }

                const hashedAsset = await retry(() => computeAssetHash(assetPath, assetInfo, () => this.assetStorage.readStream(assetPath)));
                if (hashedAsset.hash.toString("hex") !== localHashStr) {
                    throw new Error(`Hash mismatch for file "${assetPath}": ${hashedAsset.hash.toString("hex")} != ${localHashStr}`);
                }

                //
                // Refresh the timeout of the write lock.
                //
                await refreshWriteLock(this.assetStorage, this.sessionId);

                //
                // Write lock is needed to update the merkle tree and BSON database.
                //
                merkleTree = addItem(merkleTree, {
                    name: assetPath,
                    hash: hashedAsset.hash,
                    length: hashedAsset.length,
                    lastModified: hashedAsset.lastModified,
                });

                if (assetDetails?.thumbnailPath) {
                    //
                    // Uploads the thumbnail.
                    // No write lock is needed to write new assets as the asset UUID is unique.
                    // Write lock is needed to update the merkle tree and BSON database.
                    //
                    await retry(() => this.assetStorage.writeStream(thumbPath, assetDetails.thumbnailContentType!, fs.createReadStream(assetDetails.thumbnailPath)));

                    const thumbInfo = await retry(() => this.assetStorage.info(thumbPath));
                    if (!thumbInfo) {
                        throw new Error(`Failed to get info for thumbnail "${thumbPath}"`);
                    }
                    const hashedThumb = await retry(() => computeAssetHash(thumbPath, thumbInfo, () => fs.createReadStream(assetDetails.thumbnailPath)));

                    //
                    // Refresh the timeout of the write lock.
                    //
                    await refreshWriteLock(this.assetStorage, this.sessionId);

                    //
                    // Write lock is needed to update the merkle tree and BSON database.
                    //
                    merkleTree = addItem(merkleTree, {
                        name: thumbPath,
                        hash: hashedThumb.hash,
                        length: hashedThumb.length,
                        lastModified: hashedThumb.lastModified,
                    });    
                }

                if (assetDetails?.displayPath) {
                    //
                    // Uploads the display asset.
                    // No write lock is needed to write new assets as the asset UUID is unique.
                    //
                    await retry(() => this.assetStorage.writeStream(displayPath, assetDetails.displayContentType, fs.createReadStream(assetDetails.displayPath!)));

                    const displayInfo = await retry(() => this.assetStorage.info(displayPath));
                    if (!displayInfo) {
                        throw new Error(`Failed to get info for display "${displayPath}"`);
                    }
                    const hashedDisplay = await retry(() => computeAssetHash(displayPath, displayInfo, () => fs.createReadStream(assetDetails.displayPath!)));

                    //
                    // Refresh the timeout of the write lock.
                    //
                    await refreshWriteLock(this.assetStorage, this.sessionId);

                    //
                    // Write lock is needed to update the merkle tree and BSON database.
                    //
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
                    const googleApiKey = this.googleApiKey;
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

                //
                // Read the date of the file.
                //
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

                //
                // Refresh the timeout of the write lock.
                //
                await refreshWriteLock(this.assetStorage, this.sessionId);

                //
                // Add the asset's metadata to the database.
                // Write lock is needed to update the merkle tree and BSON database.
                //
                await this.bsonDatabase.collection("metadata").insertOne({
                    _id: assetId,
                    width: assetDetails?.resolution.width,
                    height: assetDetails?.resolution.height,
                    origFileName: path.basename(filePath),
                    origPath: fileDir,
                    contentType,
                    hash: localHashStr,
                    coordinates,
                    location,
                    duration: assetDetails?.duration,
                    fileDate: dayjs(fileStat.lastModified).toISOString(),
                    photoDate: assetDetails?.photoDate || dayjs(fileStat.lastModified).toISOString(),
                    uploadDate: dayjs(this.timestampProvider.dateNow()).toISOString(),
                    properties,
                    labels,
                    description,
                    micro,
                    color: assetDetails ? await extractDominantColorFromThumbnail(assetDetails.thumbnailPath) : undefined,
                });

                log.verbose(`Added file "${filePath}" to the database with ID "${assetId}".`);

                //
                // Refresh the timeout of the write lock.
                //
                await refreshWriteLock(this.assetStorage, this.sessionId);

                //
                // Increment the imported files count.
                // Write lock is needed to update the merkle tree and BSON database.
                //
                if (!merkleTree.databaseMetadata) {
                    merkleTree.databaseMetadata = { filesImported: 0 };
                }
                merkleTree.databaseMetadata.filesImported++;

                this.addSummary.filesAdded++;
                this.addSummary.totalSize += fileStat.length;
                if (progressCallback) {
                    progressCallback(this.localFileScanner.getCurrentlyScanning());
                }

                //
                // Ensure the tree is saved before releasing the lock.
                //
                await retry(() => saveMerkleTree(merkleTree, this.metadataStorage)); 
            }
            catch (err: any) {
                log.exception(`Failed to upload asset data for file "${filePath}"`, err);

                //
                // If we get here it means something went wrong during the upload or database update.
                // Clean up any files that might have been uploaded.
                // No write lock is needed to delete files as we are deleting by unique asset ID.
                //
                await retry(() => this.assetStorage.deleteFile(assetPath));
                await retry(() => this.assetStorage.deleteFile(thumbPath));
                await retry(() => this.assetStorage.deleteFile(displayPath));

                this.addSummary.filesFailed++;
                if (progressCallback) {
                    progressCallback(this.localFileScanner.getCurrentlyScanning());
                }
            }
            finally {

                //
                // Release the write lock after writing shared files in the database.
                //
                await releaseWriteLock(this.assetStorage);
            }
        }
        finally {            
            //
            // Remove all temporary assets created during the process.
            //
            await retry(() => fs.remove(assetTempDir));
        }
    }

    //
    // Checks if a file has already been added to the media file database.
    //
    private checkFile = async  (filePath: string, fileStat: IFileStat, contentType: string, openStream: (() => NodeJS.ReadableStream) | undefined, progressCallback: ProgressCallback): Promise<void> => {

        let localHashedFile = await this.getHash(filePath, fileStat, this.localHashCache);
        if (!localHashedFile) {          
            const tempDir = path.join(os.tmpdir(), `photosphere`, `check`);
            await fs.ensureDir(tempDir);

            //
            // Validate, compute and cache the hash of the file.
            //
            localHashedFile = await this.computeLocalHash(filePath, fileStat, contentType, tempDir, openStream, progressCallback);
            if (!localHashedFile) {
                // Failed validation.
                return;
            }
        }

        const metadataCollection = this.bsonDatabase.collection("metadata");

        log.verbose(`Checking if file "${filePath}" with hash "${localHashedFile.hash.toString("hex")}" is already in the media file database.`);

        const localHashStr = localHashedFile.hash.toString("hex");
        const records = await metadataCollection.findByIndex("hash", localHashStr);
        if (records.length > 0) {
            //
            // The file is already in the database.
            //
            log.verbose(`File "${filePath}" with hash "${localHashStr}", matches existing records:\n  ${records.map(r => r._id).join("\n  ")}`);
            this.addSummary.filesAlreadyAdded++;
            return;
        }

        log.verbose(`File "${filePath}" has not been added to the media file database.`);

        this.addSummary.filesAdded++;
        this.addSummary.totalSize += fileStat.length;
        if (progressCallback) {
            progressCallback(this.localFileScanner.getCurrentlyScanning());
        }
    }

    //
    // Validates the local file.
    //
    async validateFile(filePath: string, contentType: string, tempDir: string, openStream: (() => NodeJS.ReadableStream) | undefined): Promise<boolean> {
        try {
            return await validateFile(filePath, contentType, tempDir, this.uuidGenerator, openStream);
        }
        catch (error: any) {
            log.error(`File "${filePath}" has failed its validation with error: ${error.message}`);                
            return false;
        }
    }

    //
    // Gets the hash of a file from the hash cache or returns undefined if the file is not in the cache.
    //
    async getHash(filePath: string, fileStat: IFileStat, hashCache: HashCache): Promise<IHashedData | undefined> {
        const cacheEntry = hashCache.getHash(filePath);
        if (cacheEntry) {
            if (cacheEntry.length === fileStat.length && cacheEntry.lastModified.getTime() === fileStat.lastModified.getTime()) {
                // The hash cache entry is valid, so return it.
                // If a hash is commited to the hash cache, the file is assumed to be valid.
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
    // Computes the hash of a local file and stores it in the local hash cache.
    //
    async computeLocalHash(
        filePath: string, 
        fileStat: IFileStat, 
        contentType: string, 
        assetTempDir: string, 
        openStream: (() => NodeJS.ReadableStream) | undefined,
        progressCallback: ProgressCallback
    ): Promise<IHashedData | undefined> {

        if (openStream === undefined) {
            openStream = () => fs.createReadStream(filePath);
        }
        
        //
        // We might not have seen this file before, so we need to validate it.
        //
        if (!await this.validateFile(filePath, contentType, assetTempDir, openStream)) {
            log.error(`File "${filePath}" has failed validation.`);
            this.addSummary.filesFailed++;
            if (progressCallback) {
                progressCallback(this.localFileScanner.getCurrentlyScanning());
            }            
            return undefined;
        }

        //
        // Compute the hash of the file.
        //
        const hash = await computeHash(openStream ? openStream() : fs.createReadStream(filePath));
        const hashedFile: IHashedData = {
            hash,
            lastModified: fileStat.lastModified,
            length: fileStat.length,
        };

        //
        // At the point where we commit the hash to the hash cache, we have tested that the file is valid.
        //
        this.localHashCache.addHash(filePath, hashedFile);

        return hashedFile;
    }

    //
    // Removes an asset by ID, including all associated files and metadata.
    // This is the comprehensive removal method that handles storage cleanup.
    //
    async remove(assetId: string): Promise<void> {

        //
        // Acquire a write lock before modifying shared database state.
        //
        if (!await acquireWriteLock(this.assetStorage, this.sessionId)) {
            throw new Error(`Failed to acquire write lock.`);
        }

        try {
            //
            // Always reload the database after acquiring the write lock to ensure we have the latest tree.
            //
            let merkleTree = await retry(() => loadMerkleTree(this.metadataStorage));
            if (!merkleTree) {
                throw new Error(`Failed to load media file database.`);
            }

            //
            // Remove the asset from the metadata collection and decrement the count.
            //
            const removed = await this.metadataCollection.deleteOne(assetId);
            if (removed) {
                if (!merkleTree.databaseMetadata) {
                    merkleTree.databaseMetadata = { filesImported: 0 };
                }
                if (merkleTree.databaseMetadata.filesImported > 0) {
                    merkleTree.databaseMetadata.filesImported--;
                }
            }

            //
            // We need the write lock for deleting assets only because this also update the merkle tree.
            // If anything fails after deleting the metadata and before deleting
            // these files, they will become "orphaned assets" in our database.
            //
            await this.assetStorage.deleteFile(pathJoin("asset", assetId));
            await this.assetStorage.deleteFile(pathJoin("display", assetId));
            await this.assetStorage.deleteFile(pathJoin("thumb", assetId));

            deleteItem<IDatabaseMetadata>(merkleTree, pathJoin("asset", assetId));
            deleteItem<IDatabaseMetadata>(merkleTree, pathJoin("display", assetId));
            deleteItem<IDatabaseMetadata>(merkleTree, pathJoin("thumb", assetId));

            //
            // Ensure the tree is saved before releasing the lock.
            //
            await retry(() => saveMerkleTree(merkleTree, this.metadataStorage)); 
        }
        finally {
            //
            // Release the write lock after writing shared files in the database.
            //
            await releaseWriteLock(this.assetStorage);
        }    
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
