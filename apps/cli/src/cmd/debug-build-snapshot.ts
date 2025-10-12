import { IStorage } from "storage";
import { BlockGraph, DatabaseUpdate, IBlock, IDataElement } from "adb";
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
// Builds or updates the BSON database and sort indexes from the block graph.
//
export async function debugBuildSnapshotCommand(options: IDebugBuildSnapshotCommandOptions): Promise<void> {
    console.log("Building snapshot from block graph...");
    
    const { database } = await loadDatabase(options.db!, options, false, false);
    
    // Get the asset storage and block graph
    const assetStorage = database.getAssetStorage();
    const blockGraph = database.getBlockGraph();
    const headBlockIds = await blockGraph.getHeadBlockIds();
            
    // Get the last head hashes
    const currentHeadHashes = await blockGraph.getHeadHashes();
    
    log.verbose(`Current block graph head blocks: ${headBlockIds.length > 0 ? headBlockIds.join(", ") : "none"}`);
    log.verbose(`Last head hashes: ${currentHeadHashes.length > 0 ? currentHeadHashes.join(", ") : "none"}`);
    
    let rebuildFromScratch = false;
    
    if (options.force) {
        console.log("Force flag specified, rebuilding from scratch");
        rebuildFromScratch = true;
    } else if (!await assetStorage.dirExists("metadata") || currentHeadHashes.length === 0) {
        console.log("No metadata directory or head hashes found, rebuilding from scratch");
        rebuildFromScratch = true;
    } else {
        console.log("Updating existing database with new blocks");
    }
    
    let blockIdsToProcess: string[] = [];
    
    if (rebuildFromScratch) {
        // Delete metadata directory and clear head hashes
        if (await assetStorage.dirExists("metadata")) {
            log.verbose(`Deleting metadata directory`);
            await assetStorage.deleteDir("metadata");
        }
        await blockGraph.clearHeadHashes();

        // Get all block IDs from storage.
        let next: string | undefined;
        do {
            const listResult = await assetStorage.listFiles("blocks", 1000, next);
            blockIdsToProcess.push(...listResult.names);
            next = listResult.next;
        } while (next);
    } 
    else {
        // Incremental update: get blocks that haven't been applied yet
        const blocksToApply = await getBlocksToApply(blockGraph, assetStorage, currentHeadHashes);
        blockIdsToProcess = blocksToApply.map(block => block._id);
    }
    
    console.log(`Processing ${blockIdsToProcess.length} blocks`);
    
    // Update database to the latest blocks
    await database.updateToLatestBlocks(blockIdsToProcess);
    
    console.log("Snapshot build completed successfully");
        
    await exit(0);
}