import { loadDatabase } from './database-loader';
import pc from "picocolors";

interface ICollectionsCommandOptions {
    verbose?: boolean;
}

//
// Lists all collections in the BSON database
//
export async function collectionsCommand(dbPath: string, options: ICollectionsCommandOptions): Promise<void> {
    const database = await loadDatabase(dbPath, options.verbose);
    
    // Get list of collections
    const collections = await database.collections();
    
    console.log(pc.green(`Number of collections: ${collections.length}`));
    
    if (collections.length > 0) {
        console.log(pc.cyan("\nCollections:"));
        for (const collectionName of collections) {
            console.log(pc.white(`  ${collectionName}`));
        }
    } 
    else {
        console.log(pc.yellow("No collections found in this database."));
    }
    
    process.exit(0);
}


