import fs from "fs";
import fsPromises from "fs/promises";
import os from "os";
import path from "path";
import { BsonDatabase, IBsonCollection, IFileInfo, IStorage, pathJoin, StoragePrefixWrapper } from "storage";
import { AssetDatabase, IHashedFile } from "./asset-database";
import { validateFile } from "./validation";
import mime from "mime";
import { log } from "./log";
import { ILocation, retry, reverseGeocode, uuid, WrappedError } from "utils";
import dayjs from "dayjs";
import { IAsset } from "defs";
import { Readable } from "stream";
import { HashCache } from "./hash-cache";
import { getVideoDetails } from "./video";
import { getImageDetails } from "./image";
import { IResolution } from "node-utils";
import JSZip from "jszip";
import { buffer } from "node:stream/consumers";

// @ts-ignore
import ColorThief from "colorthief";
import { walkDirectory } from "./walk-directory";
import { fullPath } from "./merkle-tree";
import { computeHash } from "./hash";

//
// A function that validates a file.
//
export type FileValidator = (filePath: string, fileInfo: IFileInfo, openStream: () => Readable) => Promise<boolean>;

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

    constructor(
        private readonly assetStorage: IStorage,
        private readonly metadataStorage: IStorage,
        private readonly googleApiKey: string | undefined
            ) {

        this.assetDatabase = new AssetDatabase(assetStorage, metadataStorage);
        this.bsonDatabase = new BsonDatabase({
            storage: new StoragePrefixWrapper(pathJoin(metadataStorage.location, `metadata`), metadataStorage, `metadata`),
            maxCachedShards: 100,
            onFilesSaved: async (filesSaved) => {
                for (const fileSaved of filesSaved) {
                    console.log(`Updating file "${fileSaved}" in the asset database.`);

                    const info = await this.assetStorage.info(fileSaved);
                    if (!info) {
                        throw new Error(`Failed to get info for file "${fileSaved}"`);
                    }
                    const hash = await computeHash(this.assetStorage.readStream(fileSaved));
                    this.assetDatabase.addFile(fileSaved, {
                        hash,
                        contentType: undefined, // Don't need to worry about content type for the binary metadata files.
                        lastModified: info.lastModified,
                        length: info.length,
                    });
                }
            }
        });

        this.metadataCollection = this.bsonDatabase.collection("metadata");
        this.localHashCache = new HashCache(metadataStorage, path.join(os.tmpdir(), `photosphere`));
        this.databaseHashCache = new HashCache(metadataStorage, `.db`);
    }

    //
    // Creates a new media file database.
    //
    async create(): Promise<void> {
        await this.localHashCache.load();

        await this.assetDatabase.create();

        await this.metadataCollection.ensureIndex("hash");
        await this.metadataCollection.ensureSortIndex("photoDate", "desc");

        log.verbose(`Created new media file database.`);
    }

    //
    // Loads the existing media file database.
    //
    async load(): Promise<void> {
        await this.localHashCache.load();
        await this.databaseHashCache.load();
        await this.assetDatabase.load();

        await this.metadataCollection.ensureIndex("hash");
        await this.metadataCollection.ensureSortIndex("photoDate", "desc");

        log.verbose(`Loaded existing media file database from: ${this.assetDatabase.toString()} / ${this.metadataStorage.toString()}`);
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
    async addPaths(paths: string[]): Promise<void> {
        for (const path of paths) {
            await this.addPath(path);
        }
    }

    //
    // Adds a file or directory to the media file database.
    //
    async addPath(filePath: string): Promise<void> {
        const fileStat = await fsPromises.stat(filePath);
        if (fileStat.isFile()) {
            const contentType = mime.getType(filePath) || undefined;
            await this.addFile(filePath, {
                contentType,
                length: fileStat.size,
                lastModified: fileStat.mtime,
            }, fileStat.birthtime, [], () => fs.createReadStream(filePath));
        }
        else if (fileStat.isDirectory()) {
            return await this.scanDirectory(filePath);
        }
        else {
            throw new Error(`Unsupported file type: ${filePath}`);
        }
    }

    //
    // Adds a file to the media file database.
    //
    async addFile(filePath: string, fileInfo: IFileInfo, fileDate: Date, labels: string[], openStream: () => Readable): Promise<void> {

        if (fileInfo.contentType === "application/zip") {
            return await this.scanZipFile(filePath, fileInfo, fileDate, openStream);
        }

        log.verbose(`Adding file "${filePath}" to the media file database.`);

        const localHashedFile = await this.hashFile(filePath, fileInfo, validateFile, openStream, this.localHashCache);

        const metadataCollection = this.bsonDatabase.collection("metadata");

        const localHashStr = localHashedFile.hash.toString("hex");
        const records = await metadataCollection.findByIndex("hash", localHashStr);
        if (records.length > 0) {
            //
            // The file is already in the database.
            //
            log.info(`File "${filePath}" already in the database, don't need to add it.`);
            log.verbose(`File "${filePath}" with hash "${localHashStr}", matches existing records:\n  ${records.map(r => r._id).join("\n  ")}`);
            log.json("file-exists", {
                filePath,
                hash: localHashStr,
                size: fileInfo.length,
                lastModified: fileInfo.lastModified,
                matchingRecords: records.map(r => r._id),
            });

            this.addSummary.numFilesAlreadyAdded++;
        }

        let assetDetails: IAssetDetails | undefined = undefined;

        if (fileInfo.contentType?.startsWith("video")) {
            assetDetails = await getVideoDetails(filePath, openStream);
        }
        else if (fileInfo.contentType?.startsWith("image")) {
            assetDetails = await getImageDetails(filePath, fileInfo.contentType, openStream);
        }

        const assetId = uuid();

        const assetPath = `assets/${assetId}`;
        const thumbPath = `thumb/${assetId}`;
        const displayPath = `display/${assetId}`;

        try {
            //
            // Uploads the full asset.
            //
            await retry(() => this.assetStorage.writeStream(assetPath, fileInfo.contentType, openStream(), fileInfo.length));
            await this.assetDatabase.addFile(filePath, localHashedFile);

            const assetInfo = await this.assetStorage.info(assetPath);
            if (!assetInfo) {
                throw new Error(`Failed to get info for file "${assetPath}"`);
            }
            const hashedAsset = await this.hashFile(assetPath, assetInfo, undefined, () => this.assetStorage.readStream(assetPath), this.databaseHashCache);
            if (hashedAsset.hash.toString("hex") !== localHashStr) {
                throw new Error(`Hash mismatch for file "${assetPath}": ${hashedAsset.hash.toString("hex")} != ${localHashStr}`);
            }
            await this.assetDatabase.addFile(assetPath, {
                hash: hashedAsset.hash,
                contentType: assetInfo.contentType,
                lastModified: assetInfo.lastModified,
                length: assetInfo.length,
            });

            if (assetDetails?.thumbnail) {
                //
                // Uploads the thumbnail.
                //
                await retry(() => this.assetStorage.writeStream(thumbPath, assetDetails.thumbnailContentType, openStream()));

                const thumbInfo = await this.assetStorage.info(thumbPath);
                if (!thumbInfo) {
                    throw new Error(`Failed to get info for thumbnail "${thumbPath}"`);
                }
                const hashedThumb = await this.hashFile(thumbPath, thumbInfo, undefined, () => Readable.from(assetDetails.thumbnail), this.databaseHashCache);
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
                const hashedDisplay = await this.hashFile(displayPath, displayInfo, undefined, () => Readable.from(assetDetails.display!), this.databaseHashCache);
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
                if (!googleApiKey) {
                    log.warn(`Google API key not set, skipping reverse geocoding.`);
                }
                else {
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
            this.bsonDatabase.collection("metadata").insertOne({
                _id: assetId,
                width: assetDetails?.resolution.width,
                height: assetDetails?.resolution.height,
                origFileName: path.basename(filePath),
                origPath: fileDir,
                contentType: fileInfo.contentType,
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
            log.json("file-added", {
                filePath,
                hash: localHashStr,
                size: fileInfo.length,
                lastModified: fileInfo.lastModified,
                assetId,
            });

            this.addSummary.numFilesAdded++;
            this.addSummary.totalSize += fileInfo.length;
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
    // Scans a directory for files and adds them to the media file database.
    //
    async scanDirectory(directoryPath: string): Promise<void> {

        log.verbose(`Scanning directory "${directoryPath}" for media files.`);

        for await (const orderedFile of walkDirectory(this.assetStorage, "", undefined, [/\.db/])) {
            const contentType = mime.getType(orderedFile.fileName);
            const filePath = fullPath(orderedFile.fileName, orderedFile.directory)
            if (!contentType) {
                log.verbose(`Ignoring file "${filePath}" with unknown content type.`);
                log.json("file-ignored", {
                    filePath,
                    reason: "unknown content type",
                });
                this.addSummary.numFilesIgnored++;
                continue;
            }

            if (contentType === "application/zip"
                || contentType.startsWith("video")
                || contentType.startsWith("image")) {

                const fileStat = await fsPromises.stat(filePath);
                await this.addFile(filePath, {
                    contentType,
                    length: fileStat.size,
                    lastModified: fileStat.mtime,
                }, fileStat.birthtime, [], () => fs.createReadStream(filePath));
            }
            else {
                log.verbose(`Ignoring file "${filePath}" with content type "${contentType}".`);
                log.json("file-ignored", {
                    filePath,
                    reason: "unsupported content type",
                });
                this.addSummary.numFilesIgnored++;
            }

            if (this.addSummary.numFilesAdded % 100 === 0) {
                //
                // Save hash caches progressively to make the next run faster.
                //
                await this.localHashCache.save();
                await this.databaseHashCache.save();
            }
        }

        log.verbose(`Finished scanning directory "${directoryPath}" for media files.`);
    }

    //
    // Adds files from a zip file to the media file database.
    //
    async scanZipFile(filePath: string, fileInfo: IFileInfo, fileDate: Date, openStream: () => Readable): Promise<void> {

        log.verbose(`Scanning zip file "${filePath}" for media files.`);

        const zip = new JSZip();
        const unpacked = await zip.loadAsync(await buffer(openStream()));
        for (const [fileName, zipObject] of Object.entries(unpacked.files)) {
            if (!zipObject.dir) {
                const fullPath = `${filePath}/${fileName}`;
                const contentType = mime.getType(fileName) || undefined;
                if (!contentType) {
                    log.verbose(`Ignoring file "${fullPath}" with unknown content type.`);
                    log.json("file-ignored", {
                        filePath: fullPath,
                        reason: "unknown content type",
                    });
                    this.addSummary.numFilesIgnored++;
                    continue;
                }

                if (contentType === "application/zip"
                    || contentType.startsWith("video")
                    || contentType.startsWith("image")) {


                    const fileData = await zipObject.async("nodebuffer");
                    await this.addFile(`zip://${fullPath}`, {
                        contentType,
                        length: fileData.length,
                        lastModified: fileDate,
                    }, fileDate, ["From zip file"], () => Readable.from(fileData));
                }
            }

            if (this.addSummary.numFilesAdded % 100 === 0) {
                //
                // Save hash caches progressively to make the next run faster.
                //
                await this.localHashCache.save();
                await this.databaseHashCache.save();
            }
        }

        log.verbose(`Finished scanning zip file "${filePath}" for media files.`);
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
    // Gets the hash of a file.
    //
    // Retreive's the hash from the hash cache if it exists and the file size and last modified date match.
    // Otherwise, calculates the hash and stores it in the hash cache.
    //
    // It is assume we already have the file size and last modified date.
    //
    async hashFile(filePath: string, fileInfo: IFileInfo, validateFile: FileValidator | undefined, openStream: () => Readable, hashCache: HashCache): Promise<IHashedFile> {
        const cacheEntry = hashCache.getHash(filePath);
        if (cacheEntry) {
            if (cacheEntry.length === fileInfo.length && cacheEntry.lastModified === fileInfo.lastModified) {
                // The hash cache entry is valid, so return it.
                // If a hash is commited to the hash cache, the file is assumed to be valid.
                return {
                    hash: cacheEntry.hash,
                    contentType: fileInfo.contentType,
                    lastModified: fileInfo.lastModified,
                    length: fileInfo.length,
                }
            }
        }

        //
        // Validates the file if requested.
        //
        if (validateFile) {
            try {
                const isValid = await validateFile(filePath, fileInfo, openStream);
                if (!isValid) {
                    throw new Error(`File "${filePath}" failed validation.`);
                }
            }
            catch (error: any) {
                throw new WrappedError(`Validation failed for ${filePath} (${fileInfo.contentType})`, { cause: error });
            }
        }

        //
        // Compute the hash of the file.
        //
        const hash = await computeHash(openStream());
        const hashedFile: IHashedFile = {
            hash,
            contentType: fileInfo.contentType,
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
