import type { IBsonCollection, IGetAllResult, IRecord, IShard } from '../lib/collection';
import type { SortDirection, SortDataType, IRangeOptions } from '../lib/sort-index';

// Mock BsonCollection for testing
export class MockCollection<T extends IRecord> implements IBsonCollection<T> {
    private records: T[] = [];

    constructor(records: T[] = []) {
        this.records = [...records];
    }

    async insertOne(record: T): Promise<void> {
        this.records.push(record);
    }

    async getOne(id: string): Promise<T | undefined> {
        return this.records.find(r => r._id === id);
    }

    async *iterateRecords(): AsyncGenerator<T, void, unknown> {
        for (const record of this.records) {
            yield record;
        }
    }

    async listExistingShards(): Promise<number[]> {
        // Mock implementation - return sequential shard IDs based on number of records
        const numShards = Math.ceil(this.records.length / 2);
        return Array.from({ length: numShards }, (_, i) => i);
    }

    async *iterateShards(): AsyncGenerator<Iterable<T>, void, unknown> {
        for (let i = 0; i < this.records.length; i += 2) {
            yield this.records.slice(i, i + 2);
        }
    }

    async getAll(next?: string): Promise<IGetAllResult<T>> {
        return { records: this.records, next: undefined };
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

    async updateOne(id: string, updates: Partial<T>, options?: { upsert?: boolean }): Promise<boolean> {
        const index = this.records.findIndex(r => r._id === id);
        if (index === -1) {
            if (options?.upsert) {
                this.records.push({ _id: id, ...updates } as T);
                return true;
            }
            return false;
        }
        this.records[index] = { ...this.records[index], ...updates };
        return true;
    }

    async replaceOne(id: string, record: T, options?: { upsert?: boolean }): Promise<boolean> {
        const index = this.records.findIndex(r => r._id === id);
        if (index === -1) {
            if (options?.upsert) {
                this.records.push(record);
                return true;
            }
            return false;
        }
        this.records[index] = record;
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
        return this.records.filter(r => r[fieldName] === value);
    }

    async findByRange(fieldName: string, direction: SortDirection, options: IRangeOptions): Promise<T[]> {
        // Mock implementation for testing - filter records based on range
        let filteredRecords = this.records.filter(record => {
            const fieldValue = record[fieldName];
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
            const aValue = a[fieldName];
            const bValue = b[fieldName];
            
            if (aValue < bValue) {
                return direction === 'asc' ? -1 : 1;
            }
            if (aValue > bValue) {
                return direction === 'asc' ? 1 : -1;
            }
            return 0;
        });

        return filteredRecords;
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

    async loadShard(shardIndex: number): Promise<IShard<T>> {
        const start = shardIndex * 2;
        const end = start + 2;
        const shardRecords = this.records.slice(start, end);
        return {
            id: shardIndex,
            records: new Map(shardRecords.map(record => [record._id, record])),
        };
    }
}