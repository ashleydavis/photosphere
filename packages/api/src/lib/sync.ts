import { IBsonCollection, IBsonDatabase, IInternalRecord, IRecord, loadCollectionMerkleTree, loadDatabaseMerkleTree, loadShardMerkleTree, mergeRecords } from "bdb";
import { addItem, findMerkleTreeDifferences, getItemInfo, IMerkleTree, MerkleNode, SortNode, traverseTreeAsync } from "merkle-tree";
import { IStorage, StoragePrefixWrapper } from "storage";
import { MediaFileDatabase } from "./media-file-database";
import { acquireWriteLock, releaseWriteLock } from "./write-lock";
import { loadMerkleTree, loadOrCreateMerkleTree, saveMerkleTree } from "./tree";
import { retry, log } from "utils";
import { computeHash } from "adb";

//
// Syncs between source and target databases.
//
export async function syncDatabases(sourceDb: MediaFileDatabase, targetDb: MediaFileDatabase): Promise<void> {

    //
    // Pull incoming files.
    //
    if (!await acquireWriteLock(sourceDb.getAssetStorage(), sourceDb.sessionId)) { //todo: Don't need write lock if nothing to pull.
        throw new Error(`Failed to acquire write lock for source database.`);
    }

    try {
        // Push files from target to source (effectively pulls files from target into source).
        // We are pulling files into the sourceDb, so need the write lock on the source db.
        await pushFiles(targetDb, sourceDb);
        await syncDatabase(targetDb, sourceDb);
    }
    finally {
        await releaseWriteLock(sourceDb.getAssetStorage());
    }

    //
    // Push outgoing files.
    //
    if (!await acquireWriteLock(targetDb.getAssetStorage(), targetDb.sessionId)) { //todo: Don't need write lock if nothing to push.
        throw new Error(`Failed to acquire write lock for target database.`);
    }

    try {
        // Push files from source to target.
        // Need the write lock in the target database.
        await pushFiles(sourceDb, targetDb);
        await syncDatabase(sourceDb, targetDb);
    } 
    finally {
        await releaseWriteLock(targetDb.getAssetStorage());
    }
}

//
// Pushes from source db to target db for a particular device based
// on missing files detected by comparing source and target merkle trees.
//
// TODO: Need a faster algorithm to traverse each tree comparing nodes and trying to make them the same.
//
async function pushFiles(sourceDb: MediaFileDatabase, targetDb: MediaFileDatabase): Promise<void> {
    const sourceStorage = sourceDb.getAssetStorage();
    const targetStorage = targetDb.getAssetStorage();

    //
    // Load the merkle tree.
    //
    const sourceMerkleTree = await retry(() => loadMerkleTree(sourceDb.getMetadataStorage()));
    if (!sourceMerkleTree) {
        throw new Error("Failed to load source merkle tree.");
    }

    let targetMerkleTree = await retry(() => loadOrCreateMerkleTree(targetDb.getMetadataStorage(), targetDb.uuidGenerator));
   
    let filesCopied = 0;
    let filesProcessed = 0;

    // 
    // Copies a single file if necessary.
    //
    const copyFile = async (fileName: string, sourceHash: Buffer, sourceSize: number, sourceModified: Date): Promise<void> => {
        const targetFileInfo = getItemInfo(targetMerkleTree!, fileName);        
        if (targetFileInfo) {
            // File exists and so there is no need to copy it.
            // Just assume the target file is the same and ok. 
            // If it were different, it could only be from corruption, because files are immutable.
            // If the file is corrupted a verify/repair is needed.
            return;
        }

        // Get file info from source.
        const sourceFileInfo = await sourceStorage.info(fileName);
        if (!sourceFileInfo) {
            throw new Error(`Failed to find file ${fileName} in source database.`);
        }
        
        // Copy file from source to target.
        const readStream = sourceStorage.readStream(fileName);
        await targetStorage.writeStream(fileName, sourceFileInfo.contentType, readStream);

        const copiedFileInfo = await targetStorage.info(fileName);
        if (!copiedFileInfo) {
            throw new Error(`Failed to copy ${fileName} to target db.`);
        }

        const copiedFileHash = await computeHash(targetStorage.readStream(fileName));
        if (Buffer.compare(copiedFileHash, sourceHash) !== 0) {
            throw new Error(`Hash of copied file ${fileName} is different to the source hash.`);            
        }
        
        // Add file to target merkle tree.
        targetMerkleTree = addItem(targetMerkleTree, {
            name: fileName,
            hash: copiedFileHash,
            length: copiedFileInfo.length,
            lastModified: copiedFileInfo.lastModified,
        });

        filesCopied++;
        
        log.verbose(`Copied file: ${fileName}`);
    };
    
    // Walk the source merkle tree.
    //todo: This should traverse the merkle tree, not the sort tree. It can use the efficient algorithm to deliver differences.
    await traverseTreeAsync<SortNode>(sourceMerkleTree.sort, async (node: SortNode): Promise<boolean> => {
        if (!node.name) {
            // Skip intermediate nodes.
            return true;
        }

        filesProcessed++;

        // Copy file to target, if necessary.
        await retry(() => copyFile(node.name!, node.contentHash!, node.size, node.lastModified!));
        
        // Save target merkle tree every 100 files.
        if (filesCopied % 100 === 0) {
            await retry(() => saveMerkleTree(targetMerkleTree, targetDb.getMetadataStorage()))
        }
        
        return true;
    });
    
    // Save the target merkle tree one final time.
    await retry(() => saveMerkleTree(targetMerkleTree, targetDb.getMetadataStorage()))
    
    log.info(`Push completed: ${filesCopied} files copied out of ${filesProcessed} processed`);
}


//
// Generator to extract leaf node names from MerkleNode arrays.
//
function* iterateLeaves(nodes: MerkleNode[]): Generator<string> { //todo: This could be a shared function in the merkle-tree package.
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
// Yields differing records for a specific collection and shard.
//
async function* iterateShardDifferences(
    collectionName: string,
    shardId: string,
    sourceCollection: IBsonCollection<IRecord>,
    targetCollection: IBsonCollection<IRecord>,
    sourceShardTree: IMerkleTree<undefined> | undefined,
    targetShardTree: IMerkleTree<undefined> | undefined
): AsyncGenerator<{ collectionName: string; recordId: string; sourceRecord?: IInternalRecord; targetRecord?: IInternalRecord }> {
    const diff = findMerkleTreeDifferences(sourceShardTree?.merkle, targetShardTree?.merkle);
    
    const sourceShard = await sourceCollection.loadShard(shardId);
    const targetShard = await targetCollection.loadShard(shardId);
    
    // Extract record IDs from both sets to detect modifications
    const recordIdsInTree1 = new Set(iterateLeaves(diff.onlyInTree1));
    const recordIdsInTree2 = new Set(iterateLeaves(diff.onlyInTree2));
    
    // Track record IDs we've already yielded to avoid duplicates
    const seenRecordIds = new Set<string>();
    
    // Process records from tree1
    for (const recordId of recordIdsInTree1) {
        seenRecordIds.add(recordId);
        const normalizedId = recordId.replace(/-/g, ''); //todo: This is a bit ugly.
        const sourceRecord = sourceShard.records.get(normalizedId);
        const targetRecord = targetShard.records.get(normalizedId);
        
        // If record ID appears in both trees, it's modified (different hash)
        // Otherwise, it's only in source
        yield {
            collectionName,
            recordId,
            sourceRecord,
            targetRecord,
        };
    }
    
    // Process records only in tree2 (not already processed above)
    for (const recordId of recordIdsInTree2) {
        if (seenRecordIds.has(recordId)) {
            continue; // Already processed as a modification
        }
        
        const normalizedId = recordId.replace(/-/g, ''); //todo: This is a bit ugly.
        const sourceRecord = sourceShard.records.get(normalizedId);
        const targetRecord = targetShard.records.get(normalizedId);        
        yield {
            collectionName,
            recordId,
            sourceRecord,
            targetRecord,
        };
    }
}

//
// Yields differing records for a specific collection.
//
async function* iterateCollectionDifferences(
    collectionName: string,
    sourceStorage: IStorage,
    targetStorage: IStorage,
    sourceDb: IBsonDatabase,
    targetDb: IBsonDatabase,
    sourceCollectionTree: IMerkleTree<undefined> | undefined,
    targetCollectionTree: IMerkleTree<undefined> | undefined
): AsyncGenerator<{ collectionName: string; recordId: string; sourceRecord?: IInternalRecord; targetRecord?: IInternalRecord }> {
    const sourceCollection = sourceDb.collection(collectionName);
    const targetCollection = targetDb.collection(collectionName);
    
    const diff = findMerkleTreeDifferences(sourceCollectionTree?.merkle, targetCollectionTree?.merkle);
    
    // Track shard keys we've seen to avoid duplicates (only track, don't collect all)
    const seenShardKeys = new Set<string>();
    
    // Process shards only in source
    for (const shardId of iterateLeaves(diff.onlyInTree1)) {
        seenShardKeys.add(shardId);
        
        const sourceShardTree = await loadShardMerkleTree(sourceStorage, collectionName, shardId);
        const targetShardTree = await loadShardMerkleTree(targetStorage, collectionName, shardId);
        if (!sourceShardTree && !targetShardTree) {
            continue;
        }
        
        yield* iterateShardDifferences(collectionName, shardId, sourceCollection, targetCollection, sourceShardTree, targetShardTree);
    }
    
    // Process shards only in target or modified
    for (const shardId of iterateLeaves(diff.onlyInTree2)) {
        if (seenShardKeys.has(shardId)) {
            continue; // Already processed
        }
        
        const sourceShardTree = await loadShardMerkleTree(sourceStorage, collectionName, shardId);
        const targetShardTree = await loadShardMerkleTree(targetStorage, collectionName, shardId);        
        if (!sourceShardTree && !targetShardTree) {
            continue;
        }
        
        yield* iterateShardDifferences(collectionName, shardId, sourceCollection, targetCollection, sourceShardTree, targetShardTree);
    }
}

//
// Yields differing records in the BSON database.
//
async function* iterateDatabaseDifferences( //todo: todo this could be in the bdb package and tested.
    sourceStorage: IStorage,
    targetStorage: IStorage,
    sourceDb: IBsonDatabase,
    targetDb: IBsonDatabase,
): AsyncGenerator<{ collectionName: string; recordId: string; sourceRecord?: IInternalRecord; targetRecord?: IInternalRecord }> {
    const sourceDbTree = await loadDatabaseMerkleTree(sourceStorage);
    const targetDbTree = await loadDatabaseMerkleTree(targetStorage);    
    if (!sourceDbTree && !targetDbTree) {
        return;
    }
    
    const diff = findMerkleTreeDifferences(sourceDbTree?.merkle, targetDbTree?.merkle);
    
    // Track collections we've seen to avoid duplicates (only track, don't collect all)
    const seenCollections = new Set<string>();
    
    // Process collections only in source
    for (const collectionName of iterateLeaves(diff.onlyInTree1)) {
        seenCollections.add(collectionName);
        
        const sourceCollectionTree = await loadCollectionMerkleTree(sourceStorage, collectionName);
        const targetCollectionTree = await loadCollectionMerkleTree(targetStorage, collectionName);
        
        if (!sourceCollectionTree && !targetCollectionTree) {
            continue;
        }
        
        yield* iterateCollectionDifferences(collectionName, sourceStorage, targetStorage, sourceDb, targetDb, sourceCollectionTree, targetCollectionTree);
    }
    
    // Process collections only in target or modified
    for (const collectionName of iterateLeaves(diff.onlyInTree2)) {
        if (seenCollections.has(collectionName)) {
            continue; // Already processed
        }
        
        const sourceCollectionTree = await loadCollectionMerkleTree(sourceStorage, collectionName);
        const targetCollectionTree = await loadCollectionMerkleTree(targetStorage, collectionName);
        
        if (!sourceCollectionTree && !targetCollectionTree) {
            continue;
        }
        
        yield* iterateCollectionDifferences(collectionName, sourceStorage, targetStorage, sourceDb, targetDb, sourceCollectionTree, targetCollectionTree);
    }
}

//
// Syncs database records from source to target using hierarchical merkle-tree based diffing.
//
export async function syncDatabase(sourceDb: MediaFileDatabase, targetDb: MediaFileDatabase): Promise<void> {
    const targetMetadataDb = targetDb.getMetadataDatabase();
        
    // Load database merkle trees (they should already exist)
    const sourceStorage = new StoragePrefixWrapper(sourceDb.getAssetStorage(), "metadata"); //todo: It's kind of annoying having to wrap the storage like this.
    const sourceDbTree = await loadDatabaseMerkleTree(sourceStorage);
    const targetStorage = new StoragePrefixWrapper(targetDb.getAssetStorage(), "metadata");
    const targetDbTree = await loadDatabaseMerkleTree(targetStorage);
    
    // Compare root hashes to see if databases are identical
    if (sourceDbTree?.merkle && targetDbTree?.merkle) { //todo: move this comparison to the iterateDatabaseDifferences function.
        if (Buffer.compare(sourceDbTree.merkle.hash, targetDbTree.merkle.hash) === 0) {
            log.info("Databases are identical, no sync needed.");
            return;
        }
    }
    
    log.info("Finding differing records using hierarchical merkle trees...");
    
    let mergedCount = 0;
    
    // Process differing records as they're found (using generator)
    for await (const diff of iterateDatabaseDifferences(sourceStorage, targetStorage, sourceDb.getMetadataDatabase(), targetDb.getMetadataDatabase())) {

        const targetCollection = targetMetadataDb.collection(diff.collectionName);        

        if (diff.sourceRecord && diff.targetRecord) {
            // Both records exist, merge them.
            const merged = mergeRecords(diff.sourceRecord, diff.targetRecord);
            // Use setInternalRecord to preserve all timestamps exactly
            await targetCollection.setInternalRecord(merged);
            mergedCount++;
        } else if (diff.sourceRecord) {
            // Record only in source, insert it with all timestamps preserved
            await targetCollection.setInternalRecord(diff.sourceRecord);
            mergedCount++;
        } else if (diff.targetRecord) {
            // Record only in target, nothing to do (target already has it)
            // This case is less common in sync scenarios
        }
        
        if (mergedCount % 100 === 0) {
            log.verbose(`Merged ${mergedCount} records...`);
        }
    }
    
    if (mergedCount === 0) {
        log.info("No differing records found.");
    }
    else {
        log.info(`Sync completed: ${mergedCount} records merged.`);
    }
}

