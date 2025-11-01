import { IInternalRecord, Metadata } from "./collection";

//
// Checks if a value is a primitive, undefined or null.
//
function isPrimitive(value: any): boolean {
    return typeof value !== 'object' || value === null || value === undefined;
}

//
// A value to be merged.
// A simplified data structure with minimal optional fields.
//
export interface MergeValue {
    //
    // The value to be merged.
    //
    value: any;

    //
    // The metadata for the value.
    //
    metadata: {
        //
        // The timestamp of the value.
        //
        timestamp: number;

        //
        // Metadata for nested fields.
        //
        fields?: {
            [key: string]: Metadata;
        }
    }
}

//
// Merges two sets of fields recursively based on their metadata timestamps.
//
export function mergeFields(value1: MergeValue, value2: MergeValue): MergeValue {

    const allKeys = new Set<string>();
    for (const key in value1.value) {
        allKeys.add(key);
    }
    for (const key in value2.value) {
        allKeys.add(key);
    }

    if (value1.metadata.fields) { // Accounts for deleted fields.
        for (const key in value1.metadata.fields) {
            allKeys.add(key);
        }
    }

    if (value2.metadata.fields) { // Accounts for deleted fields.
        for (const key in value2.metadata.fields) {
            allKeys.add(key);
        }
    }

    const mergeResult: MergeValue = {
        value: {},      
        metadata: {
            // Use Math.min because the root timestamp is a default for fields without explicit timestamps.
            // Using Math.min ensures fields without explicit timestamps don't appear newer than they should be.
            timestamp: Math.min(value1.metadata.timestamp, value2.metadata.timestamp),
            fields: {},
        },
    };

    for (const key of allKeys) {
        const field1 = {
            value: value1.value[key],
            metadata: {
                timestamp: value1.metadata.fields?.[key]?.timestamp ?? value1.metadata.timestamp,
                fields: value1.metadata.fields?.[key]?.fields ?? {},
            },
        };
        const field2 = {
            value: value2.value[key],
            metadata: {
                timestamp: value2.metadata.fields?.[key]?.timestamp ?? value2.metadata.timestamp,
                fields: value2.metadata.fields?.[key]?.fields ?? {},
            }
        };
        const merged = mergeValues(field1, field2);
        mergeResult.value[key] = merged.value;
        mergeResult.metadata.fields![key] = merged.metadata;
    }

    return mergeResult;
}

// 
// Merges two values recursively based on their metadata timestamps.
// If both sides have a timestamp, the one with the newer timestamp wins.
// If one side has a timestamp and the other does not, the one with the timestamp side wins.
//
export function mergeValues(value1: MergeValue, value2: MergeValue): MergeValue {

    const timestamp1 = value1.metadata.timestamp;
    const timestamp2 = value2.metadata.timestamp;

    if (isPrimitive(value1.value) || isPrimitive(value2.value)) {
        if (value1.value === undefined) {
            // There is nothing for value 1, so value 2 wins.
            return value2;
        }
        else if (value2.value === undefined) {
            // There is nothing for value 2, so value 1 wins.
            return value1;
        }

        // Value 1 or value 2 is a primitive, other side can be anything.
        // The one with the newer timestamp wins.
        return timestamp1 > timestamp2 ? value1 : value2;
    }
    else {
        // Both sides are objects. So merge them recursively.
        return mergeFields(value1, value2);
    }   
}

//
// Cleans up empty fields in metadata recursively.
// Returns a new metadata object with empty fields removed.
//
export function cleanupMetadata(metadata: Metadata, timestamp: number): Metadata | undefined {

    const cleanedMetadata: Metadata = {
        timestamp: metadata.timestamp,
    };

    if (metadata.fields) {
        for (const key in metadata.fields) {
            const fieldMetadata = cleanupMetadata(metadata.fields[key], metadata.timestamp || timestamp);
            if (fieldMetadata) {
                if (fieldMetadata.timestamp && fieldMetadata.timestamp > timestamp) {
                    if (!cleanedMetadata.fields) {
                        cleanedMetadata.fields = {};
                    }
                    cleanedMetadata.fields[key] = fieldMetadata;                    
                }
                else if (fieldMetadata.fields && Object.keys(fieldMetadata.fields).length > 0) {
                    if (!cleanedMetadata.fields) {
                        cleanedMetadata.fields = {};
                    }
                    cleanedMetadata.fields[key] = fieldMetadata;
                }
            }
        }
    }

    if (cleanedMetadata.fields && Object.keys(cleanedMetadata.fields).length > 0) {
        return cleanedMetadata;
    }
    else if (!cleanedMetadata.timestamp || cleanedMetadata.timestamp <= timestamp) {
        return undefined;
    }
    else {
        return cleanedMetadata;
    }
}

//
// Merges two database records, combining their fields based on timestamp.
// Fields with the greater timestamp win. Both records must have the same _id.
// Returns a new IInternalRecord with merged fields and metadata.
//
export function mergeRecords(record1: IInternalRecord, record2: IInternalRecord): IInternalRecord {
    if (record1._id !== record2._id) {
        throw new Error(`Cannot merge records with different IDs: ${record1._id} vs ${record2._id}`);
    }

    const value1 = {
        value: record1.fields,
        metadata: {
            timestamp: record1.metadata.timestamp || 0,
            fields: record1.metadata.fields,
        },
    };
    const value2 = {
        value: record2.fields,
        metadata: {
            timestamp: record2.metadata.timestamp || 0,
            fields: record2.metadata.fields,
        },
    };

    // Merge fields recursively.
    const result = mergeFields(value1, value2);

    // Clean up empty fields in metadata.
    const cleanedMetadata = cleanupMetadata(result.metadata, 0);

    const merged: IInternalRecord = {
        _id: record1._id,
        fields: result.value,
        metadata: cleanedMetadata ?? {}
    };

    return merged;
}
