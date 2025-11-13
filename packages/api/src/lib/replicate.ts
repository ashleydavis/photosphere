
import { computeHash } from "./hash";
import { IStorage, StoragePrefixWrapper } from "storage";
import { retry, FatalError } from "utils";
import { IDatabaseMetadata, MediaFileDatabase, ProgressCallback } from "./media-file-database";
import { buildMerkleTree, createTree, findDifferingNodes, findMerkleTreeDifferences, getItemInfo, IMerkleTree, loadTree, MerkleNode, MerkleTreeDiff, pruneTree, saveTree, upsertItem } from "merkle-tree";
import { loadMerkleTree } from "./tree";
import { toExternal, IBsonDatabase, IBsonCollection, IRecord, loadDatabaseMerkleTree, loadCollectionMerkleTree, loadShardMerkleTree } from "bdb";
import stringify from "json-stable-stringify";

//
// Result of the replication process.
//
export interface IReplicationResult {
    //
    // The total number of files imported.
    //
    filesImported: number;

    //
    // The number of files copied to the destination storage.
    //
    copiedFiles: number;

    //
    // The number of BSON database records copied/updated in the destination database.
    //
    copiedRecords: number;

    //
    // List of file names that were pruned from the destination.
    //
    prunedFiles: string[];
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
// Replicates files from source to destination.
//
async function replicateFiles(
    merkleTree: IMerkleTree<IDatabaseMetadata>,
    destMerkleTree: IMerkleTree<IDatabaseMetadata>,
    destAssetStorage: IStorage,
    destMetadataStorage: IStorage,
    mediaFileDatabase: MediaFileDatabase,
    options: IReplicateOptions | undefined,
    progressCallback: ProgressCallback | undefined,
    result: IReplicationResult
): Promise<void> {
    //
    // Collect nodes to process from the source merkle tree that are different.
    // If there's no dest merkle tree, we process the entire source tree.
    //
    let nodesToProcess: MerkleNode[] = [];
    let nodesToPrune: MerkleNode[] = [];
    
    if (destMerkleTree.merkle) {
        //
        // Find differences between source and destination merkle trees.
        //
        const diff = findMerkleTreeDifferences(merkleTree.merkle, destMerkleTree.merkle);        
        
        //
        // Collect nodes to process - only the differing MerkleNode roots from source.
        //
        nodesToProcess = diff.onlyInTree1;
        
        //
        // Collect nodes to prune from dest that are different (only in tree2).
        // Pruning will be done at the end.
        //
        nodesToPrune = diff.onlyInTree2;
    } else {
        // If there's no dest merkle tree, process the entire source tree
        if (merkleTree.merkle) {
            nodesToProcess = [ merkleTree.merkle ];
        }
        else if (destMerkleTree.merkle) {
            nodesToPrune = [ destMerkleTree.merkle ];
        }
    }

    let filesConsidered = 0;


    //
    // Copies an asset from the source storage to the destination storage.
    // But only when necessary.
    //
    const copyAsset = async (fileName: string, sourceHash: Buffer): Promise<void> => {
        filesConsidered++;
        
        // Check if file already exists in destination tree with matching hash.
        const destFileInfo = getItemInfo(destMerkleTree!, fileName);
        if (destFileInfo && Buffer.compare(destFileInfo.hash, sourceHash) === 0) {
            // File already exists with correct hash, skip copying.
            // This assumes the file is non-corrupted. To find corrupted files, a verify would be needed.
            if (progressCallback) {
                progressCallback(`Copied ${result.copiedFiles}`);
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
            progressCallback(`Copied ${result.copiedFiles}`);
        }
    };

    //
    // Process files from MerkleNode differences.
    //
    const processMerkleNode = async (merkleNode: MerkleNode): Promise<void> => {
        if (!merkleNode.left && !merkleNode.right) {
            // Leaf node - process the file directly
            if (merkleNode.name && merkleNode.hash) {
                // Skip files that don't match the path filter
                if (options?.pathFilter) {
                    const pathFilter = options.pathFilter.replace(/\\/g, '/'); // Normalize path separators
                    const fileName = merkleNode.name.replace(/\\/g, '/');
                    
                    // Check if the file matches the filter (exact match or starts with filter + '/')
                    if (fileName !== pathFilter && !fileName.startsWith(pathFilter + '/')) {
                        return;
                    }
                }
                
                await retry(() => copyAsset(merkleNode.name!, merkleNode.hash));

                if (result.copiedFiles % 100 === 0) {
                    // Save the destination merkle tree periodically
                    await retry(async () => {
                        if (destMerkleTree!.dirty) {
                            destMerkleTree!.merkle = buildMerkleTree(destMerkleTree!.sort);
                            destMerkleTree!.dirty = false;
                        }
                        await saveTree("tree.dat", destMerkleTree!, destMetadataStorage);
                    });
                }
            }
        } else {
            // Internal node - recursively process children
            if (merkleNode.left) {
                await processMerkleNode(merkleNode.left);
            }
            if (merkleNode.right) {
                await processMerkleNode(merkleNode.right);
            }
        }
    };

    // Process only the nodes that differ
    for (const nodeToProcess of nodesToProcess) {
        await processMerkleNode(nodeToProcess);
    }

    //
    // Prune nodes from dest that are different (only in tree2).
    //
    result.prunedFiles = pruneTree(destMerkleTree, nodesToPrune);

    //
    // Saves the dest database.
    //
    await retry(async () => {
        if (destMerkleTree!.dirty) {
            destMerkleTree!.merkle = buildMerkleTree(destMerkleTree!.sort);
            destMerkleTree!.dirty = false;
        }
        await saveTree("tree.dat", destMerkleTree!, destMetadataStorage);
    });
}

//
// Generator to extract leaf node names from MerkleNode arrays.
//
function* iterateLeaves(nodes: MerkleNode[]): Generator<string> { //todo: move this to the merkle-tree package and test it.
    for (const node of nodes) {
        if (!node.left && !node.right) {
            if (!node.name) {
                throw new Error("Leaf node has no name");
            }
            yield node.name;
        } else {
            if (node.left) {
                yield* iterateLeaves([node.left]);
            }
            if (node.right) {
                yield* iterateLeaves([node.right]);
            }
        }
    }
}

//
// Yields record IDs from tree1 that differ from tree2.
// tree1 is the primary tree (source for pass 1, dest for pass 2).
// tree2 is the comparison tree (dest for pass 1, source for pass 2).
// tree1Storage and tree2Storage are the storage locations for tree1 and tree2 respectively.
//
async function* iterateShardDifferences(
    collectionName: string,
    shardId: string,
    tree1Storage: IStorage,
    tree2Storage: IStorage
): AsyncGenerator<{ collectionName: string; recordId: string }> {
    const tree1 = await retry(() => loadShardMerkleTree(tree1Storage, collectionName, shardId));    
    if (!tree1?.merkle) {
        // If primary tree doesn't exist, no records to process.
        return;
    }
    
    const tree2 = await retry(() => loadShardMerkleTree(tree2Storage, collectionName, shardId));
    if (!tree2?.merkle) {
        // If comparison tree doesn't exist, all records in primary tree need to be processed
        for (const recordId of iterateLeaves([tree1.merkle])) {
            yield {
                collectionName,
                recordId,
            };
        }
        return;
    }
    
    // Find records in tree1 that differ from tree2
    const differingNodes = findDifferingNodes(tree1.merkle, tree2.merkle);    
    for (const recordId of iterateLeaves(differingNodes)) {
        yield {
            collectionName,
            recordId,
        };
    }
}

//
// Yields record IDs from tree1 collection that differ from tree2 collection.
// tree1 is the primary tree (source for pass 1, dest for pass 2).
// tree2 is the comparison tree (dest for pass 1, source for pass 2).
// tree1Storage and tree2Storage are the storage locations for tree1 and tree2 respectively.
//
async function* iterateCollectionDifferences(
    collectionName: string,
    tree1Storage: IStorage,
    tree2Storage: IStorage
): AsyncGenerator<{ collectionName: string; recordId: string }> {
    const tree1 = await retry(() => loadCollectionMerkleTree(tree1Storage, collectionName));
    if (!tree1?.merkle) {
        // If primary collection tree doesn't exist, no records to process.
        return;
    }
    
    const tree2 = await retry(() => loadCollectionMerkleTree(tree2Storage, collectionName));
    if (!tree2?.merkle) {
        // If comparison collection tree doesn't exist, process all shards in primary tree
        for (const shardId of iterateLeaves([tree1.merkle])) {
            yield* iterateShardDifferences(collectionName, shardId, tree1Storage, tree2Storage);
        }
        return;
    }
    
    // Find shards in tree1 that differ from tree2
    const differingShards = findDifferingNodes(tree1.merkle, tree2.merkle);    
    for (const shardId of iterateLeaves(differingShards)) {
        yield* iterateShardDifferences(collectionName, shardId, tree1Storage, tree2Storage);
    }
}

//
// Yields record IDs from tree1 database that differ from tree2 database.
// tree1 is the primary tree (source for pass 1, dest for pass 2).
// tree2 is the comparison tree (dest for pass 1, source for pass 2).
// tree1Storage and tree2Storage are the storage locations for tree1 and tree2 respectively.
//
async function* iterateDatabaseDifferences(
    tree1Storage: IStorage,
    tree2Storage: IStorage
): AsyncGenerator<{ collectionName: string; recordId: string }> {

    const tree1 = await retry(() => loadDatabaseMerkleTree(tree1Storage));    
    if (!tree1?.merkle) {
        // If primary database tree doesn't exist, no records to process.
        return;
    }
    
    const tree2 = await retry(() => loadDatabaseMerkleTree(tree2Storage));
    if (!tree2?.merkle) {
        // If comparison database tree doesn't exist, process all collections in primary tree
        for (const collectionName of iterateLeaves([tree1.merkle])) {
            yield* iterateCollectionDifferences(collectionName, tree1Storage, tree2Storage);
        }
        return;
    }
    
    // Find collections in tree1 that differ from tree2
    const differingCollections = findDifferingNodes(tree1.merkle, tree2.merkle);    
    for (const collectionName of iterateLeaves(differingCollections)) {
        yield* iterateCollectionDifferences(collectionName, tree1Storage, tree2Storage);
    }
}

//
// Replicates BSON database records from source to destination.
//
async function replicateBsonDatabase(
    mediaFileDatabase: MediaFileDatabase,
    destMediaFileDatabase: MediaFileDatabase,
    progressCallback: ProgressCallback | undefined,
    result: IReplicationResult
): Promise<void> {
    //
    // Replicate BSON database records using merkle tree differences.
    // This walks the tree of trees (database -> collections -> shards -> records)
    // to efficiently identify only the records that need to be updated.
    //
    const sourceBsonDatabase = mediaFileDatabase.getMetadataDatabase();
    const destBsonDatabase = destMediaFileDatabase.getMetadataDatabase();

    // Wrap storage with metadata prefix for merkle tree loading
    // The BSON database merkle trees are stored in assetStorage with a "metadata" prefix
    const sourceStorage = new StoragePrefixWrapper(mediaFileDatabase.getAssetStorage(), "metadata");
    const destStorage = new StoragePrefixWrapper(destMediaFileDatabase.getAssetStorage(), "metadata");

    // Helper function to compare two records for equality
    // Both records should be in external format (flat objects)
    const recordsAreEqual = (record1: any, record2: any): boolean => {
        // Serialize both records in a stable way and compare
        const record1Json = stringify(record1);
        const record2Json = stringify(record2);
        return record1Json === record2Json;
    };

    let recordsConsidered = 0;

    //
    // First pass: Find records in source that are new or different.
    // These records need to be inserted or replaced in the dest database.
    //
    for await (const diff of iterateDatabaseDifferences(sourceStorage, destStorage)) {
        recordsConsidered++;

        const sourceCollection = sourceBsonDatabase.collection(diff.collectionName);
        const destCollection = destBsonDatabase.collection(diff.collectionName);

        // Load the source record (getOne already returns external format)
        const sourceRecord = await retry(() => sourceCollection.getOne(diff.recordId));
        if (!sourceRecord) {
            // Record doesn't exist in source, skip it
            continue;
        }

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
            }
        }

        if (progressCallback && recordsConsidered % 100 === 0) {
            progressCallback(`Copied ${result.copiedFiles} files, ${result.copiedRecords} records`);
        }
    }

    //
    // Second pass: Find records in dest that are new or different.
    // These records need to be removed from the dest database to match source.
    //
    for await (const diff of iterateDatabaseDifferences(destStorage, sourceStorage)) {
        recordsConsidered++;

        const destCollection = destBsonDatabase.collection(diff.collectionName);

        // Check if record exists in source
        const sourceCollection = sourceBsonDatabase.collection(diff.collectionName);
        const sourceRecord = await retry(() => sourceCollection.getOne(diff.recordId)); //todo: It's possible we don't need to do this lookup.
        if (!sourceRecord) {
            // Record doesn't exist in source, remove it from dest to match source
            await retry(() => destCollection.deleteOne(diff.recordId));
            result.copiedRecords++;
        }

        if (progressCallback && recordsConsidered % 100 === 0) {
            progressCallback(`Copied ${result.copiedFiles} files, ${result.copiedRecords} records`);
        }
    }
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
        copiedFiles: 0,
        copiedRecords: 0,
        prunedFiles: [],
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

    const treeExists = await retry(() => destMetadataStorage.fileExists("tree.dat"));
    if (treeExists) {
        await retry(() => destMediaFileDatabase.load());
    }
    else {
        //
        // This is need because it will create the sort indexes and other things.
        //
        await retry(() => destMediaFileDatabase.create(merkleTree.id));
    }
    
    //
    // Load the destination database that might have been just created.
    //
    let destMerkleTree = await loadMerkleTree(destMetadataStorage);
    if (!destMerkleTree) {
        throw new FatalError(`Failed to load merkle tree from destination database.`);
    }
    
    if (destMerkleTree.id !== merkleTree.id) {
        throw new FatalError(
            `You are trying to replicate to a database that has a different ID than the source database.\n` +
            `Source database ID: ${merkleTree.id}\n` +
            `Destination database ID: ${destMerkleTree.id}\n` + 
            `The destination database is not related to the source database.`
        );
    }
    
    //
    // Copy database metadata from source to destination.
    //
    if (merkleTree.databaseMetadata) {
        destMerkleTree.databaseMetadata = { ...merkleTree.databaseMetadata };
    }

    await replicateFiles(
        merkleTree,
        destMerkleTree,
        destAssetStorage,
        destMetadataStorage,
        mediaFileDatabase,
        options,
        progressCallback,
        result
    );

    await replicateBsonDatabase(
        mediaFileDatabase,
        destMediaFileDatabase,
        progressCallback,
        result
    );
    
    return result;
}
