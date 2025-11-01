import { loadDatabase } from './database-loader';
import { listShards } from 'bdb';
import { createStorage } from 'storage';
import pc from "picocolors";

interface IShardsCommandOptions {
    verbose?: boolean;
}

//
// Lists all shards in a collection
//
export async function shardsCommand(dbPath: string, collectionName: string, options: IShardsCommandOptions): Promise<void> {
    try {
        const database = await loadDatabase(dbPath, options.verbose);
        const collection = database.collection(collectionName);
        
        // Get storage to list shards
        const storageResult = createStorage(dbPath);
        const existingShards = await listShards(storageResult.storage, collectionName);
        
        console.log(pc.green(`Collection: ${collectionName}`));
        console.log(pc.green(`Number of existing shards: ${existingShards.length}`));
        
        if (existingShards.length > 0) {
            console.log(pc.cyan("\nExisting shard IDs:"));
            for (const shardId of existingShards) {
                console.log(pc.white(`  ${shardId}`));
            }
        } 
        else {
            console.log(pc.yellow("No shards found for this collection."));
        }
        
        process.exit(0);
    } catch (error) {
        console.error(pc.red(`Failed to list shards for collection '${collectionName}'`));
        if (error instanceof Error) {
            console.error(pc.red(error.message));
        }
        process.exit(1);
    }
}


