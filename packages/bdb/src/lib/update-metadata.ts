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

    //
    // PARTIAL FIX. The full one is still to come and has its own plan:
    // docs/plans/new/plan-clock-independent-merge.md.
    //
    // A write is ordered after the record it was applied to, whatever the writing machine's clock
    // says. `timestamp` is that machine's clock reading, while the record's own timestamp came from
    // whichever machine wrote the record, which is usually a different one. On a device running
    // behind that machine, the reading is lower than the record's timestamp even though the write
    // happened later, and the sync merge then reads the edit as the older value and keeps the one it
    // replaced. Nothing reports it: the merged record comes out identical to the record already
    // stored, so the sync reports success and the edit is gone.
    //
    // That is what smoke test 45 was failing on. The emulator runs about 22 seconds behind the host,
    // and the test reaches its edit about 26 seconds after the host writes the record, so the edit
    // was being stamped about 4 seconds above the record and the test passed or failed on that
    // margin. Lifting the write above the record removes the margin, because an edit can no longer
    // be ordered before the value it replaced.
    //
    // What this does NOT fix: two machines editing the same record independently are still ordered
    // against each other by two unrelated wall clocks, so the one with the faster clock still wins
    // whichever wrote last. Removing that needs ordering that does not come from a clock at all
    // (vector clocks or hybrid logical clocks), which is the plan named above.
    //
    // This replaces an early return that skipped stamping altogether when the record was already
    // stamped at or above the writing clock. updateFields writes the new value either way, so that
    // path applied the edit and recorded nothing about when it was made, losing it by a shorter
    // route.
    //
    const writeTimestamp = Math.max(timestamp, (metadata.timestamp ?? 0) + 1);

    // Start with all existing fields, then update/overwrite as needed.
    const existingFields = metadata.fields || {};
    const newFields: { [key: string]: Metadata } = { ...existingFields };

    for (const key in updates) {
        if (updates[key] === undefined) {
            // Field is being deleted - track deletion timestamp.
            newFields[key] = { timestamp: writeTimestamp };
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
            const nestedResult = updateMetadata(oldValue, newValue, existingFields[key] || {}, writeTimestamp);
            
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
            newFields[key] = { timestamp: writeTimestamp };
        }
    }
    
    // Return new metadata with updated fields.
    return {
        timestamp: metadata.timestamp,
        fields: newFields,
    };
}