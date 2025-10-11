import { MediaFileDatabase } from "api";
import { exit } from "node-utils";
import { loadDatabase, IBaseCommandOptions } from "../lib/init-cmd";
import { log } from "utils";
import pc from "picocolors";

//
// Options for the debug show commands.
//
export interface IDebugShowCommandOptions extends IBaseCommandOptions {
    all?: boolean;
    records?: boolean;
}

//
// Helper function to truncate long string values and limit object fields for display
//
function truncateLongStrings(obj: any, maxLength: number = 100, maxFields: number = 5, showAllFields: boolean = false): any {
    if (typeof obj === 'string') {
        if (obj.length > maxLength) {
            return obj.substring(0, maxLength) + '...';
        }
        return obj;
    }
    
    if (Array.isArray(obj)) {
        return obj.map(item => truncateLongStrings(item, maxLength, maxFields, showAllFields));
    }
    
    if (obj !== null && typeof obj === 'object') {
        const entries = Object.entries(obj);
        const result: any = {};
        
        // If showAllFields is true, use all entries; otherwise limit to maxFields
        const limitedEntries = showAllFields ? entries : entries.slice(0, maxFields);
        
        for (const [key, value] of limitedEntries) {
            result[key] = truncateLongStrings(value, maxLength, maxFields, showAllFields);
        }
        
        // If there are more fields than the limit and we're not showing all, add an indicator
        if (!showAllFields && entries.length > maxFields) {
            result['...'] = `${entries.length - maxFields} more fields`;
        }
        
        return result;
    }
    
    return obj;
}

//
// Show collections command - Lists the collections in the BSON database
//
export async function debugShowCollectionsCommand(options: IDebugShowCommandOptions): Promise<void> {
    const { database } = await loadDatabase(options.db!, options, true, true);
    
    const bsonDatabase = database.getBsonDatabase();
    
    // Get list of collections
    const collections = await bsonDatabase.collections();
    
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
    
    await exit(0);
}

//
// Show shards command - Lists the shards in the BSON database
//
export async function debugShowShardsCommand(collectionName: string, options: IDebugShowCommandOptions): Promise<void> {
    if (!collectionName) {
        console.error(pc.red("Collection name is required."));
        console.error(pc.gray("Usage: debug show shards <collection-name>"));
        await exit(1);
        return;
    }

    const { database } = await loadDatabase(options.db!, options, true, true);
    
    const bsonDatabase = database.getBsonDatabase();
    const collection = bsonDatabase.collection(collectionName);
    
    const existingShards = await collection.listExistingShards();
    
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
        
    await exit(0);
}

//
// Show specific shard command - Deserializes and prints one shard
//
export async function debugShowShardCommand(collectionName: string, shardId: string, options: IDebugShowCommandOptions): Promise<void> {
    if (!collectionName || !shardId) {
        console.error(pc.red("Collection name and shard ID are required."));
        console.error(pc.gray("Usage: debug show shard <collection-name> <shard-id>"));
        await exit(1);
        return;
    }

    const shardIdNum = parseInt(shardId, 10);
    if (isNaN(shardIdNum)) {
        console.error(pc.red("Shard ID must be a number."));
        await exit(1);
        return;
    }

    const { database } = await loadDatabase(options.db!, options, true, true);
    
    try {
        const bsonDatabase = database.getBsonDatabase();
        const collection = bsonDatabase.collection(collectionName);
        
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
        
    } catch (error) {
        console.error(pc.red(`Error loading shard ${shardIdNum} from collection '${collectionName}': ${error}`));
        await exit(1);
    }
    
    await exit(0);
}

//
// Show record command - Deserialize and show one record
//
export async function debugShowRecordCommand(collectionName: string, recordId: string, options: IDebugShowCommandOptions): Promise<void> {
    if (!collectionName || !recordId) {
        console.error(pc.red("Collection name and record ID are required."));
        console.error(pc.gray("Usage: debug show record <collection-name> <record-id>"));
        await exit(1);
        return;
    }

    const { database } = await loadDatabase(options.db!, options, true, true);
    
    try {
        const bsonDatabase = database.getBsonDatabase();
        const collection = bsonDatabase.collection(collectionName);
        
        // Get the specific record
        const record = await collection.getOne(recordId);
        
        console.log(pc.green(`Collection: ${collectionName}`));
        console.log(pc.green(`Record ID: ${recordId}`));
        
        if (record) {
            console.log(pc.cyan("\nRecord data:"));
            const truncatedRecord = truncateLongStrings(record, 100, 5, options.all);
            console.log(pc.white(JSON.stringify(truncatedRecord, null, 2)));
        } else {
            console.log(pc.yellow("Record not found."));
        }
        
    } catch (error) {
        console.error(pc.red(`Error retrieving record '${recordId}' from collection '${collectionName}': ${error}`));
        await exit(1);
    }
    
    await exit(0);
}

//
// Show sort indexes command - Show a list of sort indexes
//
export async function debugShowSortIndexesCommand(collectionName: string, options: IDebugShowCommandOptions): Promise<void> {
    if (!collectionName) {
        console.error(pc.red("Collection name is required."));
        console.error(pc.gray("Usage: debug show sort-indexes <collection-name>"));
        await exit(1);
        return;
    }

    const { database } = await loadDatabase(options.db!, options, true, true);
    
    try {
        const bsonDatabase = database.getBsonDatabase();
        const collection = bsonDatabase.collection(collectionName);
        
        // Get list of sort indexes
        const sortIndexes = await collection.listSortIndexes();
        
        console.log(pc.green(`Collection: ${collectionName}`));
        console.log(pc.green(`Number of sort indexes: ${sortIndexes.length}`));
        
        if (sortIndexes.length > 0) {
            console.log(pc.cyan("\nSort indexes:"));
            for (const index of sortIndexes) {
                console.log(pc.white(`  ${index.fieldName} (${index.direction})`));
            }
        }
        
    } catch (error) {
        console.error(pc.red(`Error listing sort indexes for collection '${collectionName}': ${error}`));
        await exit(1);
    }
    
    await exit(0);
}

//
// Show sort index structure command - Visualize the structure of a specific sort index
//
export async function debugShowSortIndexCommand(collectionName: string, fieldName: string, direction: string, options: IDebugShowCommandOptions): Promise<void> {
    if (!collectionName || !fieldName || !direction) {
        console.error(pc.red("Collection name, field name, and direction are required."));
        console.error(pc.gray("Usage: debug show sort-index <collection-name> <field-name> <direction>"));
        console.error(pc.gray("Direction must be 'asc' or 'desc'"));
        await exit(1);
        return;
    }

    if (direction !== 'asc' && direction !== 'desc') {
        console.error(pc.red("Direction must be 'asc' or 'desc'."));
        await exit(1);
        return;
    }

    const { database } = await loadDatabase(options.db!, options, true, true);
    
    try {
        const bsonDatabase = database.getBsonDatabase();
        const collection = bsonDatabase.collection(collectionName);
        
        // Check if the index exists
        const hasIndex = await collection.hasIndex(fieldName, direction as 'asc' | 'desc');
        
        console.log(pc.green(`Collection: ${collectionName}`));
        console.log(pc.green(`Field: ${fieldName}`));
        console.log(pc.green(`Direction: ${direction}`));
        console.log(pc.green(`Index exists: ${hasIndex ? 'Yes' : 'No'}`));
        
        if (hasIndex) {
            // Try to get some records to show index structure
            const sortedRecords = await collection.getSorted(fieldName, direction as 'asc' | 'desc');
            
            console.log(pc.cyan("\nIndex statistics:"));
            console.log(pc.white(`  Total records: ${sortedRecords.totalRecords}`));
            console.log(pc.white(`  Total pages: ${sortedRecords.totalPages}`));
            console.log(pc.white(`  Current page: ${sortedRecords.currentPageId}`));
            
            if (sortedRecords.records.length > 0) {
                console.log(pc.cyan(`\nFirst ${Math.min(5, sortedRecords.records.length)} records (sorted by ${fieldName}):`));
                for (let i = 0; i < Math.min(5, sortedRecords.records.length); i++) {
                    const record = sortedRecords.records[i];
                    const fieldValue = record[fieldName];
                    console.log(pc.white(`  ${record._id}: ${fieldValue}`));
                }
            }
        } else {
            console.log(pc.yellow("Index does not exist. Use 'ensureSortIndex' to create it."));
        }
        
    } catch (error) {
        console.error(pc.red(`Error inspecting sort index '${fieldName}' (${direction}) for collection '${collectionName}': ${error}`));
        await exit(1);
    }
    
    await exit(0);
}

//
// Show sort index page command - Deserialize and show one sort index page
//
export async function debugShowSortIndexPageCommand(collectionName: string, fieldName: string, direction: string, pageId: string, options: IDebugShowCommandOptions): Promise<void> {
    if (!collectionName || !fieldName || !direction || !pageId) {
        console.error(pc.red("Collection name, field name, direction, and page ID are required."));
        console.error(pc.gray("Usage: debug show sort-index-page <collection-name> <field-name> <direction> <page-id>"));
        console.error(pc.gray("Direction must be 'asc' or 'desc'"));
        await exit(1);
        return;
    }

    if (direction !== 'asc' && direction !== 'desc') {
        console.error(pc.red("Direction must be 'asc' or 'desc'."));
        await exit(1);
        return;
    }

    const { database } = await loadDatabase(options.db!, options, true, true);
    
    try {
        const bsonDatabase = database.getBsonDatabase();
        const collection = bsonDatabase.collection(collectionName);
        
        // Get the specific page
        const sortedRecords = await collection.getSorted(fieldName, direction as 'asc' | 'desc', pageId);
        
        console.log(pc.green(`Collection: ${collectionName}`));
        console.log(pc.green(`Field: ${fieldName}`));
        console.log(pc.green(`Direction: ${direction}`));
        console.log(pc.green(`Page ID: ${pageId}`));
        console.log(pc.green(`Records on this page: ${sortedRecords.records.length}`));
        
        if (sortedRecords.records.length > 0) {
            console.log(pc.cyan("\nRecords on this page:"));
            for (const record of sortedRecords.records) {
                const fieldValue = record[fieldName];
                console.log(pc.white(`  ${record._id}: ${fieldValue}`));
                if (options.verbose) {
                    console.log(pc.gray(`    ${JSON.stringify(record, null, 4).split('\n').join('\n    ')}`));
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
        
    } catch (error) {
        console.error(pc.red(`Error retrieving page '${pageId}' from sort index '${fieldName}' (${direction}) for collection '${collectionName}': ${error}`));
        await exit(1);
    }
    
    await exit(0);
}