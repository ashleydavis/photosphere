import { Metadata } from "./collection";

//
// Recursively updates metadata timestamps for fields that were changed.
// For nested objects, creates nested metadata structures.
// Returns a new metadata object (immutable) with only changed parts updated.
//
export function updateMetadata(
    fields: { [key: string]: any },
    updates: { [key: string]: any },
    metadata: Metadata,
    timestamp: number
): Metadata {
    if (!updates || Object.keys(updates).length === 0) {
        // No updates to, return original metadata unchanged.
        return metadata;
    }

    if (metadata && metadata.timestamp && metadata.timestamp >= timestamp) {
        // The metadata is already timestamped at a later time, no point in updating.
        return metadata;
    }

    // Start with all existing fields, then update/overwrite as needed.
    const existingFields = metadata.fields || {};
    const newFields: { [key: string]: Metadata } = { ...existingFields };

    for (const key in updates) {
        if (updates[key] === undefined) {
            // Field is being deleted - track deletion timestamp.
            newFields[key] = { timestamp };
            continue;
        }

        const newValue = updates[key];
        const oldValue = fields[key];
        if (oldValue === newValue) {
            // Value didn't change.
            continue;
        }

        // Value changed - handle nested objects or leaf fields.
        // Check if both old and new values are nested objects (not arrays) - same logic as updateFields.
        const isNewObject = typeof newValue === 'object'  && newValue !== null  && !Array.isArray(newValue);        
        const isOldObject = oldValue && typeof oldValue === 'object' && !Array.isArray(oldValue);
        if (isNewObject && isOldObject) {
            // Both are nested objects - recurse (same logic as updateFields).
            const nestedResult = updateMetadata(oldValue, newValue, existingFields[key] || {}, timestamp);
            
            // Check if nested metadata actually has tracked fields.
            const hasTrackedFields = nestedResult.fields && Object.keys(nestedResult.fields).length > 0;                
            if (hasTrackedFields) {
                // Something changed in the nested object and it has tracked fields.
                newFields[key] = nestedResult;
            } 
            else {
                // No tracked fields - remove from newFields.
                delete newFields[key];
            }
        } 
        else {
            // Primivite value or converting to/from object.
            newFields[key] = { timestamp };
        }
    }
    
    // Return new metadata with updated fields.
    return {
        timestamp: metadata.timestamp,
        fields: newFields,
    };
}