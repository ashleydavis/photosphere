import { BsonDatabase, IBsonCollection, getDatabaseRootHash } from "bdb";
import { IStorage, pathJoin, StoragePrefixWrapper } from "storage";
import { ILocation, log, retry, IUuidGenerator, ITimestampProvider } from "utils";
import dayjs from "dayjs";
import { IAsset } from "defs";
import { computeHash } from "./hash";
import { IFileStat, ScannerOptions } from "./file-scanner";

import customParseFormat from "dayjs/plugin/customParseFormat";
dayjs.extend(customParseFormat);

import { Image } from "tools";
import { IResolution } from "./image";
import _ from "lodash";
import { acquireWriteLock, refreshWriteLock, releaseWriteLock } from "./write-lock";
import { computeAssetHash } from "./hash";
import { loadMerkleTree, saveMerkleTree } from "./tree";
import { addItem, createTree, deleteItem, combineHashes, IMerkleTree } from "merkle-tree";

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
export type FileValidator = (filePath: string, fileStat: IFileStat, contentType: string, zipFilePath?: string) => Promise<boolean>;

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
    // The number of files that were processed (completed or failed).
    //
    filesProcessed: number;

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

    return {
        assetStorage,
        bsonDatabase,
        metadataCollection,
    };
}

//
// Creates a new media file database.
//
export async function createDatabase(
    assetStorage: IStorage,
    metadataStorage: IStorage,
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

    await retry(() => saveMerkleTree(merkleTree, metadataStorage));

    log.verbose(`Created new media file database.`);
}

//
// Loads the existing media file database.
//
export async function loadDatabase(
    assetStorage: IStorage,
    metadataCollection: IBsonCollection<IAsset>
): Promise<void> {
    await retry(() => metadataCollection.loadSortIndexFromStorage("hash", "asc", "string"));
    await retry(() => metadataCollection.loadSortIndexFromStorage("photoDate", "desc", "date"));

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
// Gets a summary of the entire database.
//
export async function getDatabaseSummary(assetStorage: IStorage, metadataStorage: IStorage): Promise<IDatabaseSummary> {
    const merkleTree = await retry(() => loadMerkleTree(metadataStorage));
    if (!merkleTree) {
        throw new Error(`Failed to load merkle tree.`);
    }
    
    const filesImported = merkleTree.databaseMetadata?.filesImported || 0;
    
    // Get root hashes from both merkle trees (compute inline to avoid loading merkle tree again)
    const filesRootHash = merkleTree.merkle?.hash;
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
        totalImports: filesImported,
        totalFiles: merkleTree.sort?.leafCount || 0,
        totalSize: merkleTree.sort?.size || 0,
        totalNodes: merkleTree.sort?.nodeCount || 0,
        fullHash,
        filesHash: filesRootHash?.toString('hex'),
        databaseHash: databaseRootHash?.toString('hex'),
        databaseVersion: merkleTree.version
    };
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
    metadataStorage: IStorage,
    sessionId: string,
    assetId: string,
    assetType: string,
    contentType: string,
    buffer: Buffer
): Promise<void> {
    const assetPath = `${assetType}/${assetId}`;

    if (!await acquireWriteLock(metadataStorage, sessionId)) {
        throw new Error(`Failed to acquire write lock.`);
    }

    try {
        let merkleTree = await retry(() => loadMerkleTree(metadataStorage));
        if (!merkleTree) {
            throw new Error(`Failed to load media file database.`);
        }

        await retry(() => assetStorage.write(assetPath, contentType, buffer));

        const assetInfo = await retry(() => assetStorage.info(assetPath));
        if (!assetInfo) {
            throw new Error(`Failed to get info for file "${assetPath}"`);
        }

        const hashedAsset = await retry(() => computeAssetHash(assetStorage.readStream(assetPath), assetInfo));

        await refreshWriteLock(metadataStorage, sessionId);

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

        await retry(() => saveMerkleTree(merkleTree, metadataStorage));
    }
    catch (err: any) {
        log.exception(`Failed to add asset "${assetPath}" from buffer`, err);
        await retry(() => assetStorage.deleteFile(assetPath));
        throw err;
    }
    finally {
        await releaseWriteLock(metadataStorage);
    }
}

//
// Removes an asset by ID, including all associated files and metadata.
// This is the comprehensive removal method that handles storage cleanup.
//
// @param recordDeleted - Whether to record the deleted asset ID in deletedAssetIds. Defaults to true.
//                        Set to false when removing duplicates or performing cleanup operations
//                        where tracking deleted assets is not desired.
//
export async function removeAsset(
    assetStorage: IStorage,
    metadataStorage: IStorage,
    sessionId: string,
    metadataCollection: IBsonCollection<IAsset>,
    assetId: string,
    recordDeleted?: boolean
): Promise<void> {
    if (!await acquireWriteLock(metadataStorage, sessionId)) {
        throw new Error(`Failed to acquire write lock.`);
    }

    try {
        let merkleTree = await retry(() => loadMerkleTree(metadataStorage));
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
            
            // Record deleted asset ID if requested (default: true for backward compatibility)
            if (recordDeleted !== false) {
                if (!merkleTree.databaseMetadata.deletedAssetIds) {
                    merkleTree.databaseMetadata.deletedAssetIds = [];
                }
                if (!merkleTree.databaseMetadata.deletedAssetIds.includes(assetId)) {
                    merkleTree.databaseMetadata.deletedAssetIds.push(assetId);
                }
            }
        }

        await assetStorage.deleteFile(pathJoin("asset", assetId));
        await assetStorage.deleteFile(pathJoin("display", assetId));
        await assetStorage.deleteFile(pathJoin("thumb", assetId));

        deleteItem<IDatabaseMetadata>(merkleTree, pathJoin("asset", assetId));
        deleteItem<IDatabaseMetadata>(merkleTree, pathJoin("display", assetId));
        deleteItem<IDatabaseMetadata>(merkleTree, pathJoin("thumb", assetId));

        await retry(() => saveMerkleTree(merkleTree, metadataStorage)); 
    }
    finally {
        await releaseWriteLock(metadataStorage);
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
