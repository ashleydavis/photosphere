import { loadDatabase, truncateLongStrings } from './database-loader';
import pc from "picocolors";

interface IShardCommandOptions {
    verbose?: boolean;
    all?: boolean;
    records?: boolean;
}

//
// Deserializes and displays the contents of a specific shard
//
export async function shardCommand(dbPath: string, collectionName: string, shardId: string, options: IShardCommandOptions): Promise<void> {
    try {
        const shardIdNum = parseInt(shardId, 10);
        if (isNaN(shardIdNum)) {
            console.error(pc.red("Shard ID must be a number."));
            process.exit(1);
            return;
        }

        const database = await loadDatabase(dbPath, options.verbose);
        const collection = database.collection(collectionName);
        
        // Load the specific shard
        const shard = await collection.loadShard(shardIdNum);
        
        console.log(pc.green(`Collection: ${collectionName}`));
        console.log(pc.green(`Shard ID: ${shardIdNum}`));
        console.log(pc.green(`Records in shard: ${shard.records.size}`));
        
        if (shard.records.size > 0) {
            if (options.records) {
                console.log(pc.cyan("\nRecord IDs:"));
                for (const [recordId] of shard.records) {
                    console.log(pc.white(`  ${recordId}`));
                }
            } 
            else {
                console.log(pc.cyan("\nRecords:"));
                for (const [recordId, record] of shard.records) {
                    console.log(pc.white(`  ${recordId}:`));
                    const truncatedRecord = truncateLongStrings(record, 100, 5, options.all);
                    console.log(pc.gray(`    ${JSON.stringify(truncatedRecord, null, 4).split('\n').join('\n    ')}`));
                }
            }
        }
        
        process.exit(0);
    } catch (error) {
        console.error(pc.red(`Failed to load shard ${shardId} from collection '${collectionName}'`));
        if (error instanceof Error) {
            console.error(pc.red(error.message));
        }
        process.exit(1);
    }
}


