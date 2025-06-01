import fs from "fs";
import fsPromises from "fs/promises";
import os from "os";
import path from "path";
import { BsonDatabase, FileStorage, IBsonCollection, IFileInfo, IStorage, StoragePrefixWrapper, walkDirectory } from "storage";
import { validateFile } from "./validation";
import mime from "mime";
import { ILocation, ILog, log, retry, reverseGeocode, uuid, WrappedError } from "utils";
import dayjs from "dayjs";
import { IAsset } from "defs";
import { Readable } from "stream";
import { getVideoDetails } from "./video";
import { getImageDetails } from "./image";
import { IResolution } from "node-utils";
import JSZip from "jszip";
import { buffer } from "node:stream/consumers";
import { AssetDatabase, AssetDatabaseStorage, computeHash, HashCache, IHashedFile } from "adb";

import customParseFormat from "dayjs/plugin/customParseFormat";
dayjs.extend(customParseFormat);

// @ts-ignore
import ColorThief from "colorthief";

//
// A function that validates a file.
//
export type FileValidator = (filePath: string, fileInfo: IFileInfo, contentType: string, openStream: () => Readable) => Promise<boolean>;

//
// Progress callback for the add operation.
//
export type ProgressCallback = (currentlyScanning: string | undefined) => void;

//
// Callback for visiting a file when scanning a directory or zip file.
//
type VisitFileCallback = (filePath: string, fileInfo: IFileInfo, fileDate: Date, contentType: string, labels: string[], openStream: () => Readable, progressCallback: ProgressCallback) => Promise<void>;

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

export interface IAddSummary {
    //
    // The number of files added to the database.
    //
    numFilesAdded: number;

    //
    // The number of files already in the database.
    //
    numFilesAlreadyAdded: number;

    //
    // The number of files ignored (because they are not media files).
    //
    numFilesIgnored: number;

    //
    // The number of files that failed to be added to the database.
    //
    numFilesFailed: number;

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
    // The micro thumbnail of the image/video.
    //
    micro: Buffer;

    //
    // The thumbnail of the image/video.
    //
    thumbnail: Buffer;

    //
    // The content type of the thumbnail.
    //
    thumbnailContentType: string;

    //
    // The display image.
    //
    display?: Buffer;

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
    // The summary of files added to the database.
    //
    private readonly addSummary: IAddSummary = {
        numFilesAdded: 0,
        numFilesAlreadyAdded: 0,
        numFilesIgnored: 0,
        numFilesFailed: 0,
        totalSize: 0,
        averageSize: 0,
    };

    //
    // The currently scanning directory.
    //
    private currentlyScanning: string | undefined = undefined;

    constructor(
        assetStorage: IStorage,
        private readonly metadataStorage: IStorage,
        private readonly googleApiKey: string | undefined
            ) {

        this.assetDatabase = new AssetDatabase(assetStorage, metadataStorage);

        // Anything that goes through this.assetStorage automatically updates the merkle tree.
        this.assetStorage = new AssetDatabaseStorage(assetStorage, this.assetDatabase); 

        this.bsonDatabase = new BsonDatabase({
            storage: new StoragePrefixWrapper(this.assetStorage, `metadata`),
            maxCachedShards: 100,
        });

        this.metadataCollection = this.bsonDatabase.collection("metadata");
        const localHashCachePath = path.join(os.tmpdir(), `photosphere`);
        this.localHashCache = new HashCache(new FileStorage(localHashCachePath), localHashCachePath);
        this.databaseHashCache = new HashCache(metadataStorage, `.db`);
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
    // Creates a new media file database.
    //
    async create(): Promise<void> {
        await this.localHashCache.load();

        await this.assetDatabase.create();

        await this.metadataCollection.ensureSortIndex("hash", "asc", "string");
        await this.metadataCollection.ensureSortIndex("photoDate", "desc", "date");

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

        log.verbose(`Loaded existing media file database from: ${this.assetStorage.location} / ${this.metadataStorage.location}`);
    }

    //
    // Gets the summary of files added to the database.
    //
    getAddSummary(): IAddSummary {
        this.addSummary.averageSize = this.addSummary.numFilesAdded > 0 ? Math.floor(this.addSummary.totalSize / this.addSummary.numFilesAdded) : 0;
        return this.addSummary;
    }

    //
    // Adds a list of files or directories to the media file database.
    //
    async addPaths(paths: string[], progressCallback: ProgressCallback): Promise<void> {
        for (const path of paths) {
            await this.addPath(path, progressCallback);
        }
    }

    //
    // Adds a file or directory to the media file database.
    //
    async addPath(filePath: string, progressCallback: ProgressCallback): Promise<void> {
        const fileStat = await fsPromises.stat(filePath);
        if (fileStat.isFile()) {
            const contentType = mime.getType(filePath) || undefined;
            if (!contentType) {
                log.verbose(`Ignoring file "${filePath}" with unknown content type.`);
                this.addSummary.numFilesIgnored++;
                return;
            }
            await this.addFile(
                filePath, 
                {
                    contentType,
                    length: fileStat.size,
                    lastModified: fileStat.mtime,
                }, 
                fileStat.birthtime, 
                contentType, 
                [], 
                () => fs.createReadStream(filePath), 
                progressCallback
            );
        }
        else if (fileStat.isDirectory()) {
            return await this.scanDirectory(filePath, this.addFile, progressCallback);
        }
        else {
            throw new Error(`Unsupported file type: ${filePath}`);
        }
    }

    //
    // Checks a list of files or directories to find files already added to the media file database.
    //
    async checkPaths(paths: string[], progressCallback: ProgressCallback): Promise<void> {
        for (const path of paths) {
            await this.checkPath(path, progressCallback);
        }
    }

    //
    // Checks a file or directory to find files already added to the media file database.
    //
    async checkPath(filePath: string, progressCallback: ProgressCallback): Promise<void> {
        const fileStat = await fsPromises.stat(filePath);
        if (fileStat.isFile()) {
            const contentType = mime.getType(filePath) || undefined;
            if (!contentType) {
                log.verbose(`Ignoring file "${filePath}" with unknown content type.`);
                this.addSummary.numFilesIgnored++;
                return;
            }
            await this.checkFile(
                filePath, 
                {
                    contentType,
                    length: fileStat.size,
                    lastModified: fileStat.mtime,
                }, 
                fileStat.birthtime, 
                contentType, 
                [], 
                () => fs.createReadStream(filePath), 
                progressCallback
            );
        }
        else if (fileStat.isDirectory()) {
            return await this.scanDirectory(filePath, this.checkFile, progressCallback);
        }
        else {
            throw new Error(`Unsupported file type: ${filePath}`);
        }
    }

    //
    // Scans a directory for files and adds them to the media file database.
    //
    private async scanDirectory(directoryPath: string, visitFile: VisitFileCallback, progressCallback: ProgressCallback): Promise<void> {

        log.verbose(`Scanning directory "${directoryPath}" for media files.`);

        this.currentlyScanning = path.basename(directoryPath);
        progressCallback(this.currentlyScanning);

        for await (const orderedFile of walkDirectory(new FileStorage("fs:"), directoryPath, [/\.db/])) {

            this.currentlyScanning = path.basename(path.dirname(orderedFile.fileName));
            progressCallback(this.currentlyScanning);

            const contentType = mime.getType(orderedFile.fileName);
            const filePath = orderedFile.fileName;
            if (!contentType) {
                log.verbose(`Ignoring file "${filePath}" with unknown content type.`);
                this.addSummary.numFilesIgnored++;
                continue;
            }

            if (contentType === "application/zip"
                || contentType.startsWith("video")
                || contentType.startsWith("image")) {

                const fileStat = await fsPromises.stat(filePath);
                await visitFile(
                    filePath, 
                    {
                        contentType,
                        length: fileStat.size,
                        lastModified: fileStat.mtime,
                    }, 
                    fileStat.birthtime, 
                    contentType, 
                    [], 
                    () => fs.createReadStream(filePath),
                    progressCallback
                );
            }
            else {
                log.verbose(`Ignoring file "${filePath}" with content type "${contentType}".`);
                this.addSummary.numFilesIgnored++;
            }

            if (this.addSummary.numFilesAdded % 100 === 0) {
                //
                // Save hash caches progressively to make the next run faster.
                //
                await this.localHashCache.save();
                await this.databaseHashCache.save();
                await this.assetDatabase.save();                
            }
        }

        log.verbose(`Finished scanning directory "${directoryPath}" for media files.`);
    }

    //
    // Adds files from a zip file to the media file database.
    //
    private async scanZipFile(filePath: string, fileInfo: IFileInfo, fileDate: Date, openStream: () => Readable, visitFile: VisitFileCallback, progressCallback: ProgressCallback): Promise<void> {

        log.verbose(`Scanning zip file "${filePath}" for media files.`);

        this.currentlyScanning = path.basename(filePath);
        progressCallback(this.currentlyScanning);

        const zip = new JSZip();
        const unpacked = await zip.loadAsync(await buffer(openStream()));
        for (const [fileName, zipObject] of Object.entries(unpacked.files)) {
            if (!zipObject.dir) {
                const fullPath = `${filePath}/${fileName}`;
                const contentType = mime.getType(fileName) || undefined;
                if (!contentType) {
                    log.verbose(`Ignoring file "${fullPath}" with unknown content type.`);
                    this.addSummary.numFilesIgnored++;
                    continue;
                }

                if (contentType === "application/zip"
                    || contentType.startsWith("video")
                    || contentType.startsWith("image")) {


                    const fileData = await zipObject.async("nodebuffer");
                    await visitFile(
                        `zip://${fullPath}`, 
                        {
                            contentType,
                            length: fileData.length,
                            lastModified: fileDate,
                        }, 
                        fileDate, 
                        contentType, 
                        ["From zip file"], 
                        () => Readable.from(fileData),
                        progressCallback                    
                    );
                }
            }

            if (this.addSummary.numFilesAdded % 100 === 0) {
                //
                // Save hash caches progressively to make the next run faster.
                //
                await this.localHashCache.save();
                await this.databaseHashCache.save();
                await this.assetDatabase.save();                
            }
        }

        log.verbose(`Finished scanning zip file "${filePath}" for media files.`);
    }

    //
    // Adds a file to the media file database.
    //
    private addFile = async (filePath: string, fileInfo: IFileInfo, fileDate: Date, contentType: string, labels: string[], openStream: () => Readable, progressCallback: ProgressCallback): Promise<void> => {

        if (contentType === "application/zip") {
            return await this.scanZipFile(filePath, fileInfo, fileDate, openStream, this.addFile, progressCallback);
        }

        if (!await this.validateFile(filePath, fileInfo, contentType, openStream)) {
            log.error(`File "${filePath}" has failed validation.`);
            this.addSummary.numFilesFailed++;
            return;
        }

        const localHashedFile = await this.hashFile(filePath, fileInfo, openStream, this.localHashCache);

        const metadataCollection = this.bsonDatabase.collection("metadata");

        log.verbose(`Checking if file "${filePath}" with hash "${localHashedFile.hash.toString("hex")}" is already in the media file database.`);

        const localHashStr = localHashedFile.hash.toString("hex");
        const records = await metadataCollection.findByIndex("hash", localHashStr);
        if (records.length > 0) {
            //
            // The file is already in the database.
            //
            log.verbose(`File "${filePath}" with hash "${localHashStr}", matches existing records:\n  ${records.map(r => r._id).join("\n  ")}`);
            this.addSummary.numFilesAlreadyAdded++;
            return;
        }

        let assetDetails: IAssetDetails | undefined = undefined;

        if (contentType?.startsWith("video")) {
            assetDetails = await getVideoDetails(filePath, openStream);
        }
        else if (contentType?.startsWith("image")) {
            assetDetails = await getImageDetails(filePath, contentType, openStream);
        }

        const assetId = uuid();

        const assetPath = `assets/${assetId}`;
        const thumbPath = `thumb/${assetId}`;
        const displayPath = `display/${assetId}`;

        try {
            //
            // Uploads the full asset.
            //
            await retry(() => this.assetStorage.writeStream(assetPath, contentType, openStream(), fileInfo.length));
            await this.assetDatabase.addFile(filePath, localHashedFile);

            const assetInfo = await this.assetStorage.info(assetPath);
            if (!assetInfo) {
                throw new Error(`Failed to get info for file "${assetPath}"`);
            }
            const hashedAsset = await this.hashFile(assetPath, assetInfo, () => this.assetStorage.readStream(assetPath), this.databaseHashCache);
            if (hashedAsset.hash.toString("hex") !== localHashStr) {
                throw new Error(`Hash mismatch for file "${assetPath}": ${hashedAsset.hash.toString("hex")} != ${localHashStr}`);
            }
            await this.assetDatabase.addFile(assetPath, {
                hash: hashedAsset.hash,
                lastModified: assetInfo.lastModified,
                length: assetInfo.length,
            });

            if (assetDetails?.thumbnail) {
                //
                // Uploads the thumbnail.
                //
                await retry(() => this.assetStorage.writeStream(thumbPath, assetDetails.thumbnailContentType!, openStream()));

                const thumbInfo = await this.assetStorage.info(thumbPath);
                if (!thumbInfo) {
                    throw new Error(`Failed to get info for thumbnail "${thumbPath}"`);
                }
                const hashedThumb = await this.hashFile(thumbPath, thumbInfo, () => Readable.from(assetDetails.thumbnail), this.databaseHashCache);
                await this.assetDatabase.addFile(thumbPath, hashedThumb);
            }

            if (assetDetails?.display) {
                //
                // Uploads the display asset.
                //
                await retry(() => this.assetStorage.writeStream(displayPath, assetDetails.displayContentType, openStream()));

                const displayInfo = await this.assetStorage.info(displayPath);
                if (!displayInfo) {
                    throw new Error(`Failed to get info for display "${displayPath}"`);
                }
                const hashedDisplay = await this.hashFile(displayPath, displayInfo, () => Readable.from(assetDetails.display!), this.databaseHashCache);
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
                fileDate: dayjs(fileDate).toISOString(),
                photoDate: assetDetails?.photoDate || dayjs(fileDate).toISOString(),
                uploadDate: dayjs().toISOString(),
                properties,
                labels,
                description,
                micro: assetDetails?.micro.toString("base64"),
                color: assetDetails ? await ColorThief.getColor(assetDetails.thumbnail) : undefined,
            });

            log.verbose(`Added file "${filePath}" to the database with ID "${assetId}".`);

            this.addSummary.numFilesAdded++;
            this.addSummary.totalSize += fileInfo.length;
            if (progressCallback) {
                progressCallback(this.currentlyScanning);
            }
        }
        catch (err: any) {
            log.exception(`Failed to upload asset data for file "${filePath}"`, err);

            await this.assetStorage.deleteFile(assetPath);
            await this.assetStorage.deleteFile(thumbPath);
            await this.assetStorage.deleteFile(displayPath);

            this.addSummary.numFilesFailed++;
        }
    }

    //
    // Checks if a file has already been added to the media file database.
    //
    private checkFile = async  (filePath: string, fileInfo: IFileInfo, fileDate: Date, contentType: string, labels: string[], openStream: () => Readable, progressCallback: ProgressCallback): Promise<void> => {

        if (contentType === "application/zip") {
            return await this.scanZipFile(filePath, fileInfo, fileDate, openStream, this.checkFile, progressCallback);
        }

        const localHashedFile = await this.hashFile(filePath, fileInfo, openStream, this.localHashCache);

        const metadataCollection = this.bsonDatabase.collection("metadata");

        log.verbose(`Checking if file "${filePath}" with hash "${localHashedFile.hash.toString("hex")}" is already in the media file database.`);

        const localHashStr = localHashedFile.hash.toString("hex");
        const records = await metadataCollection.findByIndex("hash", localHashStr);
        if (records.length > 0) {
            //
            // The file is already in the database.
            //
            log.verbose(`File "${filePath}" with hash "${localHashStr}", matches existing records:\n  ${records.map(r => r._id).join("\n  ")}`);
            this.addSummary.numFilesAlreadyAdded++;
            return;
        }

        log.verbose(`File "${filePath}" has not been added to the media file database.`);

        this.addSummary.numFilesAdded++;
        this.addSummary.totalSize += fileInfo.length;
        if (progressCallback) {
            progressCallback(this.currentlyScanning);
        }
    }

    //
    // Closes the database.
    //
    async close(): Promise<void> {
        await this.localHashCache.save();
        await this.databaseHashCache.save();
        await this.bsonDatabase.close();
        await this.assetDatabase.close();
    }

    //
    // Validates the local file.
    //
    async validateFile(filePath: string, fileInfo: IFileInfo, contentType: string, openStream: () => Readable): Promise<boolean> {
        try {
            return await validateFile(filePath, fileInfo, contentType, openStream);
        }
        catch (error: any) {
            log.error(`File "${filePath}" has failed its validation with error: ${error.message}`);                
            return false;
        }
    }

    //
    // Gets the hash of a file.
    //
    // Retreive's the hash from the hash cache if it exists and the file size and last modified date match.
    // Otherwise, calculates the hash and stores it in the hash cache.
    //
    // It is assume we already have the file size and last modified date.
    //
    async hashFile(filePath: string, fileInfo: IFileInfo, openStream: () => Readable, hashCache: HashCache): Promise<IHashedFile> {
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

        //
        // Compute the hash of the file.
        //
        const hash = await computeHash(openStream());
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
}
