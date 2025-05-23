import { expect, test, describe, beforeEach } from '@jest/globals';
import { MockStorage } from './mock-storage';
import { IBsonCollection, IRecord, IShard } from '../lib/bson-database/collection';
import { SortIndex } from '../lib/bson-database/sort-index';

// Test interface
interface TestRecord extends IRecord {
    _id: string;
    name: string;
    score: number;
    category: string;
}

// Mock BsonCollection for testing SortIndex
class MockCollection implements IBsonCollection<TestRecord> {
    private records: TestRecord[] = [];

    constructor(records: TestRecord[] = []) {
        this.records = [...records];
    }

    async insertOne(record: TestRecord): Promise<void> {
        this.records.push(record);
    }

    async getOne(id: string): Promise<TestRecord | undefined> {
        return this.records.find(r => r._id === id);
    }

    async *iterateRecords(): AsyncGenerator<TestRecord, void, unknown> {
        for (const record of this.records) {
            yield record;
        }
    }

    async *iterateShards(): AsyncGenerator<Iterable<TestRecord>, void, unknown> {
        for (let i = 0; i < this.records.length; i += 2) {
            yield this.records.slice(i, i + 2);
        }
    }

    async getAll(next?: string): Promise<{ records: TestRecord[], next?: string }> {
        return { records: this.records, next: undefined };
    }

    async getSorted(fieldName: string, options?: { direction?: 'asc' | 'desc'; page?: number; pageSize?: number }): Promise<{
        records: TestRecord[];
        totalRecords: number;
        currentPage: number;
        totalPages: number;
        nextPage?: number;
        previousPage?: number;
    }> {
        throw new Error('Method not implemented.');
    }

    async ensureSortIndex(fieldName: string, direction?: 'asc' | 'desc'): Promise<void> {
        throw new Error('Method not implemented.');
    }

    async listSortIndexes(): Promise<Array<{ fieldName: string; direction: 'asc' | 'desc' }>> {
        throw new Error('Method not implemented.');
    }

    async deleteSortIndex(fieldName: string, direction: 'asc' | 'desc'): Promise<boolean> {
        throw new Error('Method not implemented.');
    }

    async updateOne(id: string, updates: Partial<TestRecord>, options?: { upsert?: boolean }): Promise<boolean> {
        const index = this.records.findIndex(r => r._id === id);
        if (index === -1) {
            if (options?.upsert) {
                this.records.push({ _id: id, ...updates } as TestRecord);
                return true;
            }
            return false;
        }
        this.records[index] = { ...this.records[index], ...updates };
        return true;
    }

    async replaceOne(id: string, record: TestRecord, options?: { upsert?: boolean }): Promise<boolean> {
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

    async hasIndex(fieldName: string, direction: "asc" | "desc"): Promise<boolean> {
        throw new Error('Method not implemented.');
    }

    async listIndexes(): Promise<string[]> {
        throw new Error('Method not implemented.');
    }

    async findByIndex(fieldName: string, value: any): Promise<TestRecord[]> {
        return this.records.filter(r => r[fieldName] === value);
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

    async loadShard(shardIndex: number): Promise<IShard<TestRecord>> {
        const start = shardIndex * 2;
        const end = start + 2;
        const shardRecords = this.records.slice(start, end);
        return {
            id: shardIndex,
            records: new Map(shardRecords.map(record => [record._id, record])),
            dirty: false,
            lastAccessed: 0,
        };
    }

}

describe('SortIndex', () => {
    let storage: MockStorage;
    let sortIndex: SortIndex<TestRecord>;
    let collection: MockCollection;
    
    const testRecords: TestRecord[] = [
        { _id: '123e4567-e89b-12d3-a456-426614174001', name: 'Record 1', score: 85, category: 'A' },
        { _id: '123e4567-e89b-12d3-a456-426614174002', name: 'Record 2', score: 72, category: 'B' },
        { _id: '123e4567-e89b-12d3-a456-426614174003', name: 'Record 3', score: 90, category: 'A' },
        { _id: '123e4567-e89b-12d3-a456-426614174004', name: 'Record 4', score: 65, category: 'C' },
        { _id: '123e4567-e89b-12d3-a456-426614174005', name: 'Record 5', score: 85, category: 'B' },
    ];
    
    beforeEach(() => {
        storage = new MockStorage();
        collection = new MockCollection(testRecords);
        
        sortIndex = new SortIndex<TestRecord>({
            storage,
            baseDirectory: 'db',
            collectionName: 'test_collection',
            fieldName: 'score',
            direction: 'asc',
            pageSize: 2
        });
    });
    
    test('should initialize the sort index with records', async () => {
        // Initialize the index
        await sortIndex.build(collection);
        
        // Check that the index has been initialized
        const isInitialized = await sortIndex.isBuilt();
        expect(isInitialized).toBe(true);

        await sortIndex.shutdown();
        
        // Check that metadata has been written
        expect(await storage.fileExists('db/sort_indexes/test_collection/score_asc/metadata.dat')).toBe(true);
        
        // B-tree implementation uses UUIDs for page IDs, so we check metadata instead
        expect(await storage.fileExists('db/sort_indexes/test_collection/score_asc/metadata.dat')).toBe(true);
        
        // Force metadata save
        await sortIndex.persistMetadata();
    });
    
    test('should retrieve a page of sorted records', async () => {
        // Initialize the index
        await sortIndex.build(collection);
        
        // Get the first page (page 1 is 1-indexed)
        const result = await sortIndex.getPage(collection, 1);
        
        // Check page contents
        expect(result.records.length).toBe(2);
        expect(result.totalRecords).toBe(5);
        expect(result.currentPage).toBe(1);
        expect(result.totalPages).toBe(3);
        expect(result.nextPage).toBe(2);
        expect(result.previousPage).toBeUndefined();
        
        // Check records are sorted by score (ascending)
        expect(result.records[0].score).toBe(65); // Record 4
        expect(result.records[1].score).toBe(72); // Record 2
    });
    
    test('should find records by exact value', async () => {
        // Initialize the index
        await sortIndex.build(collection);
        
        // Find records with score 85
        const result = await sortIndex.findByValue(85);
        
        // Should find 2 records with score 85
        expect(result.length).toBe(2);
        expect(result.every(r => r.score === 85)).toBe(true);
        
        // Find records with score 90
        const result2 = await sortIndex.findByValue(90);
        
        // Should find 1 record with score 90
        expect(result2.length).toBe(1);
        expect(result2[0].score).toBe(90);
        
        // Find records with a non-existent score
        const result3 = await sortIndex.findByValue(100);
        
        // Should find 0 records
        expect(result3.length).toBe(0);
    });
    
    test('should find records by range', async () => {
        // Initialize the index
        await sortIndex.build(collection);
        
        // Find records with score between 70 and 85 (inclusive)
        const result = await sortIndex.findByRange({
            min: 70,
            max: 85,
            minInclusive: true,
            maxInclusive: true
        });
        
        // Should find 3 records with score in range
        expect(result.length).toBe(3);
        expect(result.every(r => r.score >= 70 && r.score <= 85)).toBe(true);
        
        // Find records with score > 85
        const result2 = await sortIndex.findByRange({
            min: 85,
            minInclusive: false
        });
        
        // Should find 1 record with score > 85
        expect(result2.length).toBe(1);
        expect(result2[0].score).toBe(90);
        
        // Find records with score < 70
        const result3 = await sortIndex.findByRange({
            max: 70,
            maxInclusive: false
        });
        
        // Should find 1 record with score < 70
        expect(result3.length).toBe(1);
        expect(result3[0].score).toBe(65);
    });
    
    test('should update and delete records in the index', async () => {
        // Initialize the index
        await sortIndex.build(collection);
        
        // Update a record
        const updatedRecord: TestRecord = {
            _id: '123e4567-e89b-12d3-a456-426614174001',
            name: 'Record 1 Updated',
            score: 95, // Changed from 85
            category: 'A'
        };
        
        await sortIndex.updateRecord(updatedRecord, testRecords[0]);
        
        // Find records with the new score
        const result = await sortIndex.findByValue(95);
        
        // Should find 1 record with the new score
        expect(result.length).toBe(1);
        expect(result[0].score).toBe(95);
        expect(result[0].name).toBe('Record 1 Updated');
        
        // Old score should have one less record
        const oldScoreResult = await sortIndex.findByValue(85);
        expect(oldScoreResult.length).toBe(1); // Now just Record 5
        
        // Delete a record
        await sortIndex.deleteRecord('123e4567-e89b-12d3-a456-426614174005', 85); // Record 5 with score 85
        
        // Check that the record is gone
        const afterDeleteResult = await sortIndex.findByValue(85);
        expect(afterDeleteResult.length).toBe(0);
    });
    
    test('should add a new record to the index', async () => {
        // Initialize the index
        await sortIndex.build(collection);
        
        // Add a new record
        const newRecord: TestRecord = {
            _id: '123e4567-e89b-12d3-a456-426614174006',
            name: 'Record 6',
            score: 80,
            category: 'A'
        };
        
        await sortIndex.addRecord(newRecord);
        
        // In the B-tree implementation, we need to verify the record was added
        // by checking if it exists in the collection through the index methods
        
        // Check by traversing all pages
        const page1 = await sortIndex.getPage(collection, 1);
        const page2 = await sortIndex.getPage(collection, 2);
        const page3 = await sortIndex.getPage(collection, 3);
        
        // Combine all records from all pages
        const allRecords = [...page1.records, ...page2.records, ...page3.records];
        
        // Find the record we added
        const foundRecord = allRecords.find(r => r.name === 'Record 6');
        expect(foundRecord).toBeDefined();
        expect(foundRecord?.score).toBe(80);
    });
    
    test('should delete the entire index', async () => {
        // Initialize the index
        await sortIndex.build(collection);
        
        // Delete the index
        await sortIndex.delete();
        
        // Check that the index directory no longer exists
        const exists = await storage.dirExists('db/sort_indexes/test_collection/score_asc');
        expect(exists).toBe(false);
        
        // Index should no longer be initialized
        const isInitialized = await sortIndex.isBuilt();
        expect(isInitialized).toBe(false);
    });
});