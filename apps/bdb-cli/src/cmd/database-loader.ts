import { BsonDatabase } from "bdb";
import type { IBsonDatabase } from "bdb";
import { createStorage } from "storage";
import pc from "picocolors";
import { TimestampProvider } from "utils";

//
// Simple UUID generator for the database
//
const uuidGenerator = {
    generate: () => {
        return crypto.randomUUID();
    }
};

//
// Loads a BSON database from a given path
//
export async function loadDatabase(dbPath: string, verbose: boolean = false): Promise<IBsonDatabase> {
    try {
        if (verbose) {
            console.log(pc.gray(`Loading database from: ${dbPath}`));
        }

        // Create storage based on the path
        const storageResult = createStorage(dbPath);
        const storage = storageResult.storage;

        // Create the BSON database
        const database = new BsonDatabase({
            storage,
            uuidGenerator,
            timestampProvider: new TimestampProvider()
        });

        if (verbose) {
            console.log(pc.green('✓ Database loaded successfully'));
        }

        return database;
    } catch (error) {
        console.error(pc.red(`Failed to load database from ${dbPath}:`));
        if (error instanceof Error) {
            console.error(pc.red(error.message));
        }
        throw error;
    }
}

//
// Helper function to truncate long string values and limit object fields for display
//
export function truncateLongStrings(obj: any, maxLength: number = 100, maxFields: number = 5, showAllFields: boolean = false): any {
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

