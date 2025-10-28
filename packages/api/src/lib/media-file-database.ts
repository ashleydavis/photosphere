import fs from "fs-extra";
import os from "os";
import path from "path";
import { BsonDatabase, IBsonCollection, IRecord } from "bdb";
import type { IBsonDatabase } from "bdb";
import { createStorage, FileStorage, IStorage, loadEncryptionKeys, pathJoin, StoragePrefixWrapper } from "storage";
import { validateFile } from "./validation";
import { ILocation, log, retry, reverseGeocode, IUuidGenerator, ITimestampProvider, sleep } from "utils";
import dayjs from "dayjs";
import { IAsset } from "defs";
import { Readable } from "stream";
import { getVideoDetails } from "./video";
import { getImageDetails, IResolution } from "./image";
import { computeHash, getItemInfo, HashCache, traverseTree, IMerkleTree, visualizeTree, IHashedData, SortNode, buildMerkleTree, createTree, loadTree, saveTree, upsertItem, deleteItem } from "adb";
import { FileScanner, IFileStat } from "./file-scanner";

import customParseFormat from "dayjs/plugin/customParseFormat";
dayjs.extend(customParseFormat);

import { Image } from "tools";
import _ from "lodash";
import { acquireWriteLock, refreshWriteLock, releaseWriteLock } from "./write-lock";
import { computeAssetHash } from "./hash";

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
// Options for the replication process.
//
export interface IReplicateOptions {
    //
    // Path filter to only replicate files matching this path (file or directory).
    //
    pathFilter?: string;
}

//
// Implements the Photosphere media file database.
//
export class MediaFileDatabase {

    //
    // The merkle tree that helps protect against corruption.
    //
    private merkleTree: IMerkleTree<IDatabaseMetadata> | undefined = undefined;

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
    private readonly uuidGenerator: IUuidGenerator;

    //
    // The session ID for this instance (used for write lock identification).
    //
    public readonly sessionId: string;

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
            uuidGenerator: uuidGenerator
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
    // Gets the merkle tree.
    //
    getMerkleTree(): IMerkleTree<IDatabaseMetadata> {
        if (!this.merkleTree) {
            throw new Error("Cannot access merkle tree. No database loaded.");
        }
        return this.merkleTree;
    }

    //
    // Adds a file to the merkle tree (public method for external use like sync).
    //
    addFile(filePath: string, hashedFile: IHashedData): void {
        if (!this.merkleTree) {
            throw new Error("Cannot add file to database. No database loaded.");
        }

        if (filePath.startsWith("metadata/")) {
            return;
        }
        
        this.merkleTree = upsertItem(this.merkleTree, {
            name: filePath,
            hash: hashedFile.hash,
            length: hashedFile.length,
            lastModified: hashedFile.lastModified,
        });
    }

    //
    // Saves the merkle tree (public method for external use like sync).
    //
    async save(): Promise<void> {
        await this.saveMerkleTree();
    }

    //
    // Saves the merkle tree to disk.
    //
    private async saveMerkleTree(): Promise<void> {
        if (!this.merkleTree) {
            throw new Error("Cannot save database. No database loaded.");
        }

        if (this.merkleTree.dirty) {
            this.merkleTree.merkle = buildMerkleTree(this.merkleTree.sort);
            this.merkleTree.dirty = false;
        }

        await saveTree("tree.dat", this.merkleTree, this.metadataStorage);
    }

    //
    // Loads the merkle tree from disk.
    //
    async loadMerkleTree(): Promise<boolean> {
        this.merkleTree = await loadTree("tree.dat", this.metadataStorage);
        if (!this.merkleTree) {
            return false;
        }

        return true;
    }

    //
    // Deletes a file from the merkle tree.
    //
    private deleteFile(filePath: string): void {
        if (!this.merkleTree) {
            throw new Error("Cannot delete file from database. No database loaded.");
        }

        if (filePath.startsWith("metadata/")) {
            return;
        }

        deleteItem<IDatabaseMetadata>(this.merkleTree, filePath);
    }


    //
    // Increments the asset count.
    //
    private incrementAssetCount(): void {
        const merkleTree = this.getMerkleTree();
        if (!merkleTree.databaseMetadata) {
            merkleTree.databaseMetadata = { filesImported: 0 };
        }
        merkleTree.databaseMetadata.filesImported++;
    }

    //
    // Decrements the asset count.
    //
    private decrementAssetCount(): void {
        const merkleTree = this.getMerkleTree();
        if (!merkleTree.databaseMetadata) {
            merkleTree.databaseMetadata = { filesImported: 0 };
        }
        if (merkleTree.databaseMetadata.filesImported > 0) {
            merkleTree.databaseMetadata.filesImported--;
        }
    }

    //
    // Creates a new media file database.
    //
    async create(): Promise<void> {
        await retry(() => this.localHashCache.load());

        if (!await this.assetStorage.isEmpty("./")) {
            throw new Error(`Cannot create new media file database in ${this.assetStorage.location}. This storage location already contains files! Please create your database in a new empty directory.`);
        }

        this.merkleTree = createTree(this.uuidGenerator.generate());
        this.merkleTree.databaseMetadata = { filesImported: 0 };

        await this.ensureSortIndex();

        // Create README.md file with warning about manual modifications
        await retry(() => this.assetStorage.write('README.md', 'text/markdown', Buffer.from(DATABASE_README_CONTENT, 'utf8')));

        const readmeInfo = await retry(() => this.assetStorage.info('README.md'));
        if (!readmeInfo) {
            throw new Error('README.md file not found after creation.');
        }

        this.addFile('README.md', {
            hash: await retry(() => computeHash(this.assetStorage.readStream('README.md'))),
            length: readmeInfo.length,
            lastModified: readmeInfo.lastModified,
        });

        await retry(() => this.saveMerkleTree());

        log.verbose(`Created new media file database.`);
    }

    //
    // Loads the existing media file database.
    //
    async load(): Promise<void> {
        await retry(() => this.localHashCache.load());
        if (!await retry(() => this.loadMerkleTree())) {
            throw new Error(`Failed to load media file database.`);
        }

        await retry(() => this.metadataCollection.loadSortIndex("hash", "asc", "string"));
        await retry(() => this.metadataCollection.loadSortIndex("photoDate", "desc", "date"));

        log.verbose(`Loaded existing media file database from: ${this.assetStorage.location} / ${this.metadataStorage.location}`);
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
    // Gets a summary of the entire database.
    //
    async getDatabaseSummary(): Promise<IDatabaseSummary> {
        const merkleTree = this.getMerkleTree();
        const filesImported = merkleTree.databaseMetadata?.filesImported || 0;
        if (merkleTree.dirty || !merkleTree.merkle) {
            log.warn(`Merkle tree is dirty or missing, will rebuild.`);
        }
        const merkle = !merkleTree.dirty && merkleTree.merkle || buildMerkleTree(merkleTree.sort);
        
        // Get root hash (first node is always the root)
        const rootHash = merkle?.hash;
        const fullHash = rootHash?.toString('hex');
        
        return {
            totalImports: filesImported,
            totalFiles: merkleTree.sort?.leafCount || 0,
            totalSize: merkleTree.sort?.size || 0,
            totalNodes: merkleTree.sort?.nodeCount || 0,
            fullHash: fullHash || 'empty',
            databaseVersion: merkleTree.version
        };
    }

    //
    // Visualizes the merkle tree structure
    //
    visualizeMerkleTree(): string {
        return visualizeTree(this.getMerkleTree());
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

            //
            // Always reload the database after acquiring the write lock to ensure we have the latest tree.
            //
            if (!await this.loadMerkleTree()) {
                throw new Error(`Failed to load asset database after acquiring write lock.`);
            }

            // Simulate failure for testing (10% chance when SIMULATE_FAILURE=add-file)
            // This occurs while holding the write lock to test lock recovery scenarios
            if (process.env.SIMULATE_FAILURE === "add-file" && Math.random() < 0.1) {
                throw new Error(`Simulated failure during add-file operation for ${filePath}`);
            }

            try {
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
                this.addFile(assetPath, hashedAsset);

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
                    this.addFile(thumbPath, hashedThumb);
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
                    this.addFile(displayPath, hashedDisplay);
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
                this.incrementAssetCount();

                this.addSummary.filesAdded++;
                this.addSummary.totalSize += fileStat.length;
                if (progressCallback) {
                    progressCallback(this.localFileScanner.getCurrentlyScanning());
                }

                //
                // Ensure the tree is saved before releasing the lock.
                //
                await retry(() => this.saveMerkleTree()); 
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
    // Loads or creates the merkle tree.
    //
    private async loadOrCreateMerkleTree(metadataStorage: IStorage): Promise<IMerkleTree<IDatabaseMetadata>> {
        let merkleTree = await retry(() => loadTree<IDatabaseMetadata>("tree.dat", metadataStorage));
        if (!merkleTree) {
            merkleTree = createTree(this.uuidGenerator.generate());
        }
        return merkleTree;
    }

    //
    // Replicates the media file database to another storage.
    //
    async replicate(destAssetStorage: IStorage, destMetadataStorage: IStorage, options?: IReplicateOptions, progressCallback?: ProgressCallback): Promise<IReplicationResult> {

        const merkleTree = this.getMerkleTree();
        const filesImported = merkleTree.databaseMetadata?.filesImported || 0;

        const result: IReplicationResult = {
            filesImported,
            filesConsidered: 0,
            existingFiles: 0,
            copiedFiles: 0,
        };

        //
        // Load the destination database, or create it if it doesn't exist.
        //
        let destMerkleTree = await this.loadOrCreateMerkleTree(destMetadataStorage);
        
        //
        // Copy database metadata from source to destination.
        //
        if (merkleTree.databaseMetadata) {
            destMerkleTree.databaseMetadata = { ...merkleTree.databaseMetadata };
        }

        //
        // Copies an asset from the source storage to the destination storage.
        // But only when necessary.
        //
        const copyAsset = async (fileName: string, sourceHash: Buffer): Promise<void> => {
            result.filesConsidered++;
            
            // Check if file already exists in destination tree with matching hash.
            const destFileInfo = getItemInfo(destMerkleTree!, fileName);
            if (destFileInfo && Buffer.compare(destFileInfo.hash, sourceHash) === 0) {
                // File already exists with correct hash, skip copying.
                // This assumes the file is non-corrupted. To find corrupted files, a verify would be needed.
                result.existingFiles++;
                if (progressCallback) {
                    progressCallback(`Copied ${result.copiedFiles} | Already copied ${result.existingFiles}`);
                }
                return;
            }

            const srcFileInfo = await retry(() => this.assetStorage.info(fileName));
            if (!srcFileInfo) {
                throw new Error(`Source file "${fileName}" does not exist in the source database.`);
            }

            //
            // Copy the file from source to dest.
            //
            await retry(async  () => {
                const readStream = this.assetStorage.readStream(fileName);
                await destAssetStorage.writeStream(fileName, srcFileInfo.contentType, readStream);
            });

            //
            // Compute hash for the copied file.
            //
            const copiedHash = await retry(() => computeHash(destAssetStorage.readStream(fileName)));
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
            const copiedFileInfo = await retry(() => destAssetStorage.info(fileName));
            if (!copiedFileInfo) {
                throw new Error(`Failed to read dest info for file: ${fileName}`);
            }

            //
            // Add or update the file in the destination merkle tree.
            //
            if (!fileName.startsWith("metadata/")) {
                destMerkleTree = upsertItem(destMerkleTree!, {
                    name: fileName,
                    hash: copiedHash,
                    length: copiedFileInfo.length,
                    lastModified: copiedFileInfo.lastModified,
                });
            }

            result.copiedFiles++;

            if (progressCallback) {
                progressCallback(`Copied ${result.copiedFiles} | Already copied ${result.existingFiles}`);
            }
        };

        //
        // Process a node in the soure merkle tree.
        //
        const processSrcNode = async (srcNode: SortNode): Promise<boolean> => {
            if (srcNode.name) {
                // Skip files that don't match the path filter
                if (options?.pathFilter) {
                    const pathFilter = options.pathFilter.replace(/\\/g, '/'); // Normalize path separators
                    const fileName = srcNode.name.replace(/\\/g, '/');
                    
                    // Check if the file matches the filter (exact match or starts with filter + '/')
                    if (fileName !== pathFilter && !fileName.startsWith(pathFilter + '/')) {
                        return true; // Continue traversal
                    }
                }
                                
                await retry(() => copyAsset(srcNode.name!, srcNode.contentHash!));

                if (result.copiedFiles % 100 === 0) {
                    // Save the destination merkle tree periodically
                    await retry(async () => {
                        if (destMerkleTree.dirty) {
                            destMerkleTree.merkle = buildMerkleTree(destMerkleTree.sort);
                            destMerkleTree.dirty = false;
                        }
                        await saveTree("tree.dat", destMerkleTree, destMetadataStorage);
                    });
                }
            }
            return true; // Continue traversing.
        };

        await traverseTree(merkleTree, processSrcNode);

        //
        // Saves the dest database.
        //
        await retry(async () => {
            if (destMerkleTree.dirty) {
                destMerkleTree.merkle = buildMerkleTree(destMerkleTree.sort);
                destMerkleTree.dirty = false;
            }
            await saveTree("tree.dat", destMerkleTree, destMetadataStorage);
        });
        
        return result;
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

        //
        // Always reload the database after acquiring the write lock to ensure we have the latest tree.
        //
        if (!await this.loadMerkleTree()) {
            throw new Error(`Failed to load asset database after acquiring write lock.`);
        }

        try {
            //
            // Remove the asset from the metadata collection and decrement the count.
            //
            const removed = await this.metadataCollection.deleteOne(assetId);
            if (removed) {
                this.decrementAssetCount();
            }

            //
            // We need the write lock for deleting assets only because this also update the merkle tree.
            // If anything fails after deleting the metadata and before deleting
            // these files, they will become "orphaned assets" in our database.
            //
            await this.assetStorage.deleteFile(pathJoin("asset", assetId));
            await this.assetStorage.deleteFile(pathJoin("display", assetId));
            await this.assetStorage.deleteFile(pathJoin("thumb", assetId));

            //
            // Remove files from the merkle tree.
            //
            this.deleteFile(pathJoin("asset", assetId));
            this.deleteFile(pathJoin("display", assetId));
            this.deleteFile(pathJoin("thumb", assetId));

            //
            // Ensure the tree is saved before releasing the lock.
            //
            await retry(() => this.saveMerkleTree()); 
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
