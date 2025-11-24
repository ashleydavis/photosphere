import { loadDatabase } from './database-loader';
import pc from "picocolors";

interface ISortIndexesCommandOptions {
    verbose?: boolean;
}

//
// Lists all sort indexes for a collection
//
export async function sortIndexesCommand(dbPath: string, collectionName: string, options: ISortIndexesCommandOptions): Promise<void> {
    const database = await loadDatabase(dbPath, options.verbose);
    const collection = database.collection(collectionName);
    
    // Get list of sort indexes
    const sortIndexes = await collection.listSortIndexes();
    
    console.log(pc.green(`Collection: ${collectionName}`));
    console.log(pc.green(`Number of sort indexes: ${sortIndexes.length}`));
    
    if (sortIndexes.length > 0) {
        console.log(pc.cyan("\nSort indexes:"));
        for (const index of sortIndexes) {
            console.log(pc.white(`  ${index.fieldName} (${index.direction})`));
        }
    } else {
        console.log(pc.yellow("No sort indexes found for this collection."));
    }
    
    process.exit(0);
}


