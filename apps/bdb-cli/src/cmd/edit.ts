import { loadDatabase } from './database-loader';
import pc from "picocolors";

interface IEditCommandOptions {
    verbose?: boolean;
}

//
// Parses a field value based on its type
//
function parseFieldValue(value: string, fieldType: string): any {
    switch (fieldType.toLowerCase()) {
        case 'number':
            const num = Number(value);
            if (isNaN(num)) {
                throw new Error(`Invalid number value: ${value}`);
            }
            return num;

        case 'string':
            return value;

        case 'date':
            const date = new Date(value);
            if (isNaN(date.getTime())) {
                throw new Error(`Invalid date value: ${value}`);
            }
            return date.toISOString();

        case 'boolean':
            const lowerValue = value.toLowerCase();
            if (lowerValue === 'true' || lowerValue === '1' || lowerValue === 'yes') {
                return true;
            }
            if (lowerValue === 'false' || lowerValue === '0' || lowerValue === 'no') {
                return false;
            }
            throw new Error(`Invalid boolean value: ${value}. Expected true/false, 1/0, or yes/no`);

        case 'string-array':
            // Split by comma and trim each element
            return value.split(',').map(item => item.trim()).filter(item => item.length > 0);

        case 'json':
            try {
                return JSON.parse(value);
            } catch (error) {
                throw new Error(`Invalid JSON value: ${value}. Error: ${error instanceof Error ? error.message : 'Unknown error'}`);
            }

        default:
            throw new Error(`Unknown field type: ${fieldType}. Supported types: number, string, date, boolean, string-array, json`);
    }
}

//
// Converts a dot-notation field path (e.g., "user.name") into a nested object structure
// Example: setNestedField({}, "user.name", "John") -> { user: { name: "John" } }
//
function setNestedField(obj: any, path: string, value: any): any {
    const parts = path.split('.');
    let current = obj;
    
    for (let i = 0; i < parts.length - 1; i++) {
        const part = parts[i];
        if (!(part in current) || typeof current[part] !== 'object' || current[part] === null || Array.isArray(current[part])) {
            current[part] = {};
        }
        current = current[part];
    }
    
    current[parts[parts.length - 1]] = value;
    return obj;
}

//
// Edits a field in a record from a collection
//
export async function editCommand(
    dbPath: string,
    collectionName: string,
    recordId: string,
    fieldName: string,
    fieldType: string,
    fieldValue: string,
    options: IEditCommandOptions
): Promise<void> {
    const database = await loadDatabase(dbPath, options.verbose);
    const collection = database.collection(collectionName);

    // Check if record exists
    const existingRecord = await collection.getOne(recordId);
    if (!existingRecord) {
        console.error(pc.red(`Record '${recordId}' not found in collection '${collectionName}'`));
        process.exit(1);
    }

    // Parse the field value based on type
    const parsedValue = parseFieldValue(fieldValue, fieldType);

    // Build the update object, handling nested field paths
    const updates: any = {};
    setNestedField(updates, fieldName, parsedValue);

    // Update the record
    const updated = await collection.updateOne(recordId, updates);
    
    if (!updated) {
        console.error(pc.red(`Failed to update record '${recordId}'`));
        process.exit(1);
    }

    console.log(pc.green(`✓ Successfully updated field '${fieldName}' in record '${recordId}'`));
    
    if (options.verbose) {
        console.log(pc.cyan(`\nUpdated value:`));
        console.log(pc.white(JSON.stringify(parsedValue, null, 2)));
    }
}

