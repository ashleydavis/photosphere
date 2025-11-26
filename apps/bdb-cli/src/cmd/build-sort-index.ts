import { loadDatabase } from './database-loader';
import type { SortDirection, SortDataType } from 'bdb';
import pc from "picocolors";

interface IBuildSortIndexCommandOptions {
    verbose?: boolean;
    rebuild?: boolean;
    type?: string;
}

//
// Builds a sort index for a collection
//
export async function buildSortIndexCommand(
    dbPath: string, 
    collectionName: string, 
    fieldName: string, 
    direction: string, 
    options: IBuildSortIndexCommandOptions
): Promise<void> {
    if (direction !== 'asc' && direction !== 'desc') {
        console.error(pc.red("Direction must be 'asc' or 'desc'."));
        process.exit(1);
        return;
    }

    // Default type to 'string' if not provided
    const typeValue = options.type || 'string';
    if (typeValue !== 'date' && typeValue !== 'string' && typeValue !== 'number') {
        console.error(pc.red("Type must be 'date', 'string', or 'number'."));
        process.exit(1);
        return;
    }
    const type = typeValue as SortDataType;

    const database = await loadDatabase(dbPath, options.verbose);
    const collection = database.collection(collectionName);
    
    // Check if the index already exists
    const hasIndex = await collection.hasIndex(fieldName, direction as SortDirection);
    
    if (hasIndex && !options.rebuild) {
        console.log(pc.yellow(`Sort index for ${fieldName}/${direction} already exists.`));
        console.log(pc.yellow("Use --rebuild to rebuild the index."));
        process.exit(0);
        return;
    }

    if (hasIndex && options.rebuild) {
        console.log(pc.yellow(`Rebuilding sort index for ${fieldName}/${direction}...`));
        // Delete the existing index first
        await collection.deleteSortIndex(fieldName, direction as SortDirection);
    } else if (!hasIndex) {
        console.log(pc.green(`Building sort index for ${fieldName}/${direction}...`));
    }

    // Use ensureSortIndex which will create and build the index if it doesn't exist
    // After deletion (rebuild case), it will also create and build
    const startTime = Date.now();
    await collection.ensureSortIndex(fieldName, direction as SortDirection, type);
    const endTime = Date.now();
    const duration = endTime - startTime;

    // Load the index to get statistics
    const finalIndex = await collection.loadSortIndex(fieldName, direction as SortDirection);
    if (finalIndex) {
        const sortedRecords = await collection.getSorted(fieldName, direction as SortDirection);
        console.log(pc.green("\n✓ Sort index built successfully!"));
        console.log(pc.cyan("\nIndex statistics:"));
        console.log(pc.white(`  Total records: ${sortedRecords.totalRecords}`));
        console.log(pc.white(`  Total pages: ${sortedRecords.totalPages}`));
        console.log(pc.white(`  Time taken: ${(duration / 1000).toFixed(2)}s`));
    } else {
        console.log(pc.green("\n✓ Sort index built successfully!"));
        console.log(pc.white(`  Time taken: ${(duration / 1000).toFixed(2)}s`));
    }
    
    process.exit(0);
}

