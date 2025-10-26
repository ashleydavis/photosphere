import { loadDatabase } from './database-loader';
import pc from "picocolors";

interface ICollectionCommandOptions {
    verbose?: boolean;
}

//
// Shows details about a specific collection
//
export async function collectionCommand(dbPath: string, collectionName: string, options: ICollectionCommandOptions): Promise<void> {
    try {
        const database = await loadDatabase(dbPath, options.verbose);
        const collection = database.collection(collectionName);
        
        console.log(pc.green(`Collection: ${collectionName}`));
        
        // Get existing shards
        const existingShards = await collection.listExistingShards();
        console.log(pc.cyan(`Number of shards: ${existingShards.length}`));
        
        // Get sort indexes
        const sortIndexes = await collection.listSortIndexes();
        console.log(pc.cyan(`Number of sort indexes: ${sortIndexes.length}`));
        
        // Count total records (approximately, by iterating)
        let recordCount = 0;
        for await (const record of collection.iterateRecords()) {
            recordCount++;
        }
        console.log(pc.cyan(`Total records: ${recordCount}`));
        
        if (sortIndexes.length > 0) {
            console.log(pc.yellow("\nSort indexes:"));
            for (const index of sortIndexes) {
                console.log(pc.white(`  ${index.fieldName} (${index.direction})`));
            }
        }
        
        process.exit(0);
    } catch (error) {
        console.error(pc.red(`Failed to show collection '${collectionName}'`));
        if (error instanceof Error) {
            console.error(pc.red(error.message));
        }
        process.exit(1);
    }
}


