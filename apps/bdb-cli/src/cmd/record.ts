import { loadDatabase, truncateLongStrings } from './database-loader';
import pc from "picocolors";

interface IRecordCommandOptions {
    verbose?: boolean;
    all?: boolean;
}

//
// Deserializes and displays a specific record from a collection
//
export async function recordCommand(dbPath: string, collectionName: string, recordId: string, options: IRecordCommandOptions): Promise<void> {
    try {
        const database = await loadDatabase(dbPath, options.verbose);
        const collection = database.collection(collectionName);
        
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
        
        process.exit(0);
    } catch (error) {
        console.error(pc.red(`Failed to retrieve record '${recordId}' from collection '${collectionName}'`));
        if (error instanceof Error) {
            console.error(pc.red(error.message));
        }
        process.exit(1);
    }
}


