import { IMerkleTree } from 'merkle-tree';
import { IShard, toExternal, toInternal, type IBsonCollection, type IGetAllResult, type IInternalRecord, type IRecord } from '../lib/collection';
import type { SortDirection, SortDataType, IRangeOptions } from '../lib/sort-index';

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

    async getSorted(
        fieldName: string,
        direction: SortDirection,
        pageId?: string
    ): Promise<{
        records: T[];
        totalRecords: number;
        currentPageId: string;
        totalPages: number;
        nextPageId?: string;
        previousPageId?: string;
    }> {
        throw new Error('Method not implemented.');
    }

    async ensureSortIndex(fieldName: string, direction: SortDirection, type: SortDataType): Promise<void> {
        // Mock implementation - no-op for testing
    }

    async loadSortIndex(fieldName: string, direction: SortDirection, type: SortDataType): Promise<void> {
        // Mock implementation - no-op for testing
    }

    async listSortIndexes(): Promise<Array<{ fieldName: string; direction: SortDirection }>> {
        throw new Error('Method not implemented.');
    }

    async deleteSortIndex(fieldName: string, direction: SortDirection): Promise<boolean> {
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

    async hasIndex(fieldName: string, direction: SortDirection): Promise<boolean> {
        throw new Error('Method not implemented.');
    }

    async listIndexes(): Promise<string[]> {
        throw new Error('Method not implemented.');
    }

    async findByIndex(fieldName: string, value: any): Promise<T[]> {
        return this.records.filter(r => r.fields[fieldName] === value).map(internal => toExternal<T>(internal));
    }

    async findByRange(fieldName: string, direction: SortDirection, options: IRangeOptions): Promise<T[]> {
        // Mock implementation for testing - filter records based on range
        let filteredRecords = this.records.filter(record => {
            const fieldValue = record.fields[fieldName];
            if (fieldValue === undefined || fieldValue === null) {
                return false;
            }

            // Check min constraint
            if (options.min !== undefined) {
                if (options.minInclusive === false) {
                    if (fieldValue <= options.min) return false;
                } else {
                    if (fieldValue < options.min) return false;
                }
            }

            // Check max constraint
            if (options.max !== undefined) {
                if (options.maxInclusive === false) {
                    if (fieldValue >= options.max) return false;
                } else {
                    if (fieldValue > options.max) return false;
                }
            }

            return true;
        });

        // Sort the results according to direction
        filteredRecords.sort((a, b) => {
            const aValue = a.fields[fieldName];
            const bValue = b.fields[fieldName];
            
            if (aValue < bValue) {
                return direction === 'asc' ? -1 : 1;
            }
            if (aValue > bValue) {
                return direction === 'asc' ? 1 : -1;
            }
            return 0;
        });

        return filteredRecords.map(internal => toExternal<T>(internal));
    }

    async deleteIndex(fieldName: string): Promise<boolean> {
        throw new Error('Method not implemented.');
    }

    async shutdown(): Promise<void> {
        // No-op for testing
    }

    async drop(): Promise<void> {
        this.records = [];
    }

    getNumShards(): number {
        return Math.ceil(this.records.length / 2);
    }

    loadShard(shardId: string): Promise<IShard> {
        throw new Error('Method not implemented.');
    }
}