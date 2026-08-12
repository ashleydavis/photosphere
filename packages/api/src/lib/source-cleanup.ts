import { IMediaSource, MediaSourceDeleteError } from "./media-source";

//
// Deleting the source file off the device once the asset is safely in the local database.
//
// The rule this file exists to enforce is that nothing is deleted until it has been confirmed
// present in the database, by content hash, not merely reported as imported. A report is a message
// about what a task believed it did; the hash being in the database is the database saying so.
//

//
// An item that the import said it took in, paired with the hash the import computed for it.
//
export interface IImportedSourceItem {
    // The source id to delete if this item turns out to be confirmed.
    sourceId: string;

    // The content hash the import computed, lower-case hex.
    contentHash: string;
}

//
// What a cleanup run actually did.
//
export interface ISourceCleanupResult {
    // The source ids that were deleted.
    deletedSourceIds: string[];

    // The source ids the source refused or failed to delete.
    failedSourceIds: string[];
}

//
// Returns the source ids whose content hash is confirmed present in the local database.
//
// An item whose hash is not in the database is left alone, whatever the import reported: that is
// the difference between deleting the user's only copy and keeping it.
//
export function selectConfirmedForCleanup(importedItems: IImportedSourceItem[], databaseHashes: Set<string>): string[] {
    const confirmed: string[] = [];
    const alreadySelected = new Set<string>();

    for (const importedItem of importedItems) {
        if (!importedItem.contentHash) {
            continue;
        }
        if (!databaseHashes.has(importedItem.contentHash.toLowerCase())) {
            continue;
        }
        if (alreadySelected.has(importedItem.sourceId)) {
            continue;
        }
        alreadySelected.add(importedItem.sourceId);
        confirmed.push(importedItem.sourceId);
    }

    return confirmed;
}

//
// Deletes the given source ids in batches.
//
// Mobile is the reason for the batching: Android and iOS both put a system confirmation in front of
// deleting media the app does not own, so one request per photo would mean one dialog per photo.
//
// A batch the source refuses does not stop the run: the remaining batches are still attempted, and
// every id that was not deleted comes back in the result so the caller can say what is still on the
// device instead of assuming it is gone.
//
export async function runSourceCleanup(source: IMediaSource, sourceIds: string[], batchSize: number): Promise<ISourceCleanupResult> {
    if (batchSize < 1) {
        throw new Error(`Source cleanup batch size must be at least 1, got ${batchSize}.`);
    }

    const deletedSourceIds: string[] = [];
    const failedSourceIds: string[] = [];

    for (let start = 0; start < sourceIds.length; start += batchSize) {
        const batch = sourceIds.slice(start, start + batchSize);
        try {
            await source.deleteItems(batch);
            deletedSourceIds.push(...batch);
        }
        catch (error: any) {
            if (error instanceof MediaSourceDeleteError) {
                // The source named exactly what it could not delete, so the rest of the batch did go.
                const undeletable = new Set(error.sourceIds);
                for (const sourceId of batch) {
                    if (undeletable.has(sourceId)) {
                        failedSourceIds.push(sourceId);
                    }
                    else {
                        deletedSourceIds.push(sourceId);
                    }
                }
            }
            else {
                // The source failed in a way that says nothing about which items went, so none of
                // the batch may be reported as deleted.
                failedSourceIds.push(...batch);
            }
        }
    }

    return { deletedSourceIds, failedSourceIds };
}
