import { IBsonDatabase, IBsonCollection, IStorage } from "storage";
import { BlockGraph, DatabaseUpdate, IBlock, IFieldUpdate, IUpsertUpdate, IDeleteUpdate, IDataElement } from "adb";
import { MediaFileDatabase } from "api";
import { exit } from "node-utils";
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";
import { log } from "utils";

//
// Options for the debug build-snapshot command.
//
export interface IDebugBuildSnapshotCommandOptions extends IBaseCommandOptions {
    force?: boolean;
}

//
// Gets all blocks from storage.
//
export async function getAllBlocks<DataElementT extends IDataElement>(
    blockGraph: BlockGraph<DataElementT>,
    storage: IStorage
): Promise<IBlock<DataElementT>[]> {
    const allBlocks: IBlock<DataElementT>[] = [];
    let next: string | undefined;
    
    do {
        const listResult = await storage.listFiles("blocks", 1000, next);
        for (const blockId of listResult.names) {
            const block = await blockGraph.getBlock(blockId);
            if (block) {
                allBlocks.push(block);
            }
        }
        next = listResult.next;
    } while (next);
    
    return allBlocks;
}

//
// Finds all blocks that are "behind" (reachable from) the given head blocks by traversing backwards.
//
export async function getBlocksBehindHeads<DataElementT extends IDataElement>(
    blockGraph: BlockGraph<DataElementT>,
    headBlockIds: string[]
): Promise<Set<string>> {
    const behindBlocks = new Set<string>();
    const queue = [...headBlockIds];
    
    while (queue.length > 0) {
        const blockId = queue.shift()!;
        if (behindBlocks.has(blockId)) continue;
        
        behindBlocks.add(blockId);
        const block = await blockGraph.getBlock(blockId);
        if (block) {
            queue.push(...block.prevBlocks);
        }
    }
    
    return behindBlocks;
}

//
// Finds blocks that need to be applied (not yet behind the stored head hashes).
// Uses brute force algorithm for now.
//
// TODO: Want a more efficient algorithm that doesn't require loading all blocks each time.
//       It's not that difficult. We just need to track the new blocks we are copying into the local
//       database and by definition these are blocks that have not yet been applied. So we just
//       need only those blocks and we won't need to run this search of all blocks.
//
export async function getBlocksToApply<DataElementT extends IDataElement>(
    blockGraph: BlockGraph<DataElementT>,
    storage: IStorage,
    storedHeadHashes: string[]
): Promise<IBlock<DataElementT>[]> {
    // Get all blocks in the graph
    const allBlocks = await getAllBlocks(blockGraph, storage);    
    if (storedHeadHashes.length === 0) {
        // No stored head hashes means all blocks are unapplied.
        return allBlocks;
    }
    
    // Find all blocks that are behind (already applied based on) the stored head hashes.
    const behindBlocks = await getBlocksBehindHeads(blockGraph, storedHeadHashes);
    
    // Find blocks that are NOT behind the stored head hashes (unapplied)
    const unappliedBlocks = allBlocks.filter(block => !behindBlocks.has(block._id));    
    if (unappliedBlocks.length === 0) {
        return [];
    }
    
    // Find the minimum timestamp of unapplied blocks
    const minTimestamp = Math.min(...unappliedBlocks.flatMap(block => 
        block.data.map((update: any) => update.timestamp)
    ));
    
    // Return all blocks (applied or unapplied) that have updates at or after the minimum timestamp
    return allBlocks.filter(block => block.data[0].timestamp >= minTimestamp);
}

//
// Applies database updates to the BSON database.
//
export async function applyDatabaseUpdates(
    bsonDatabase: IBsonDatabase,
    updates: DatabaseUpdate[]
): Promise<void> {
    for (const update of updates) {
        try {
            const collection = bsonDatabase.collection(update.collection);
            
            switch (update.type) {
                case "upsert": {
                    const upsertUpdate = update as IUpsertUpdate;
                    await collection.replaceOne(upsertUpdate._id, upsertUpdate.document, { upsert: true });
                    break;
                }
                
                case "field": {
                    const fieldUpdate = update as IFieldUpdate;
                    await collection.updateOne(fieldUpdate._id, { [fieldUpdate.field]: fieldUpdate.value }, { upsert: true });
                    break;
                }
                
                case "delete": {
                    await collection.deleteOne(update._id);
                    break;
                }
                
                default:
                    const _exhaustiveCheck: never = update;
                    console.warn(`Unknown update type: ${(_exhaustiveCheck as DatabaseUpdate).type}`);
            }
        } catch (error) {
            console.warn(`Error applying update ${update.type} for ${update._id}:`, error);
        }
    }
}

//
// Builds or updates the BSON database and sort indexes from the block graph.
//
export async function debugBuildSnapshotCommand(options: IDebugBuildSnapshotCommandOptions): Promise<void> {
    console.log("Building snapshot from block graph...");
    
    const { database } = await loadDatabase(options.db!, options, true, true);
    
    // Get the asset database and storage
    const assetDatabase = database.getAssetDatabase();
    const storage = assetDatabase.getMetadataStorage();
    
    // Load the block graph
    const blockGraph = new BlockGraph<DatabaseUpdate>(storage);
    await blockGraph.loadHeadBlocks();
    const headBlockIds = blockGraph.getHeadBlockIds();
            
    // Get the last head hashes
    const currentHeadHashes = await blockGraph.getHeadHashes();
    
    log.verbose(`Current block graph head blocks: ${headBlockIds.length > 0 ? headBlockIds.join(", ") : "none"}`);
    log.verbose(`Last head hashes: ${currentHeadHashes.length > 0 ? currentHeadHashes.join(", ") : "none"}`);
    
    // Determine what needs to be rebuilt
    const metadataExists = await storage.dirExists("metadata");
    
    let rebuildFromScratch = false;
    
    if (options.force) {
        console.log("Force flag specified, rebuilding from scratch");
        rebuildFromScratch = true;
    } else if (!metadataExists || currentHeadHashes.length === 0) {
        console.log("No metadata directory or head hashes found, rebuilding from scratch");
        rebuildFromScratch = true;
    } else {
        console.log("Updating existing database with new blocks");
    }
    
    let blocksToProcess: IBlock<DatabaseUpdate>[] = [];
    
    if (rebuildFromScratch) {
        // Delete metadata directory and clear head hashes
        if (await storage.dirExists("metadata")) {
            log.verbose(`Deleting metadata directory`);
            await storage.deleteDir("metadata");
        }
        await blockGraph.clearHeadHashes();
        
        // Get all blocks from storage.
        let next: string | undefined;
        do {
            const listResult = await storage.listFiles("blocks", 1000, next);
            for (const blockId of listResult.names) {
                const block = await blockGraph.getBlock(blockId);
                if (block) {
                    blocksToProcess.push(block);
                }
            }
            next = listResult.next;
        } while (next);
    } 
    else {
        // Incremental update: get blocks that haven't been applied yet
        blocksToProcess = await getBlocksToApply(blockGraph, storage, currentHeadHashes);        
    }
    
    // Extract updates from new blocks.
    const allUpdates = blocksToProcess.map(b => b.data).flat();

    // Sort updates by timestamp (database updates are idempotent)
    allUpdates.sort((a, b) => a.timestamp - b.timestamp);
    
    console.log(`Processing ${blocksToProcess.length} blocks with ${allUpdates.length} database updates`);
    
    if (allUpdates.length > 0) {
        log.verbose("Applying database updates...");
        await applyDatabaseUpdates(database.getBsonDatabase(), allUpdates);
        log.verbose("Database updates applied successfully");
    }
    
    // Update head hashes to current block graph heads
    if (headBlockIds.length > 0) {
        await blockGraph.setHeadHashes(headBlockIds);
        log.verbose(`Updated head hashes to: ${headBlockIds.join(", ")}`);
    }
    
    console.log("Snapshot build completed successfully");
        
    await exit(0);
}