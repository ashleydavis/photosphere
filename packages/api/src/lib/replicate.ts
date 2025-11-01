//
// Result of the replication process.

import { computeHash } from "adb";
import { IStorage, StoragePrefixWrapper } from "storage";
import { retry } from "utils";
import { MediaFileDatabase, ProgressCallback } from "./media-file-database";
import { buildMerkleTree, getItemInfo, saveTree, SortNode, traverseTreeAsync, upsertItem } from "merkle-tree";
import { loadMerkleTree, loadOrCreateMerkleTree } from "./tree";
import { BsonDatabase, IInternalRecord, toExternal } from "bdb";
import stringify from "json-stable-stringify";

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

    //
    // The total number of BSON database records considered.
    //
    recordsConsidered: number;

    //
    // The number of BSON database records already existing in the destination database.
    //
    existingRecords: number;

    //
    // The number of BSON database records copied/updated in the destination database.
    //
    copiedRecords: number;
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
// Replicates the media file database to another storage.
//
export async function replicate(mediaFileDatabase: MediaFileDatabase, destAssetStorage: IStorage, destMetadataStorage: IStorage, options?: IReplicateOptions, progressCallback?: ProgressCallback): Promise<IReplicationResult> {

    const merkleTree = await retry(() => loadMerkleTree(mediaFileDatabase.getMetadataStorage()));
    if (!merkleTree) {
        throw new Error(`Failed to load merkle tree`);
    }

    const filesImported = merkleTree.databaseMetadata?.filesImported || 0;

    const result: IReplicationResult = {
        filesImported,
        filesConsidered: 0,
        existingFiles: 0,
        copiedFiles: 0,
        recordsConsidered: 0,
        existingRecords: 0,
        copiedRecords: 0,
    };

    //
    // Create or load the destination MediaFileDatabase to ensure sort indexes are loaded/created.
    // This has to be created before tree.dat is saved.
    //
    const destMediaFileDatabase = new MediaFileDatabase(
        destAssetStorage,
        destMetadataStorage,
        undefined, // googleApiKey not needed for replication
        mediaFileDatabase.uuidGenerator,
        mediaFileDatabase.getTimestampProvider()
    );
    
    // Load or create the destination database
    await retry(() => destMediaFileDatabase.loadOrCreate());


    //
    // Load the destination database, or create it if it doesn't exist.
    //
    let destMerkleTree = await loadOrCreateMerkleTree(destMetadataStorage, mediaFileDatabase.uuidGenerator);
    
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

        const assetStorage = mediaFileDatabase.getAssetStorage();
        const srcFileInfo = await retry(() => assetStorage.info(fileName));
        if (!srcFileInfo) {
            throw new Error(`Source file "${fileName}" does not exist in the source database.`);
        }

        //
        // Copy the file from source to dest.
        //
        await retry(async  () => {
            const readStream = assetStorage.readStream(fileName);
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

    await traverseTreeAsync<SortNode>(merkleTree.sort, processSrcNode);

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

    //
    // Replicate BSON database records.
    // Iterate through all collections and records, adding or updating records as needed.
    //    
    const sourceBsonDatabase = mediaFileDatabase.getMetadataDatabase();
    const destBsonDatabase = destMediaFileDatabase.getMetadataDatabase();

    // Helper function to compare two records for equality
    // Both records should be in external format (flat objects)
    const recordsAreEqual = (record1: any, record2: any): boolean => {
        // Serialize both records in a stable way and compare
        const record1Json = stringify(record1);
        const record2Json = stringify(record2);
        return record1Json === record2Json;
    };

    // Get all collections from source database
    const sourceCollections = await retry(() => sourceBsonDatabase.collections());

    // Replicate each collection
    for (const collectionName of sourceCollections) {
        const sourceCollection = sourceBsonDatabase.collection(collectionName);
        const destCollection = destBsonDatabase.collection(collectionName);

        // Iterate through all records in the source collection
        for await (const sourceRecordInternal of sourceCollection.iterateRecords()) {
            result.recordsConsidered++;

            // Convert source record to external format for comparison and insertion
            const sourceRecord = toExternal(sourceRecordInternal);

            // Check if record exists in destination
            const destRecord = await retry(() => destCollection.getOne(sourceRecord._id));

            if (!destRecord) {
                // Record doesn't exist in destination, add it
                await retry(() => destCollection.insertOne(sourceRecord));
                result.copiedRecords++;
            } else {
                // Record exists, check if it's different
                if (!recordsAreEqual(sourceRecord, destRecord)) {
                    // Records are different, update the destination record
                    await retry(() => destCollection.replaceOne(sourceRecord._id, sourceRecord, { upsert: true }));
                    result.copiedRecords++;
                } else {
                    // Records are identical, skip
                    result.existingRecords++;
                }
            }

            if (progressCallback && result.recordsConsidered % 100 === 0) {
                progressCallback(`Copied ${result.copiedFiles} files, ${result.copiedRecords} records | Already copied ${result.existingFiles} files, ${result.existingRecords} records`);
            }
        }
    }
    
    return result;
}
