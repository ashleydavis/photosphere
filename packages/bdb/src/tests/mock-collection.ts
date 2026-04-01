import { IMerkleTree, type HashedItem } from 'merkle-tree';
import { toExternal, toInternal, type IBsonCollection, type IGetAllResult, type IRecord } from '../lib/collection';
import { type IInternalRecord, type IShard } from '../lib/shard';
import type { SortDirection, ISortIndex } from '../lib/sort-index';
import type { IMerkleRef } from '../lib/merkle-tree-ref';

//
// No-op IMerkleRef for mock collections that have no real merkle tree.
//
export class NoopMerkleRef implements IMerkleRef {
    async get(): Promise<IMerkleTree<undefined> | undefined> {
        return undefined;
    }

    async upsert(_item: HashedItem): Promise<void> {
    }

    async remove(_name: string): Promise<void> {
    }

    async commit(): Promise<void> {
    }

    flush(): void {
    }
}

// Mock BsonCollection for testing
export class MockCollection<T extends IRecord> implements IBsonCollection<T> {
    private records: IInternalRecord[] = [];

    constructor(records: T[] = [], timestamp: number = Date.now()) {
        this.records = records.map(record => toInternal<T>(record, timestamp));
    }

    async insertOne(record: T, options?: { timestamp?: number }): Promise<void> {
        const timestamp = options?.timestamp ?? Date.now();
        this.records.push(toInternal<T>(record, timestamp));
    }

    async getOne(id: string): Promise<T | undefined> {
        const internal = this.records.find(r => r._id === id);
        return internal ? toExternal<T>(internal) : undefined;
    }

    async *iterateRecords(): AsyncGenerator<IInternalRecord, void, unknown> {
        for (const record of this.records) {
            yield record;
        }
    }


    async *iterateShards(): AsyncGenerator<Iterable<IInternalRecord>, void, unknown> {
        for (let i = 0; i < this.records.length; i += 2) {
            yield this.records.slice(i, i + 2);
        }
    }

    async getAll(next?: string): Promise<IGetAllResult<T>> {
        return { records: this.records.map(internal => toExternal<T>(internal)), next: undefined };
    }

    async sortIndexes(): Promise<Array<{ fieldName: string; direction: SortDirection }>> {
        throw new Error('Method not implemented.');
    }

    sortIndex(_fieldName: string, _direction: SortDirection): ISortIndex<T> {
        throw new Error('Method not implemented.');
    }

    async updateOne(id: string, updates: Partial<T>, options?: { upsert?: boolean; timestamp?: number }): Promise<boolean> {
        const timestamp = options?.timestamp ?? Date.now();
        const index = this.records.findIndex(r => r._id === id);
        if (index === -1) {
            if (options?.upsert) {
                this.records.push(toInternal<any>({ _id: id, ...updates }, timestamp));
                return true;
            }
            return false;
        }
        // For updates, we need to preserve existing metadata and merge updates
        // This is a simplified version - in real usage, you'd use updateMetadataRecursive
        const existing = this.records[index];
        const updatedFields = { ...existing.fields, ...updates };
        const updated: IInternalRecord = {
            _id: existing._id,
            fields: updatedFields,
            metadata: existing.metadata // Preserve existing metadata
        };
        this.records[index] = updated;
        return true;
    }

    async replaceOne(id: string, record: T, options?: { upsert?: boolean; timestamp?: number }): Promise<boolean> {
        const timestamp = options?.timestamp ?? Date.now();
        const index = this.records.findIndex(r => r._id === id);
        if (index === -1) {
            if (options?.upsert) {
                this.records.push(toInternal<T>(record, timestamp));
                return true;
            }
            return false;
        }
        this.records[index] = toInternal<T>(record, timestamp);
        return true;
    }

    async setInternalRecord(record: IInternalRecord): Promise<void> {
        const index = this.records.findIndex(r => r._id === record._id);
        if (index === -1) {
            // Record doesn't exist, add it
            this.records.push(record);
        } else {
            // Replace existing record, preserving all metadata
            this.records[index] = record;
        }
    }

    async deleteOne(id: string): Promise<boolean> {
        const index = this.records.findIndex(r => r._id === id);
        if (index === -1) {
            return false;
        }
        this.records.splice(index, 1);
        return true;
    }

    async ensureIndex(fieldName: string): Promise<void> {
        throw new Error('Method not implemented.');
    }

    async shutdown(): Promise<void> {
        // No-op for testing
    }

    async drop(): Promise<void> {
        this.records = [];
    }


    shard(_shardId: string): IShard {
        throw new Error('Method not implemented.');
    }

    //
    // Returns the shard id for a record (mock returns '0').
    //
    getShardId(recordId: string): string {
        return '0';
    }

    //
    // Stub dirty — always false for mock.
    //
    dirty(): boolean {
        return false;
    }

    // Stub commit — no-op for mock.
    //
    async commit(): Promise<void> {
    }

    //
    // Stub flush — no-op for mock.
    //
    flush(): void {
    }

    merkleTree(): IMerkleRef {
        return new NoopMerkleRef();
    }
}