import { loadDatabase } from './database-loader';
import type { SortDirection } from 'bdb';
import pc from "picocolors";

interface ISortIndexCommandOptions {
    verbose?: boolean;
}

//
// Visualizes the structure of a specific sort index
//
export async function sortIndexCommand(dbPath: string, collectionName: string, fieldName: string, direction: string, options: ISortIndexCommandOptions): Promise<void> {
    if (direction !== 'asc' && direction !== 'desc') {
        console.error(pc.red("Direction must be 'asc' or 'desc'."));
        process.exit(1);
        return;
    }

    const database = await loadDatabase(dbPath, options.verbose);
    const collection = database.collection(collectionName);
    
    // Check if the index exists
    const hasIndex = await collection.hasIndex(fieldName, direction as SortDirection);
    
    console.log(pc.green(`Collection: ${collectionName}`));
    console.log(pc.green(`Field: ${fieldName}`));
    console.log(pc.green(`Direction: ${direction}`));
    console.log(pc.green(`Index exists: ${hasIndex ? 'Yes' : 'No'}`));
    
    if (hasIndex) {       
        // Try to get some records to show index structure
        const sortedRecords = await collection.getSorted(fieldName, direction as SortDirection);
        
        console.log(pc.cyan("\nIndex statistics:"));
        console.log(pc.white(`  Total records: ${sortedRecords.totalRecords}`));
        console.log(pc.white(`  Total pages: ${sortedRecords.totalPages}`));
        console.log(pc.white(`  Current page: ${sortedRecords.currentPageId}`));
        
        if (sortedRecords.records.length > 0) {
            console.log(pc.cyan(`\nFirst ${Math.min(5, sortedRecords.records.length)} records (sorted by ${fieldName}/${direction}):`));
            for (let i = 0; i < Math.min(5, sortedRecords.records.length); i++) {
                const record = sortedRecords.records[i];
                const fieldValue = (record as any)[fieldName];
                console.log(pc.white(`  ${(record as any)._id}: ${fieldValue}`));
            }
        }

        // Load the sort index from the collection
        const sortIndex = await collection.loadSortIndex(fieldName, direction as SortDirection);        
        if (sortIndex) {
            // Display the btree structure
            const treeVisualization = await sortIndex.visualizeTree();
            console.log(pc.cyan("\nB-Tree Structure:"));
            console.log(pc.white(treeVisualization));

            // Collect all page IDs by traversing through all pages
            const pageIds: string[] = [];
            let currentPage = await collection.getSorted(fieldName, direction as SortDirection);
            
            if (currentPage.currentPageId) {
                pageIds.push(currentPage.currentPageId);
                
                // Traverse through all pages using nextPageId
                while (currentPage.nextPageId) {
                    currentPage = await collection.getSorted(fieldName, direction as SortDirection, currentPage.nextPageId);
                    if (currentPage.currentPageId) {
                        pageIds.push(currentPage.currentPageId);
                    }
                }
            }

            // Display all page IDs numbered from page 1
            if (pageIds.length > 0) {
                console.log(pc.cyan("\nAll Page IDs:"));
                pageIds.forEach((pageId, index) => {
                    console.log(pc.white(`  Page ${index + 1}: ${pageId}`));
                });
            }
        }

    } else {
        console.log(pc.yellow("Index does not exist."));
    }
    
    process.exit(0);
}

