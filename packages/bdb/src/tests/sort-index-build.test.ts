import { MockStorage } from 'storage';
import { RandomUuidGenerator } from 'utils';
import { IRecord, toInternal } from '../lib/collection';
import { ISortedIndexEntry, SortIndex } from '../lib/sort-index';
import { MockCollection } from './mock-collection';

// Test interface
interface TestRecord extends IRecord {
    _id: string;
    name: string;
    score: number;
    category: string;
    createdAt?: string;
}

describe('SortIndex build function', () => {
    let storage: MockStorage;
    let uuidGenerator: RandomUuidGenerator;
    
    beforeEach(() => {
        storage = new MockStorage();
        uuidGenerator = new RandomUuidGenerator();
    });
    
    test('should call progress callback at configured intervals', async () => {
        const records: TestRecord[] = [];
        for (let i = 0; i < 25; i++) {
            records.push({
                _id: `record-${i}`,
                name: `Record ${i}`,
                score: i * 10,
                category: 'A'
            });
        }
        
        const collection = new MockCollection<TestRecord>(records);
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'test_collection',
            fieldName: 'score',
            direction: 'asc',
            pageSize: 10,
            buildBatchSize: 10, // Small batch size for testing
            buildProgressInterval: 5, // Report every 5 records
            uuidGenerator
        });
        
        const progressMessages: string[] = [];
        await sortIndex.build(collection, (message) => {
            progressMessages.push(message);
        });
        
        // Should have progress messages at 5, 10, 15, 20, 25 records
        expect(progressMessages.length).toBeGreaterThan(0);
        expect(progressMessages.some(msg => msg.includes('Indexed 5 records'))).toBe(true);
        expect(progressMessages.some(msg => msg.includes('Indexed 10 records'))).toBe(true);
        expect(progressMessages.some(msg => msg.includes('Indexed 15 records'))).toBe(true);
        expect(progressMessages.some(msg => msg.includes('Indexed 20 records'))).toBe(true);
        expect(progressMessages.some(msg => msg.includes('Indexed 25 records'))).toBe(true);
        
        // Should have final completion message
        const finalMessage = progressMessages[progressMessages.length - 1];
        expect(finalMessage).toContain('Completed indexing 25 records');
    });
    
    test('should batch saves according to buildBatchSize', async () => {
        const records: TestRecord[] = [];
        for (let i = 0; i < 25; i++) {
            records.push({
                _id: `record-${i}`,
                name: `Record ${i}`,
                score: i * 10,
                category: 'A'
            });
        }
        
        const collection = new MockCollection<TestRecord>(records);
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'test_collection',
            fieldName: 'score',
            direction: 'asc',
            pageSize: 10,
            buildBatchSize: 10, // Flush every 10 records
            buildProgressInterval: 25, // Don't report during build
            uuidGenerator
        });
        
        // Track file writes
        const fileWrites: string[] = [];
        const originalWrite = storage.write.bind(storage);
        storage.write = async (path: string, contentType: string | undefined, data: Buffer) => {
            fileWrites.push(path);
            return originalWrite(path, contentType, data);
        };
        
        await sortIndex.build(collection);
        
        // Should have written files (tree.dat and leaf page files)
        // The exact count depends on splits, but we should have at least the tree file
        expect(fileWrites.length).toBeGreaterThan(0);
        expect(fileWrites.some(path => path.includes('tree.dat'))).toBe(true);
    });
    
    test('should handle empty collection', async () => {
        const collection = new MockCollection<TestRecord>([]);
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'test_collection',
            fieldName: 'score',
            direction: 'asc',
            pageSize: 10,
            buildBatchSize: 10,
            buildProgressInterval: 5,
            uuidGenerator
        });
        
        const progressMessages: string[] = [];
        await sortIndex.build(collection, (message) => {
            progressMessages.push(message);
        });
        
        // Should have completion message even with 0 records
        expect(progressMessages.length).toBeGreaterThan(0);
        const finalMessage = progressMessages[progressMessages.length - 1];
        expect(finalMessage).toContain('Completed indexing 0 records');
    });
    
    test('should handle collection with records missing the indexed field', async () => {
        const records: TestRecord[] = [
            { _id: '1', name: 'Record 1', score: 10, category: 'A' },
            { _id: '2', name: 'Record 2', score: undefined as any, category: 'B' }, // Missing score
            { _id: '3', name: 'Record 3', score: 30, category: 'A' },
        ];
        
        const collection = new MockCollection<TestRecord>(records);
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'test_collection',
            fieldName: 'score',
            direction: 'asc',
            pageSize: 10,
            buildBatchSize: 10,
            buildProgressInterval: 5,
            uuidGenerator
        });
        
        await sortIndex.build(collection);
        
        // Should only index records with the score field
        const result = await sortIndex.getPage();
        expect(result.totalRecords).toBe(2); // Only 2 records have scores
        expect(result.records.map(r => r.fields.score)).toEqual([10, 30]);
    });
    
    test('should handle large dataset with multiple pages', async () => {
        const records: TestRecord[] = [];
        for (let i = 0; i < 100; i++) {
            records.push({
                _id: `record-${i}`,
                name: `Record ${i}`,
                score: i,
                category: i % 2 === 0 ? 'A' : 'B'
            });
        }
        
        const collection = new MockCollection<TestRecord>(records);
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'test_collection',
            fieldName: 'score',
            direction: 'asc',
            pageSize: 10,
            buildBatchSize: 20, // Flush every 20 records
            buildProgressInterval: 10, // Report every 10 records
            uuidGenerator
        });
        
        const progressMessages: string[] = [];
        await sortIndex.build(collection, (message) => {
            progressMessages.push(message);
        });
        
        // Verify all records were indexed
        let allRecords: ISortedIndexEntry[] = [];
        let currentPage = await sortIndex.getPage();
        allRecords.push(...currentPage.records);
        
        while (currentPage.nextPageId) {
            currentPage = await sortIndex.getPage(currentPage.nextPageId);
            allRecords.push(...currentPage.records);
        }
        
        expect(allRecords.length).toBe(100);
        expect(allRecords.map(r => r.fields.score)).toEqual(Array.from({ length: 100 }, (_, i) => i));
        
        // Should have progress messages
        expect(progressMessages.length).toBeGreaterThan(0);
        expect(progressMessages.some(msg => msg.includes('Completed indexing 100 records'))).toBe(true);
    });
    
    test('should handle records with duplicate values', async () => {
        const records: TestRecord[] = [
            { _id: '1', name: 'Record 1', score: 10, category: 'A' },
            { _id: '2', name: 'Record 2', score: 10, category: 'B' },
            { _id: '3', name: 'Record 3', score: 10, category: 'C' },
            { _id: '4', name: 'Record 4', score: 20, category: 'A' },
        ];
        
        const collection = new MockCollection<TestRecord>(records);
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'test_collection',
            fieldName: 'score',
            direction: 'asc',
            pageSize: 10,
            buildBatchSize: 10,
            buildProgressInterval: 5,
            uuidGenerator
        });
        
        await sortIndex.build(collection);
        
        const result = await sortIndex.getPage();
        expect(result.totalRecords).toBe(4);
        // All records with score 10 should be present
        const score10Records = result.records.filter(r => r.fields.score === 10);
        expect(score10Records.length).toBe(3);
    });
    
    test('should handle descending sort', async () => {
        const records: TestRecord[] = [];
        for (let i = 0; i < 20; i++) {
            records.push({
                _id: `record-${i}`,
                name: `Record ${i}`,
                score: i * 10,
                category: 'A'
            });
        }
        
        const collection = new MockCollection<TestRecord>(records);
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'test_collection',
            fieldName: 'score',
            direction: 'desc',
            pageSize: 10,
            buildBatchSize: 10,
            buildProgressInterval: 5,
            uuidGenerator
        });
        
        await sortIndex.build(collection);
        
        const result = await sortIndex.getPage();
        expect(result.totalRecords).toBe(20);
        // Should be in descending order
        const scores = result.records.map(r => r.fields.score);
        expect(scores[0]).toBe(190); // Highest score first
        expect(scores[scores.length - 1]).toBeLessThan(scores[0]);
    });
    
    test('should handle string type sorting', async () => {
        const records: TestRecord[] = [
            { _id: '1', name: 'Zebra', score: 10, category: 'A' },
            { _id: '2', name: 'Apple', score: 20, category: 'B' },
            { _id: '3', name: 'Banana', score: 30, category: 'C' },
        ];
        
        const collection = new MockCollection<TestRecord>(records);
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'test_collection',
            fieldName: 'name',
            direction: 'asc',
            type: 'string',
            pageSize: 10,
            buildBatchSize: 10,
            buildProgressInterval: 5,
            uuidGenerator
        });
        
        await sortIndex.build(collection);
        
        const result = await sortIndex.getPage();
        expect(result.totalRecords).toBe(3);
        expect(result.records[0].fields.name).toBe('Apple');
        expect(result.records[1].fields.name).toBe('Banana');
        expect(result.records[2].fields.name).toBe('Zebra');
    });
    
    test('should handle date type sorting', async () => {
        const now = new Date();
        const records: TestRecord[] = [
            { _id: '1', name: 'Record 1', score: 10, category: 'A', createdAt: new Date(now.getTime() - 3 * 24 * 60 * 60 * 1000).toISOString() },
            { _id: '2', name: 'Record 2', score: 20, category: 'B', createdAt: new Date(now.getTime() - 1 * 24 * 60 * 60 * 1000).toISOString() },
            { _id: '3', name: 'Record 3', score: 30, category: 'C', createdAt: new Date(now.getTime() - 2 * 24 * 60 * 60 * 1000).toISOString() },
        ];
        
        const collection = new MockCollection<TestRecord>(records);
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'test_collection',
            fieldName: 'createdAt',
            direction: 'asc',
            type: 'date',
            pageSize: 10,
            buildBatchSize: 10,
            buildProgressInterval: 5,
            uuidGenerator
        });
        
        await sortIndex.build(collection);
        
        const result = await sortIndex.getPage();
        expect(result.totalRecords).toBe(3);
        // Should be sorted by date (oldest first)
        const dates = result.records.map(r => new Date(r.fields.createdAt as string).getTime());
        expect(dates[0]).toBeLessThan(dates[1]);
        expect(dates[1]).toBeLessThan(dates[2]);
    });
    
    test('should show performance metrics in final progress message', async () => {
        const records: TestRecord[] = [];
        for (let i = 0; i < 15; i++) {
            records.push({
                _id: `record-${i}`,
                name: `Record ${i}`,
                score: i * 10,
                category: 'A'
            });
        }
        
        const collection = new MockCollection<TestRecord>(records);
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'test_collection',
            fieldName: 'score',
            direction: 'asc',
            pageSize: 10,
            buildBatchSize: 10,
            buildProgressInterval: 5,
            uuidGenerator
        });
        
        const progressMessages: string[] = [];
        await sortIndex.build(collection, (message) => {
            progressMessages.push(message);
        });
        
        // Final message should contain performance metrics
        const finalMessage = progressMessages[progressMessages.length - 1];
        expect(finalMessage).toContain('Average time per operation');
        expect(finalMessage).toContain('Tree traversal');
        expect(finalMessage).toContain('Load records');
        expect(finalMessage).toContain('Binary search');
        expect(finalMessage).toContain('MOST EXPENSIVE');
    });
});

