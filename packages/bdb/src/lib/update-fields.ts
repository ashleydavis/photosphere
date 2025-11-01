//
// Recursively updates fields by merging updates into existing fields.
// Treats input data as immutable and returns a new object with updated fields.
// Handles nested objects recursively, and deletions (undefined values).
//
export function updateFields(oldFields: any, updates: any): any {
    // If oldFields is undefined/null, start with empty object.
    if (!oldFields || typeof oldFields !== 'object' || Array.isArray(oldFields)) {
        oldFields = {};
    }

    // If no updates, return the original fields.
    if (!updates || Object.keys(updates).length === 0) {
        return oldFields;
    }

    // Create a new root object for immutability.
    const updatedFields = { ...oldFields };

    for (const key in updates) {
        if (updates[key] === undefined) {
            // Field is being deleted
            delete updatedFields[key];
        } 
        else {
            const newValue = updates[key];
            const oldValue = updatedFields[key];

            // Check if both old and new values are nested objects (not arrays)
            const isNewObject = typeof newValue === 'object'  && newValue !== null && !Array.isArray(newValue);           
            const isOldObject = oldValue && typeof oldValue === 'object' && !Array.isArray(oldValue);
            if (isNewObject && isOldObject) {
                // Both are nested objects - recurse
                updatedFields[key] = updateFields(oldValue, newValue);
            } 
            else {
                // Replace the field value (including when converting to/from object)
                updatedFields[key] = newValue;
            }
        }
    }

    return updatedFields;
}
