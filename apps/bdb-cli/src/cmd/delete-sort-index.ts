import { loadDatabase } from './database-loader';
import type { SortDirection } from 'bdb';
import pc from "picocolors";

interface IDeleteSortIndexCommandOptions {
    verbose?: boolean;
}

//
// Deletes a sort index for a collection
//
export async function deleteSortIndexCommand(
    dbPath: string, 
    collectionName: string, 
    fieldName: string, 
    direction: string, 
    options: IDeleteSortIndexCommandOptions
): Promise<void> {
    if (direction !== 'asc' && direction !== 'desc') {
        console.error(pc.red("Direction must be 'asc' or 'desc'."));
        process.exit(1);
        return;
    }

    const database = await loadDatabase(dbPath, options.verbose);
    const collection = database.collection(collectionName);
    
    // Check if the index exists
    const hasIndex = await collection.hasIndex(fieldName, direction as SortDirection);
    
    if (!hasIndex) {
        console.log(pc.yellow(`Sort index for ${fieldName}/${direction} does not exist.`));
        process.exit(0);
        return;
    }

    console.log(pc.yellow(`Deleting sort index for ${fieldName}/${direction}...`));
    const deleted = await collection.deleteSortIndex(fieldName, direction as SortDirection);
    
    if (deleted) {
        console.log(pc.green(`✓ Sort index deleted successfully!`));
    } else {
        console.log(pc.red(`✗ Failed to delete sort index.`));
        process.exit(1);
    }
    
    process.exit(0);
}

