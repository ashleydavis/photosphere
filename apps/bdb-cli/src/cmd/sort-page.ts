import { loadDatabase } from './database-loader';
import type { SortDirection } from 'bdb';
import pc from "picocolors";

interface ISortPageCommandOptions {
    verbose?: boolean;
}

//
// Displays a specific page from a sort index
//
export async function sortPageCommand(dbPath: string, collectionName: string, fieldName: string, direction: string, pageId: string, options: ISortPageCommandOptions): Promise<void> {
    if (direction !== 'asc' && direction !== 'desc') {
        console.error(pc.red("Direction must be 'asc' or 'desc'."));
        process.exit(1);
        return;
    }

    const database = await loadDatabase(dbPath, options.verbose);
    const collection = database.collection(collectionName);
    
    // Get the specific page
    const sortedRecords = await collection.getSorted(fieldName, direction as SortDirection, pageId);
    
    console.log(pc.green(`Collection: ${collectionName}`));
    console.log(pc.green(`Field: ${fieldName}`));
    console.log(pc.green(`Direction: ${direction}`));
    console.log(pc.green(`Page ID: ${pageId}`));
    console.log(pc.green(`Records on this page: ${sortedRecords.records.length}`));
    
    if (sortedRecords.records.length > 0) {
        console.log(pc.cyan("\nRecords on this page:"));
        for (const record of sortedRecords.records) {
            const fieldValue = (record as any)[fieldName];
            console.log(pc.white(`  ${(record as any)._id}: ${fieldValue}`));
            if (options.verbose) {
                console.log(`    ${JSON.stringify(record, null, 4).split('\n').join('\n    ')}`);
            }
        }
    }
    
    console.log(pc.cyan("\nPage navigation:"));
    console.log(pc.white(`  Current page: ${sortedRecords.currentPageId}`));
    console.log(pc.white(`  Total pages: ${sortedRecords.totalPages}`));
    if (sortedRecords.previousPageId) {
        console.log(pc.white(`  Previous page: ${sortedRecords.previousPageId}`));
    }
    if (sortedRecords.nextPageId) {
        console.log(pc.white(`  Next page: ${sortedRecords.nextPageId}`));
    }
    
    process.exit(0);
}

