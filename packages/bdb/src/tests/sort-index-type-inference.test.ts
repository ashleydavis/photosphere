import { SortIndex } from 'bdb';
import { IBsonCollection, IRecord, IShard } from 'bdb';
import { expect, jest, test, describe, beforeEach, afterEach } from '@jest/globals';
import { MockStorage } from 'storage';
import { MockCollection } from 'bdb';
import { RandomUuidGenerator } from 'utils';

// Test interface
interface TestRecord extends IRecord {
    _id: string;
    value?: any;
    name?: string;
    score?: number;
    eventDate?: Date;
}


describe('SortIndex type inference', () => {
    let storage: MockStorage;

    beforeEach(() => {
        storage = new MockStorage();
    });

    test('should infer string type when no type is specified', async () => {
        const records: TestRecord[] = [
            { _id: '1', name: 'Apple' },
            { _id: '2', name: 'Banana' },
            { _id: '3', name: 'Cherry' }
        ];
        
        const collection = new MockCollection<TestRecord>(records);
        
        // Create sort index without specifying type
        const index = new SortIndex<TestRecord>(
            {
                storage,
                baseDirectory: 'test',
                collectionName: 'products',
                fieldName: 'name',
                direction: 'asc',
                pageSize: 10,
                uuidGenerator: new RandomUuidGenerator()
                // Note: no type specified, should be inferred
            },
            collection
        );
        
        // Initialize the index
        await index.build();
        
        // Get sorted results
        const results = await index.getPage();
        
        // Should be sorted alphabetically
        expect(results.records.length).toBe(3);
        expect(results.records[0].name).toBe('Apple');
        expect(results.records[1].name).toBe('Banana');
        expect(results.records[2].name).toBe('Cherry');
    });

    test('should infer number type when no type is specified', async () => {
        const records: TestRecord[] = [
            { _id: '1', score: 100 },
            { _id: '2', score: 50 },
            { _id: '3', score: 200 }
        ];
        
        const collection = new MockCollection<TestRecord>(records);
        
        // Create sort index without specifying type
        const index = new SortIndex<TestRecord>(
            {
                storage,
                baseDirectory: 'test',
                collectionName: 'scores',
                fieldName: 'score',
                direction: 'asc',
                pageSize: 10,
                uuidGenerator: new RandomUuidGenerator()
                // Note: no type specified, should be inferred
            },
            collection
        );
        
        // Initialize the index
        await index.build();
        
        // Get sorted results
        const results = await index.getPage();
        
        // Should be sorted numerically
        expect(results.records.length).toBe(3);
        expect(results.records[0].score).toBe(50);
        expect(results.records[1].score).toBe(100);
        expect(results.records[2].score).toBe(200);
    });

    test('should infer date type when no type is specified', async () => {
        const date1 = new Date('2024-01-01');
        const date2 = new Date('2024-06-15');
        const date3 = new Date('2024-03-10');
        
        const records: TestRecord[] = [
            { _id: '1', eventDate: date1 },
            { _id: '2', eventDate: date2 },
            { _id: '3', eventDate: date3 }
        ];
        
        const collection = new MockCollection<TestRecord>(records);
        
        // Create sort index without specifying type
        const index = new SortIndex<TestRecord>(
            {
                storage,
                baseDirectory: 'test',
                collectionName: 'events',
                fieldName: 'eventDate',
                direction: 'asc',
                pageSize: 10,
                uuidGenerator: new RandomUuidGenerator()
                // Note: no type specified, should be inferred
            },
            collection
        );
        
        // Initialize the index
        await index.build();
        
        // Get sorted results
        const results = await index.getPage();
        
        // Should be sorted chronologically
        expect(results.records.length).toBe(3);
        expect(results.records[0].eventDate).toEqual(date1);
        expect(results.records[1].eventDate).toEqual(date3);
        expect(results.records[2].eventDate).toEqual(date2);
    });

    test('should throw error when comparing incompatible types', async () => {
        // Create a smaller page size to ensure comparison happens
        const mixedRecords: TestRecord[] = [
            { _id: '1', value: 'string' },
            { _id: '2', value: 123 }
        ];
        
        const collection = new MockCollection<TestRecord>(mixedRecords);
        
        // Create sort index without specifying type
        const index = new SortIndex<TestRecord>(
            {
                storage,
                baseDirectory: 'test',
                collectionName: 'mixed',
                fieldName: 'value',
                direction: 'asc',
                pageSize: 1,  // Small page size to force comparison
                uuidGenerator: new RandomUuidGenerator()
                // Note: no type specified, should be inferred
            },
            collection
        );
        
        // This should throw an error during initialization when comparing values
        await expect(index.build()).rejects.toThrow(/Type mismatch/);
    });
    
    test('should work correctly when all values are the same inferred type', async () => {
        const records: TestRecord[] = [
            { _id: '1', value: 'first' },
            { _id: '2', value: 'second' },
            { _id: '3', value: 'third' }
        ];
        
        const collection = new MockCollection<TestRecord>(records);
        
        // Create sort index without specifying type - should infer string
        const index = new SortIndex<TestRecord>(
            {
                storage,
                baseDirectory: 'test',
                collectionName: 'consistent',
                fieldName: 'value',
                direction: 'asc',
                pageSize: 10,
                uuidGenerator: new RandomUuidGenerator()
            },
            collection
        );
        
        // Should work fine since all values are strings
        await index.build();
        const results = await index.getPage();
        
        expect(results.records.length).toBe(3);
        expect(results.records[0].value).toBe('first');
        expect(results.records[1].value).toBe('second');
        expect(results.records[2].value).toBe('third');
    });
});