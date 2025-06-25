import fs from "fs-extra";
import os from "os";
import path from "path";
import { BsonDatabase, FileStorage, IBsonCollection, IFileInfo, IStorage, StoragePrefixWrapper, walkDirectory } from "storage";
import { validateFile } from "./validation";
import { ILocation, log, retry, reverseGeocode, IUuidGenerator, RandomUuidGenerator } from "utils";
import { TestUuidGenerator } from "node-utils";
import dayjs from "dayjs";
import { IAsset } from "defs";
import { Readable } from "stream";
import { getVideoDetails } from "./video";
import { getImageDetails, IResolution } from "./image";
import { addFile, AssetDatabase, AssetDatabaseStorage, computeHash, createTree, HashCache, IHashedFile, MerkleNode, saveTreeV2, traverseTree, visualizeTree } from "adb";
import { FileScanner } from "./file-scanner";

import customParseFormat from "dayjs/plugin/customParseFormat";
dayjs.extend(customParseFormat);

import { Image } from "tools";

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
export type FileValidator = (filePath: string, fileInfo: IFileInfo, contentType: string, openStream?: () => Readable) => Promise<boolean>;

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

export interface IDatabaseSummary {
    //
    // Total number of assets in the database.
    //
    totalAssets: number;

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
}

//
// Interface for the database metadata stored in metadata.json
//
export interface IDatabaseMetadata {
    //
    // Number of files that have been imported into the database.
    //
    filesImported: number;

    //
    // Version of the metadata format.
    //
    version: number;
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
// Options for verifying the media file database.
//
export interface IVerifyOptions {
    //
    // Enables full verification where all files are re-hashed.
    //
    full?: boolean;
}

//
// Result of the verification process.
//
export interface IVerifyResult {
    //
    // The total number of files imported into the database.
    //
    filesImported: number;

    //
    // The total number of files verified (including thumbnails, display, BSON, etc.).
    //
    totalFiles: number;

    //
    // The total database size.
    //
    totalSize: number;

    //
    // The number of files that were unmodified.
    //
    numUnmodified: number;

    //
    // The list of files that were modified.
    //
    modified: string[];

    //
    // The list of new files that were added to the database.
    //
    new: string[];

    //
    // The list of files that were removed from the database.
    //
    removed: string[];
}

//
// Result of the replication process.
//
export interface IReplicationResult {
    //
    // The total number of files imported.
    //
    filesImported: number;

    //
    // The total number of files considered.
    //
    filesConsidered: number;

    //
    // The number of files already existing in the destination storage.
    //
    existingFiles: number;

    //
    // The number of files copied to the destination storage.
    //
    copiedFiles: number;
}


//
// Implements the Photosphere media file database.
//
export class MediaFileDatabase {

    //
    // The storage for the asset files.
    //
    private readonly assetStorage: IStorage;

    //
    // For interacting with the asset database.
    //
    private readonly assetDatabase: AssetDatabase;

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
    // The hash cache contained within the database (possibly remote).
    //
    private readonly databaseHashCache: HashCache;

    //
    // The file scanner for scanning directories and files.
    //
    private readonly localFileScanner: FileScanner;

    //
    // The UUID generator for creating asset IDs.
    //
    private readonly uuidGenerator: IUuidGenerator;

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

    //
    // Database metadata tracking asset count.
    //
    private databaseMetadata: IDatabaseMetadata = {
        filesImported: 0,
        version: 1,
    };

    //
    // Flag to track if database metadata has been modified and needs saving.
    //
    private isDirty: boolean = false;

    constructor(
        assetStorage: IStorage,
        private readonly metadataStorage: IStorage,
        private readonly googleApiKey: string | undefined,
        uuidGenerator: IUuidGenerator
            ) {

        this.assetDatabase = new AssetDatabase(assetStorage, metadataStorage);

        const localHashCachePath = path.join(os.tmpdir(), `photosphere`);
        this.localHashCache = new HashCache(new FileStorage(localHashCachePath), localHashCachePath);
        this.databaseHashCache = new HashCache(metadataStorage, ``);

        // Anything that goes through this.assetStorage automatically updates the merkle tree.
        this.assetStorage = new AssetDatabaseStorage(assetStorage, this.assetDatabase, this.databaseHashCache); 

        this.bsonDatabase = new BsonDatabase({
            storage: new StoragePrefixWrapper(this.assetStorage, `metadata`),
            maxCachedShards: 100,
        });

        this.metadataCollection = this.bsonDatabase.collection("metadata");
        this.localFileScanner = new FileScanner(new FileStorage("fs:"), {
            ignorePatterns: [/\.db/]
        });

        // Use the provided UUID generator
        this.uuidGenerator = uuidGenerator;
    }

    //
    // Gets the asset storage for reading and writing files.
    //
    getAssetStorage(): IStorage {
        return this.assetStorage;
    }

    //
    // Gets the database for reading and writing metadata for assets.
    //
    getMetadataDatabase(): BsonDatabase {
        return this.bsonDatabase;
    }

    //
    // Gets the asset database for accessing the merkle tree.
    //
    getAssetDatabase(): AssetDatabase {
        return this.assetDatabase;
    }

    //
    // Gets the database's hash cache.
    //
    getHashCache(): HashCache {
        return this.databaseHashCache;
    }

    //
    // Loads the database metadata from metadata.json or initializes it.
    //
    private async loadDatabaseMetadata(): Promise<void> {
        try {
            const metadataBuffer = await this.metadataStorage.read("metadata.json");
            if (metadataBuffer) {
                const metadataJson = metadataBuffer.toString('utf8');
                this.databaseMetadata = JSON.parse(metadataJson);
                
                log.verbose(`Loaded database metadata: ${this.databaseMetadata.filesImported} assets`);
            } else {
                // Initialize metadata by counting assets in the assets directory
                await this.initializeDatabaseMetadata();
            }
        } catch (error: any) {
            log.warn(`Failed to load database metadata, initializing: ${error.message}`);
            await this.initializeDatabaseMetadata();
        }
    }

    //
    // Initializes database metadata by counting existing assets.
    //
    private async initializeDatabaseMetadata(): Promise<void> {
        try {
            let filesImported = 0;
            
            // Count files in the assets directory
            for await (const file of walkDirectory(this.assetStorage, "assets", [])) {
                filesImported++;
            }
            
            this.databaseMetadata = {
                filesImported,
                version: 1,
            };
            
            await this.saveDatabaseMetadata();
            log.verbose(`Initialized database metadata with ${filesImported} assets`);
        } catch (error: any) {
            log.warn(`Failed to initialize database metadata: ${error.message}`);
            this.databaseMetadata = { filesImported: 0, version: 1 };
        }
    }

    //
    // Saves the database metadata to metadata.json.
    //
    private async saveDatabaseMetadata(): Promise<void> {
        try {
            const metadataJson = JSON.stringify(this.databaseMetadata, null, 2);
            const metadataPath = "metadata.json";
            const metadataBuffer = Buffer.from(metadataJson, 'utf8');
            
            await this.metadataStorage.write(metadataPath, undefined, metadataBuffer);
            
            log.verbose(`Saved database metadata: ${this.databaseMetadata.filesImported} assets`);
            this.isDirty = false;
        } catch (error: any) {
            log.error(`Failed to save database metadata: ${error.message}`);
        }
    }

    //
    // Increments the asset count.
    //
    private incrementAssetCount(): void {
        this.databaseMetadata.filesImported++;
        this.isDirty = true;
    }

    //
    // Decrements the asset count.
    //
    private decrementAssetCount(): void {
        if (this.databaseMetadata.filesImported > 0) {
            this.databaseMetadata.filesImported--;
            this.isDirty = true;
        }
    }

    //
    // Creates a new media file database.
    //
    async create(): Promise<void> {
        await this.localHashCache.load();
        await this.databaseHashCache.load();

        await this.assetDatabase.create();

        await this.metadataCollection.ensureSortIndex("hash", "asc", "string");
        await this.metadataCollection.ensureSortIndex("photoDate", "desc", "date");

        // Initialize database metadata
        this.databaseMetadata = { filesImported: 0, version: 1 };
        this.isDirty = true;
        await this.saveDatabaseMetadata();

        // Create README.md file with warning about manual modifications
        try {
            await this.assetStorage.write('README.md', 'text/markdown', Buffer.from(DATABASE_README_CONTENT, 'utf8'));
        } catch (error) {
            // Don't fail database creation if README write fails
            log.warn(`Warning: Could not create README.md: ${error instanceof Error ? error.message : 'Unknown error'}`);
        }

        log.verbose(`Created new media file database.`);
    }

    //
    // Loads the existing media file database.
    //
    async load(): Promise<void> {
        await this.localHashCache.load();
        await this.databaseHashCache.load();
        await this.assetDatabase.load();

        await this.metadataCollection.ensureSortIndex("hash", "asc", "string");
        await this.metadataCollection.ensureSortIndex("photoDate", "desc", "date");

        // Load database metadata
        await this.loadDatabaseMetadata();

        log.verbose(`Loaded existing media file database from: ${this.assetStorage.location} / ${this.metadataStorage.location}`);
    }

    //
    // Gets the summary of files added to the database.
    //
    getAddSummary(): IAddSummary {
        this.addSummary.averageSize = this.addSummary.filesAdded > 0 ? Math.floor(this.addSummary.totalSize / this.addSummary.filesAdded) : 0;
        return this.addSummary;
    }

    //
    // Gets a summary of the entire database.
    //
    async getDatabaseSummary(): Promise<IDatabaseSummary> {
        const merkleTree = this.assetDatabase.getMerkleTree();
        const metadata = merkleTree.metadata;
        
        // Get root hash (first node is always the root)
        const rootHash = merkleTree.nodes.length > 0 ? merkleTree.nodes[0].hash : Buffer.alloc(0);
        const fullHash = rootHash.toString('hex');

        return {
            totalAssets: this.databaseMetadata.filesImported,
            totalFiles: metadata.totalFiles,
            totalSize: metadata.totalSize,
            totalNodes: metadata.totalNodes,
            fullHash
        };
    }

    //
    // Visualizes the merkle tree structure
    //
    visualizeMerkleTree(): string {
        return visualizeTree(this.assetDatabase.getMerkleTree());
    }

    //
    // Adds a list of files or directories to the media file database.
    //
    async addPaths(paths: string[], progressCallback: ProgressCallback): Promise<void> {
        await this.localFileScanner.scanPaths(paths, async (result) => {
            await this.addFile(
                result.filePath,
                result.fileInfo,
                result.contentType,
                result.labels,
                result.openStream,
                progressCallback
            );

            // Save hash caches progressively to make the next run faster
            if (this.addSummary.filesAdded % 100 === 0) {
                await this.localHashCache.save();
                await this.databaseHashCache.save();
                await this.assetDatabase.save();
            }
        }, progressCallback);

        // Update the number of ignored files after scanning
        this.addSummary.filesIgnored += this.localFileScanner.getNumFilesIgnored();
    }

    //
    // Checks a list of files or directories to find files already added to the media file database.
    //
    async checkPaths(paths: string[], progressCallback: ProgressCallback): Promise<void> {
        await this.localFileScanner.scanPaths(paths, async (result) => {
            await this.checkFile(
                result.filePath,
                result.fileInfo,
                result.openStream,
                progressCallback
            );
        }, progressCallback);
    }


    //
    // Adds a file to the media file database.
    //
    private addFile = async (filePath: string, fileInfo: IFileInfo, contentType: string, labels: string[], openStream: (() => Readable) | undefined, progressCallback: ProgressCallback): Promise<void> => {

        let localHashedFile = await this.getHash(filePath, fileInfo, this.localHashCache);
        if (localHashedFile) {
            //
            // Already hashed, which means the file is valid.
            //
        }
        else {
            //
            // We might not have seen this file before, so we need to validate it.
            //
            if (!await this.validateFile(filePath, fileInfo, contentType, openStream)) {
                log.error(`File "${filePath}" has failed validation.`);
                this.addSummary.filesFailed++;
                if (progressCallback) {
                    progressCallback(this.localFileScanner.getCurrentlyScanning());
                }            
                return;
            }

            //
            // Compute (and cache) the hash of the file.
            //
            localHashedFile = await this.computeHash(filePath, fileInfo, openStream, this.localHashCache);
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

        const assetId = this.uuidGenerator.generate();

        let assetDetails: IAssetDetails | undefined = undefined;
        
        //
        // Create a temporary directory for generates files like the thumbnail, display asset, etc.
        //
        const assetTempDir = path.join(os.tmpdir(), `photosphere`, `assets`, this.uuidGenerator.generate());
        await fs.ensureDir(assetTempDir);

        if (contentType?.startsWith("video")) {
            assetDetails = await getVideoDetails(filePath, assetTempDir, contentType, openStream);
        }
        else if (contentType?.startsWith("image")) {
            assetDetails = await getImageDetails(filePath, assetTempDir, contentType, openStream);
        }

        const assetPath = `assets/${assetId}`;
        const thumbPath = `thumb/${assetId}`;
        const displayPath = `display/${assetId}`;

        try {
            //
            // Uploads the full asset.
            //
            await retry(() => this.assetStorage.writeStream(assetPath, contentType, openStream ? openStream() : fs.createReadStream(filePath), fileInfo.length));

            const assetInfo = await this.assetStorage.info(assetPath);
            if (!assetInfo) {
                throw new Error(`Failed to get info for file "${assetPath}"`);
            }
            
            const hashedAsset = await this.computeHash(assetPath, assetInfo, () => this.assetStorage.readStream(assetPath), this.databaseHashCache);
            if (hashedAsset.hash.toString("hex") !== localHashStr) {
                throw new Error(`Hash mismatch for file "${assetPath}": ${hashedAsset.hash.toString("hex")} != ${localHashStr}`);
            }
            await this.assetDatabase.addFile(assetPath, hashedAsset);

            if (assetDetails?.thumbnailPath) {
                //
                // Uploads the thumbnail.
                //
                await retry(() => this.assetStorage.writeStream(thumbPath, assetDetails.thumbnailContentType!, fs.createReadStream(assetDetails.thumbnailPath)));

                const thumbInfo = await this.assetStorage.info(thumbPath);
                if (!thumbInfo) {
                    throw new Error(`Failed to get info for thumbnail "${thumbPath}"`);
                }
                const hashedThumb = await this.computeHash(thumbPath, thumbInfo, () => fs.createReadStream(assetDetails.thumbnailPath), this.databaseHashCache);
                await this.assetDatabase.addFile(thumbPath, hashedThumb);
            }

            if (assetDetails?.displayPath) {
                //
                // Uploads the display asset.
                //
                await retry(() => this.assetStorage.writeStream(displayPath, assetDetails.displayContentType, fs.createReadStream(assetDetails.displayPath!)));

                const displayInfo = await this.assetStorage.info(displayPath);
                if (!displayInfo) {
                    throw new Error(`Failed to get info for display "${displayPath}"`);
                }
                const hashedDisplay = await this.computeHash(displayPath, displayInfo, () => fs.createReadStream(assetDetails.displayPath!), this.databaseHashCache);
                await this.assetDatabase.addFile(displayPath, hashedDisplay);
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
                ? (await fs.promises.readFile(assetDetails.microPath)).toString("base64")
                : undefined;

            const color = assetDetails 
                ? await extractDominantColorFromThumbnail(assetDetails.thumbnailPath) 
                : undefined;

            //
            // Add the asset's metadata to the database.
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
                fileDate: dayjs(fileInfo.lastModified).toISOString(),
                photoDate: assetDetails?.photoDate || dayjs(fileInfo.lastModified).toISOString(),
                uploadDate: dayjs().toISOString(),
                properties,
                labels,
                description,
                micro,
                color: assetDetails ? await extractDominantColorFromThumbnail(assetDetails.thumbnailPath) : undefined,
            });

            log.verbose(`Added file "${filePath}" to the database with ID "${assetId}".`);

            // Increment asset count in metadata
            this.incrementAssetCount();

            this.addSummary.filesAdded++;
            this.addSummary.totalSize += fileInfo.length;
            if (progressCallback) {
                progressCallback(this.localFileScanner.getCurrentlyScanning());
            }
        }
        catch (err: any) {
            log.exception(`Failed to upload asset data for file "${filePath}"`, err);

            await this.assetStorage.deleteFile(assetPath);
            await this.assetStorage.deleteFile(thumbPath);
            await this.assetStorage.deleteFile(displayPath);

            this.addSummary.filesFailed++;
            if (progressCallback) {
                progressCallback(this.localFileScanner.getCurrentlyScanning());
            }
        }
        finally {
            //
            // Remove all temporary assets created during the process.
            //
            await fs.remove(assetTempDir);
        }
    }

    //
    // Checks if a file has already been added to the media file database.
    //
    private checkFile = async  (filePath: string, fileInfo: IFileInfo, openStream: (() => Readable) | undefined, progressCallback: ProgressCallback): Promise<void> => {

        let localHashedFile = await this.getHash(filePath, fileInfo, this.localHashCache);
        if (!localHashedFile) {            
            localHashedFile = await this.computeHash(filePath, fileInfo, openStream, this.localHashCache);
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
        this.addSummary.totalSize += fileInfo.length;
        if (progressCallback) {
            progressCallback(this.localFileScanner.getCurrentlyScanning());
        }
    }

    //
    // Closes the database.
    //
    async close(): Promise<void> {
        await this.localHashCache.save();
        await this.bsonDatabase.close();
        await this.assetDatabase.close();

        //
        // NOTE:    We save the database hash cache last 
        //          because closing the database can flush 
        //          changes to files that should be updated 
        //          in the hash cache.
        //
        await this.databaseHashCache.save();
        
        // Save database metadata only if it has been modified
        if (this.isDirty) {
            await this.saveDatabaseMetadata();
        }
    }

    //
    // Validates the local file.
    //
    async validateFile(filePath: string, fileInfo: IFileInfo, contentType: string, openStream: (() => Readable) | undefined): Promise<boolean> {
        try {
            return await validateFile(filePath, fileInfo, contentType, openStream);
        }
        catch (error: any) {
            log.error(`File "${filePath}" has failed its validation with error: ${error.message}`);                
            return false;
        }
    }

    // async getHash(filePath: string): Promise<IHashedFile | undefined> {

    // }

    //
    // Gets the hash of a file from the hash cache or returns undefined if the file is not in the cache.
    //
    async getHash(filePath: string, fileInfo: IFileInfo, hashCache: HashCache): Promise<IHashedFile | undefined> {
        const cacheEntry = hashCache.getHash(filePath);
        if (cacheEntry) {
            if (cacheEntry.length === fileInfo.length && cacheEntry.lastModified.getTime() === fileInfo.lastModified.getTime()) {
                // The hash cache entry is valid, so return it.
                // If a hash is commited to the hash cache, the file is assumed to be valid.
                return {
                    hash: cacheEntry.hash,
                    lastModified: fileInfo.lastModified,
                    length: fileInfo.length,
                }
            }
        }

        return undefined;
    }

    //
    // Computes the has h of a file and stores it in the hash cache.
    //
    async computeHash(filePath: string, fileInfo: IFileInfo, openStream: (() => Readable) | undefined, hashCache: HashCache): Promise<IHashedFile> {
        //
        // Compute the hash of the file.
        //
        const hash = await computeHash(openStream ? openStream() : fs.createReadStream(filePath));
        const hashedFile: IHashedFile = {
            hash,
            lastModified: fileInfo.lastModified,
            length: fileInfo.length,
        };

        //
        // At the point where we commit the hash to the hash cache, we have tested that the file is valid.
        //
        hashCache.addHash(filePath, hashedFile);

        return hashedFile;
    }

    //
    // Verifies the media file database.
    // Checks for missing files, modified files, and new files.
    // If any files are corrupted, this will pick them up as modified.
    //
    async verify(options?: IVerifyOptions, progressCallback?: ProgressCallback) : Promise<IVerifyResult> {

        const summary = await this.getDatabaseSummary();
        const result: IVerifyResult = {
            filesImported: this.databaseMetadata.filesImported,
            totalFiles: summary.totalFiles,
            totalSize: summary.totalSize,
            numUnmodified: 0,
            modified: [],
            new: [],
            removed: [],
        };

        //
        // Check all files in the database to find new and modified files.
        //
        let filesProcessed = 0;
        for await (const file of walkDirectory(this.assetStorage, "", [/\.db/])) {
            filesProcessed++;

            if (progressCallback) {
                progressCallback(`Verified file ${filesProcessed} of ${summary.totalFiles}`);
            }

            const fileInfo = await this.assetStorage.info(file.fileName);
            if (!fileInfo) {
                // The file doesn't exist in the storage.
                // This shouldn't happen because we literally just walked the directory..
                log.warn(`File "${file.fileName}" is missing, even though we just found it by walking the directory.`);
                continue;
            }


            const fileHash = this.databaseHashCache.getHash(file.fileName);
            if (!fileHash) {
                result.new.push(file.fileName);
                continue;
            }

            if (fileHash.length !== fileInfo.length  // File size doesn't match, indicating the file has changed.
                || fileHash.lastModified.getTime() !== fileInfo.lastModified.getTime()) { // File has been modified.
                // File metadata has changed - check if content actually changed by computing the hash.
                const freshHash = await this.computeHash(file.fileName, fileInfo, () => this.assetStorage.readStream(file.fileName), this.databaseHashCache);
                if (freshHash.hash.toString("hex") !== fileHash.hash.toString("hex")) {
                    // The file content has actually been modified.
                    result.modified.push(file.fileName);
                } else {
                    // Content is the same, just metadata changed - cache is already updated by computeHash
                    result.numUnmodified++;
                }
            }
            else if (options?.full) {
                // The file doesn't seem to have changed, but the full verification is requested.
                const freshHash = await this.computeHash(file.fileName, fileInfo, () => this.assetStorage.readStream(file.fileName), this.databaseHashCache);
                if (freshHash.hash.toString("hex") === fileHash.hash.toString("hex")) {
                    // The file is unmodified.
                    result.numUnmodified++;
                }
                else {
                    // The file has been modified.
                    result.modified.push(file.fileName);
                }
            }
            else {
                result.numUnmodified++;
            }
        }

        //
        // Check the merkle tree to find files that have been removed.
        //
        if (progressCallback) {
            progressCallback(`Checking for removed files...`);
        }

        let numNodes = 0;
        
        await traverseTree(this.assetDatabase.getMerkleTree(), async (node) => {
            numNodes++;

            if (progressCallback) {
                progressCallback(`Node ${numNodes} of ${summary.totalNodes}`);
            }

            if (node.fileName && !node.isDeleted) {
                if (!await this.assetStorage.fileExists(node.fileName)) {
                    // The file is missing from the storage, but it exists in the merkle tree.
                    result.removed.push(node.fileName);
                }
            }

            return true;
        });
       

        return result;
    }

    //
    // Replicates the media file database to another storage.
    //
    async replicate(destAssetStorage: IStorage, destMetadataStorage: IStorage, progressCallback?: ProgressCallback): Promise<IReplicationResult> {

        const result: IReplicationResult = {
            filesImported: this.databaseMetadata.filesImported,
            filesConsidered: 0,
            existingFiles: 0,
            copiedFiles: 0,
        };

        const srcStorage = this.assetStorage;

        const destHashCache = new HashCache(destMetadataStorage, "");
        await destHashCache.load();

        let newDestTree = createTree();

        //
        // Copies an asset from the source storage to the destination storage.
        // But only when necessary.
        //
        async function copyAsset(fileName: string, sourceHash: Buffer): Promise<void> {
            result.filesConsidered++;
            
            const destHash = destHashCache.getHash(fileName);
            if (destHash) {
                //
                // The file already exists in the destination database.
                // Check if the hash matches. Compare the buffers.
                //
                if (Buffer.compare(sourceHash, destHash.hash) === 0) {
                    //
                    // The hash matches, so we don't need to copy the file.
                    //
                    result.existingFiles++;

                    //
                    // Add the existing file to the destination merkle tree.
                    //
                    newDestTree = addFile(newDestTree, {
                        fileName,
                        hash: destHash.hash,
                        length: destHash.length,
                    });

                    return;                
                }
            }

            const srcFileInfo = await srcStorage.info(fileName);
            if (!srcFileInfo) {
                throw new Error(`Source file "${fileName}" does not exist in the source database.`);
            }

            //
            // Copy the file from source to dest.
            //
            const readStream = srcStorage.readStream(fileName);
            await destAssetStorage.writeStream(fileName, srcFileInfo.contentType, readStream);

            //
            // Compute hash for the copied file.
            //
            const copiedHash = await computeHash(destAssetStorage.readStream(fileName));
            if (Buffer.compare(copiedHash, sourceHash) !== 0) {
                throw new Error(
`Copied file "${fileName}" hash does not match the source hash.
    Source hash: ${sourceHash.toString("hex")}
    Copied hash: ${copiedHash.toString("hex")}
`);
            }

            //
            // Get the info for the copied file.
            //
            const copiedFileInfo = await destAssetStorage.info(fileName);
            if (!copiedFileInfo) {
                throw new Error(`Failed to read dest info for file: ${fileName}`);
            }

            //
            // Add the file to the destination hash cache.
            //
            destHashCache.addHash(fileName, {
                hash: copiedHash,
                lastModified: copiedFileInfo.lastModified,
                length: copiedFileInfo.length,
            });

            //
            // Add the file to the destination merkle tree.
            //
            newDestTree = addFile(newDestTree, {
                fileName,
                hash: copiedHash,
                length: copiedFileInfo.length,
            });

            result.copiedFiles++;

            if (progressCallback) {
                progressCallback(`Copied ${result.copiedFiles} | Already copied ${result.existingFiles}`);
            }
        }

        //
        // Process a node in the soure merkle tree.
        //
        async function processSrcNode(srcNode: MerkleNode): Promise<boolean> {
            if (srcNode.fileName && !srcNode.isDeleted) {               
                await retry(() => copyAsset(srcNode.fileName!, srcNode.hash));

                if (result.copiedFiles % 100 === 0) {
                    await retry(() => destHashCache.save());
                }
            }
            return true; // Continue traversing.
        }

        await traverseTree(this.assetDatabase.getMerkleTree(), processSrcNode);

        await destHashCache.save();

        await saveTreeV2("tree.dat", newDestTree, destMetadataStorage);   
        
        const metadataJson = JSON.stringify(this.databaseMetadata, null, 2);
        const metadataBuffer = Buffer.from(metadataJson, 'utf8');
        await destMetadataStorage.write("metadata.json", undefined, metadataBuffer);
        
        return result;
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
