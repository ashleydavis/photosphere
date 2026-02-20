//
// Manages batch updates for all sort indexes of a collection. Loads each index once,
// applies many sync/remove operations in memory, then flushes once at commitChanges().
//

import type { IInternalRecord, ISortIndexCreationOptions } from './collection';
import type { SortDirection } from './sort-index';
import { BatchSortIndex } from './batch-sort-index';

//
// Provider of sort index list and options so the manager can create BatchSortIndex instances.
//
export interface ISortIndexBatchProvider {
    listSortIndexes(): Promise<Array<{ fieldName: string; direction: SortDirection }>>;
    getSortIndexOptions(): ISortIndexCreationOptions;
}

//
// Manages batch updates for all sort indexes. Call startBatch() to load indexes, then
// syncRecord/removeRecord for each change, then commitChanges() to flush.
//
export class BatchSortIndexManager {
    private readonly indexes = new Map<string, BatchSortIndex>();

    //
    // Creates a manager that will use the provider to list indexes and get options when startBatch() is called.
    //
    constructor(private readonly provider: ISortIndexBatchProvider) {}

    //
    // Loads all sort indexes for the collection and caches them for batch updates. Call before syncRecord/removeRecord.
    //
    async startBatch(): Promise<void> {
        const indexList = await this.provider.listSortIndexes();
        const opts = this.provider.getSortIndexOptions();
        this.indexes.clear();
        for (const { fieldName, direction } of indexList) {
            const batchIndex = new BatchSortIndex({ ...opts, fieldName, direction });
            const loaded = await batchIndex.load();
            if (loaded) {
                this.indexes.set(`${fieldName}_${direction}`, batchIndex);
            }
        }
    }

    //
    // Adds or updates the record in all managed sort indexes. Deferred until commitChanges().
    // Pass undefined oldRecord for insert; pass previous record for update.
    //
    async syncRecord(record: IInternalRecord, oldRecord: IInternalRecord | undefined): Promise<void> {
        for (const index of this.indexes.values()) {
            if (oldRecord === undefined) {
                await index.addRecord(record);
            }
            else {
                await index.updateRecord(record, oldRecord);
            }
        }
    }

    //
    // Removes the record from all managed sort indexes. Deferred until commitChanges().
    //
    async removeRecord(recordId: string, record: IInternalRecord): Promise<void> {
        for (const index of this.indexes.values()) {
            await index.deleteRecord(recordId, record);
        }
    }

    //
    // Flushes all deferred updates on each managed index, then clears the manager's index cache.
    //
    async commitChanges(): Promise<void> {
        for (const index of this.indexes.values()) {
            await index.commitChanges();
        }
        this.indexes.clear();
    }
}
