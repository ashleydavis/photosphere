
import { computeHash } from "./hash";
import { IStorage, StoragePrefixWrapper } from "storage";
import { retry, FatalError, ITimestampProvider, IUuidGenerator, log } from "utils";
import { IDatabaseMetadata, ProgressCallback, createMediaFileDatabase, loadDatabase, createDatabase } from "./media-file-database";
import { BsonDatabase, BatchSortIndexManager } from "bdb";
import { findDifferingNodes, findMerkleTreeDifferences, getItemInfo, IMerkleTree, MerkleNode, pruneTree, upsertItem } from "merkle-tree";
import { loadMerkleTree, merkleTreeExists, saveMerkleTree } from "./tree";
import { loadCollectionMerkleTree, loadShardMerkleTree } from "./tree";
import { loadDatabaseMerkleTree } from "bdb";

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

    //
    // If true, allows replication even if source and destination have different database IDs.
    //
    force?: boolean;

    //
    // If true, only copy thumb directory assets. Asset and display files will be lazily copied when needed.
    //
    partial?: boolean;
}

//
// Replicates files from source to destination.
//
async function replicateFiles(
    merkleTree: IMerkleTree<IDatabaseMetadata>,
    destMerkleTree: IMerkleTree<IDatabaseMetadata>,
    destAssetStorage: IStorage,
    destMetadataStorage: IStorage,
    sourceAssetStorage: IStorage,
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
        log.verbose(`Found ${diff.onlyInTree1.length} nodes to copy, ${diff.onlyInTree2.length} nodes to prune`);
        
        //
        // Collect nodes to process - only the differing MerkleNode roots from source.
        //
        nodesToProcess = diff.onlyInTree1;
        
        //
        // Collect nodes to prune from dest that are different (only in tree2).
        // Pruning will be done at the end.
        //
        nodesToPrune = diff.onlyInTree2;
    }
    else {
        // If there's no dest merkle tree, process the entire source tree
        if (merkleTree.merkle) {
            nodesToProcess = [ merkleTree.merkle ];
        }
        else if (destMerkleTree.merkle) {
            nodesToPrune = [ destMerkleTree.merkle ];
        }
    }

    //
    // Copies an asset from the source storage to the destination storage.
    // But only when necessary.
    //
    const copyAsset = async (fileName: string, sourceHash: Buffer): Promise<void> => {
        
        // Check if file already exists in destination tree with matching hash.
        const destFileInfo = getItemInfo(destMerkleTree!, fileName);
        if (destFileInfo && Buffer.compare(destFileInfo.hash, sourceHash) === 0) {
            log.verbose(`File already exists with correct hash, skipping copy: ${fileName}`);

            // File already exists with correct hash, skip copying.
            // This assumes the file is non-corrupted. To find corrupted files, a verify would be needed.
            if (progressCallback) {
                progressCallback(`Copied ${result.copiedFiles}`);
            }
            return;
        }

        log.verbose(`Copying file: ${fileName}`);
        const assetStorage = sourceAssetStorage;
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

        log.verbose(`Copied file: ${fileName}`);

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

        log.verbose(`Destination file ${fileName} matches source hash ${sourceHash.toString("hex")}`);

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
        destMerkleTree = upsertItem(destMerkleTree!, {
            name: fileName,
            hash: copiedHash,
            length: copiedFileInfo.length,
            lastModified: copiedFileInfo.lastModified,
        });

        result.copiedFiles++;

        log.verbose(`Added file to destination merkle tree: ${fileName}`);

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
                
                // In partial mode, only copy thumb directory files and root-level files (like README.md)
                if (options?.partial) {
                    const fileName = merkleNode.name.replace(/\\/g, '/');
                    const isThumbFile = fileName.startsWith('thumb/');
                    const isRootFile = !fileName.includes('/');
                    if (!isThumbFile && !isRootFile) {
                        log.verbose(`Skipped ${fileName} (partial mode, only thumb files and root files are copied)`);
                        return;
                    }
                }
                
                await retry(() => copyAsset(merkleNode.name!, merkleNode.hash));

                if (result.copiedFiles % 100 === 0) {
                    // Save the destination merkle tree periodically
                    await retry(() => saveMerkleTree(destMerkleTree!, destMetadataStorage));
                }
            }
        } 
        else {
            // Internal node - recursively process children
            if (merkleNode.left) {
                await processMerkleNode(merkleNode.left);
            }
            if (merkleNode.right) {
                await processMerkleNode(merkleNode.right);
            }
        }
    };
    
    if (nodesToProcess.length > 0 || nodesToPrune.length > 0) {
        //
        // Process only the nodes that differ.
        //

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
        await retry(() => saveMerkleTree(destMerkleTree!, destMetadataStorage));
    }
}

//
// Generator to extract leaf node names from MerkleNode arrays.
//
export function* iterateLeaves(nodes: MerkleNode[]): Generator<string> { //todo: move this to the merkle-tree package and test it.
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
export async function* iterateShardDifferences(
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
export async function* iterateCollectionDifferences(
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
export async function* iterateDatabaseDifferences(
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
// Builds a map of modified records per collection, then processes by shard: load source and dest shards,
// apply updates to dest shard's records map, update sort indexes, save shard once, update merkle trees.
//
async function replicateBsonDatabase(
    sourceBsonDatabase: BsonDatabase,
    destBsonDatabase: BsonDatabase,
    sourceAssetStorage: IStorage,
    destAssetStorage: IStorage,
    progressCallback: ProgressCallback | undefined,
    result: IReplicationResult
): Promise<void> {

    //
    // Replicate BSON database records using merkle tree differences.
    // This walks the tree of trees (database -> collections -> shards -> records)
    // to efficiently identify only the records that need to be updated.
    //
    // Use v6 layout: BSON database merkle trees are stored under .db/bson
    const sourceStorage = new StoragePrefixWrapper(sourceAssetStorage, ".db/bson");
    const destStorage = new StoragePrefixWrapper(destAssetStorage, ".db/bson");

    // 1. Build map of modified records per collection: toCopy (source→dest) and toDelete (dest→source)
    const toCopyByCollection = new Map<string, Set<string>>();
    const toDeleteByCollection = new Map<string, Set<string>>();

    for await (const diff of iterateDatabaseDifferences(sourceStorage, destStorage)) {
        let set = toCopyByCollection.get(diff.collectionName);
        if (!set) {
            set = new Set<string>();
            toCopyByCollection.set(diff.collectionName, set);
        }
        set.add(diff.recordId);
    }
    const toCopyTotal = [...toCopyByCollection.values()].reduce((n, s) => n + s.size, 0);

    for await (const diff of iterateDatabaseDifferences(destStorage, sourceStorage)) {
        let set = toDeleteByCollection.get(diff.collectionName);
        if (!set) {
            set = new Set<string>();
            toDeleteByCollection.set(diff.collectionName, set);
        }
        set.add(diff.recordId);
    }
    const toDeleteTotal = [...toDeleteByCollection.values()].reduce((n, s) => n + s.size, 0);

    const collectionNames = new Set<string>([...toCopyByCollection.keys(), ...toDeleteByCollection.keys()]);

    for (const collectionName of collectionNames) {
        const sourceColl = sourceBsonDatabase.collection(collectionName);
        const destColl = destBsonDatabase.collection(collectionName);

        const toCopy = toCopyByCollection.get(collectionName) ?? new Set<string>();
        const toDelete = toDeleteByCollection.get(collectionName) ?? new Set<string>();

        const batchSortIndexManager = new BatchSortIndexManager(destColl);
        await batchSortIndexManager.startBatch();

        // 2. Group record ids by shard
        const byShard = new Map<string, { toCopy: Set<string>; toDelete: Set<string> }>();
        function addToShard(recordId: string, kind: 'toCopy' | 'toDelete'): void {
            const shardId = destColl.getShardId(recordId);
            let entry = byShard.get(shardId);
            if (!entry) {
                entry = { toCopy: new Set<string>(), toDelete: new Set<string>() };
                byShard.set(shardId, entry);
            }
            entry[kind].add(recordId);
        }
        for (const id of toCopy) {
            addToShard(id, 'toCopy');
        }
        for (const id of toDelete) {
            addToShard(id, 'toDelete');
        }

        for (const [shardId, { toCopy: toCopyInShard, toDelete: toDeleteInShard }] of byShard) {
            const sourceShard = await retry(() => sourceColl.loadShard(shardId));

            const destShard = await retry(() => destColl.loadShard(shardId));

            for (const recordId of toCopyInShard) {
                const sourceRecord = sourceColl.getRecordFromShard(recordId, sourceShard);
                if (!sourceRecord) {
                    continue;
                }
                const oldDest = destColl.getRecordFromShard(recordId, destShard);
                destColl.setRecordInShard(recordId, sourceRecord, destShard);
                await retry(() => batchSortIndexManager.syncRecord(sourceRecord, oldDest));
                result.copiedRecords++;
            }

            for (const recordId of toDeleteInShard) {
                const oldDest = destColl.getRecordFromShard(recordId, destShard);
                if (!oldDest) {
                    continue;
                }
                destColl.deleteRecordFromShard(recordId, destShard);
                await retry(() => batchSortIndexManager.removeRecord(recordId, oldDest));
                result.copiedRecords++;
            }

            await retry(() => destColl.saveShard(destShard));

            await retry(() => destColl.rebuildAndSaveShardMerkleTree(destShard));

            if (progressCallback) {
                progressCallback(`Copied ${result.copiedFiles} files, ${result.copiedRecords} records`);
            }
        }

        await batchSortIndexManager.commitChanges();
    }
}

//
// Replicates the media file database to another storage.
//
export async function replicate(
    sourceAssetStorage: IStorage,
    sourceMetadataStorage: IStorage,
    sourceBsonDatabase: BsonDatabase,
    sourceUuidGenerator: IUuidGenerator,
    sourceTimestampProvider: ITimestampProvider,
    destAssetStorage: IStorage,
    destMetadataStorage: IStorage,
    options?: IReplicateOptions,
    progressCallback?: ProgressCallback
): Promise<IReplicationResult> {

    const merkleTree = await retry(() => loadMerkleTree(sourceMetadataStorage));
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
    // This has to be created before files.dat is saved.
    //
    const destDb = createMediaFileDatabase(
        destAssetStorage,
        sourceUuidGenerator,
        sourceTimestampProvider
    );

    const treeExists = await retry(() => merkleTreeExists(destMetadataStorage));
    if (treeExists) {
        log.verbose("Loading existing destination database...");
        await loadDatabase(destDb.assetStorage, destDb.metadataCollection);
    }
    else {
        log.verbose("Creating new destination database...");
        //
        // This is need because it will create the sort indexes and other things.
        //
        await createDatabase(destAssetStorage, destMetadataStorage, sourceUuidGenerator, destDb.metadataCollection, merkleTree.id);
    }
    
    //
    // Load the destination database that might have been just created.
    //
    let destMerkleTree = await retry(() => loadMerkleTree(destMetadataStorage));
    if (!destMerkleTree) {
        throw new FatalError(`Failed to load merkle tree from destination database.`);
    }
    
    if (!options?.force && destMerkleTree.id !== merkleTree.id) {
        throw new FatalError(
            `You are trying to replicate to a database that has a different ID than the source database.\n` +
            `Source database ID: ${merkleTree.id}\n` +
            `Destination database ID: ${destMerkleTree.id}\n` + 
            `The destination database is not related to the source database.\n` +
            `Use the --force flag to proceed anyway.`
        );
    }
    
    //
    // If force is used and IDs don't match, update destination files merkle tree UUID to match source.
    //
    if (options?.force && destMerkleTree.id !== merkleTree.id) {
        destMerkleTree.id = merkleTree.id;
    }
    
    //
    // Copy database metadata from source to destination.
    //
    if (merkleTree.databaseMetadata) {
        destMerkleTree.databaseMetadata = { ...merkleTree.databaseMetadata };
    }
    else {
        destMerkleTree.databaseMetadata = { filesImported: 0 };
    }
    
    //
    // Set isPartial flag if partial replication is enabled.
    //
    if (options?.partial) {
        destMerkleTree.databaseMetadata.isPartial = true;
    }

    await replicateFiles(
        merkleTree,
        destMerkleTree,
        destAssetStorage,
        destMetadataStorage,
        sourceAssetStorage,
        options,
        progressCallback,
        result
    );

    await replicateBsonDatabase(
        sourceBsonDatabase,
        destDb.bsonDatabase,
        sourceAssetStorage,
        destAssetStorage,
        progressCallback,
        result
    );
    
    return result;
}
