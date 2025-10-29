import { expect, test, describe, beforeEach } from '@jest/globals';
import { MockStorage } from 'storage';
import { IRecord, ISortedIndexEntry } from 'bdb';
import { SortIndex } from 'bdb';
import { MockCollection } from 'bdb';
import { RandomUuidGenerator } from 'utils';
import { toExternal, toInternal } from '../lib/collection';

// Test interface
interface TestRecord extends IRecord {
    _id: string;
    name: string;
    score: number;
    category: string;
}


describe('SortIndex', () => {
    let storage: MockStorage;
    let sortIndex: SortIndex;
    let collection: MockCollection<TestRecord>;
    
    const testRecords: TestRecord[] = [
        { _id: '123e4567-e89b-12d3-a456-426614174001', name: 'Record 1', score: 85, category: 'A' },
        { _id: '123e4567-e89b-12d3-a456-426614174002', name: 'Record 2', score: 72, category: 'B' },
        { _id: '123e4567-e89b-12d3-a456-426614174003', name: 'Record 3', score: 90, category: 'A' },
        { _id: '123e4567-e89b-12d3-a456-426614174004', name: 'Record 4', score: 65, category: 'C' },
        { _id: '123e4567-e89b-12d3-a456-426614174005', name: 'Record 5', score: 85, category: 'B' },
    ];
    
    beforeEach(() => {
        storage = new MockStorage();
        collection = new MockCollection<TestRecord>(testRecords);        
        sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'test_collection',
            fieldName: 'score',
            direction: 'asc',
            pageSize: 2,
            uuidGenerator: new RandomUuidGenerator()
        });
    });
    
    test('should initialize the sort index with records', async () => {
        // Initialize the index
        await sortIndex.build(collection);
        
        
        // Check that tree file has been written
        expect(await storage.fileExists('db/sort_indexes/test_collection/score_asc/tree.dat')).toBe(true);
        
        // B-tree implementation uses UUIDs for page IDs, so we check tree file instead
        expect(await storage.fileExists('db/sort_indexes/test_collection/score_asc/tree.dat')).toBe(true);
        
        // Force metadata save
        await sortIndex.saveTree();
    });
    
    test('should retrieve a page of sorted records', async () => {
        // Initialize the index
        await sortIndex.build(collection);
        
        // Get the first page (using empty string to get first page)
        const result = await sortIndex.getPage('');
        
        // Check page contents
        expect(result.records.length).toBeLessThanOrEqual(3);
        expect(result.totalRecords).toBe(5);
        expect(result.currentPageId).toBeTruthy();
        expect(result.totalPages).toBe(2);
        
        // Check pagination links exist as expected
        if (result.records.length < 5) {
            expect(result.nextPageId).toBeTruthy();
        }
        expect(result.previousPageId).toBeUndefined();
        
        // Check records are sorted by score (ascending)
        if (result.records.length > 0) {
            // The first page should have the lowest score
            expect(result.records[0].fields.score).toBe(65); // Record 4
            if (result.records.length > 1) {
                expect(result.records[1].fields.score).toBe(72); // Record 2
            }
        }
        
        // Follow the chain of pages to get all records
        let allRecords = [...result.records];
        let nextPageId = result.nextPageId;
        
        while (nextPageId) {
            const nextPage = await sortIndex.getPage(nextPageId);
            allRecords = [...allRecords, ...nextPage.records];
            nextPageId = nextPage.nextPageId;
        }
        
        // Should have all 5 records after traversing all pages
        expect(allRecords.length).toBe(5);
        
        // Verify they are in the correct sorted order
        const scores = allRecords.map(r => r.fields.score);
        expect(scores).toEqual([65, 72, 85, 85, 90]);
    });
    
    test('should find records by exact value', async () => {
        // Initialize the index
        await sortIndex.build(collection);
        
        // Find records with score 85
        const result = await sortIndex.findByValue(85);
        
        // Should find 2 records with score 85
        expect(result.length).toBe(2);
        expect(result.every(r => r.fields.score === 85)).toBe(true);
        
        // Find records with score 90
        const result2 = await sortIndex.findByValue(90);
        
        // Should find 1 record with score 90
        expect(result2.length).toBe(1);
        expect(result2[0].fields.score).toBe(90);
        
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
        expect(result.every(r => r.fields.score >= 70 && r.fields.score <= 85)).toBe(true);
        
        // Find records with score > 85
        const result2 = await sortIndex.findByRange({
            min: 85,
            minInclusive: false
        });
        
        // Should find 1 record with score > 85
        expect(result2.length).toBe(1);
        expect(result2[0].fields.score).toBe(90);
        
        // Find records with score < 70
        const result3 = await sortIndex.findByRange({
            max: 70,
            maxInclusive: false
        });
        
        // Should find 1 record with score < 70
        expect(result3.length).toBe(1);
        expect(result3[0].fields.score).toBe(65);
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
        
        await sortIndex.updateRecord(toInternal<TestRecord>(updatedRecord), toInternal<TestRecord>(testRecords[0]));
        
        // Find records with the new score
        const result = await sortIndex.findByValue(95);
        
        // Should find 1 record with the new score
        expect(result.length).toBe(1);
        expect(result[0].fields.score).toBe(95);
        expect(result[0].fields.name).toBe('Record 1 Updated');
        
        // Old score should have one less record
        const oldScoreResult = await sortIndex.findByValue(85);
        expect(oldScoreResult.length).toBe(1); // Now just Record 5
        
        // Delete a record
        await sortIndex.deleteRecord('123e4567-e89b-12d3-a456-426614174005', toInternal<TestRecord>(testRecords[4]));
        
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
        
        await sortIndex.addRecord(toInternal<TestRecord>(newRecord));
        
        // In the B-tree implementation, we need to verify the record was added
        // by checking if it exists in the collection through the index methods
        
        // Check by traversing all pages
        let allRecords: ISortedIndexEntry[] = [];
        let currentPage = await sortIndex.getPage('');
        
        // Add records from first page
        allRecords = [...allRecords, ...currentPage.records];
        
        // Follow next page links until we've visited all pages
        while (currentPage.nextPageId) {
            currentPage = await sortIndex.getPage(currentPage.nextPageId);
            allRecords = [...allRecords, ...currentPage.records];
        }
        
        // Find the record we added
        const foundRecord = allRecords.find(r => r.fields.name === 'Record 6');
        expect(foundRecord).toBeDefined();
        expect(foundRecord?.fields.score).toBe(80);
    });
    
    test('should delete the entire index', async () => {
        // Initialize the index
        await sortIndex.build(collection);
        
        // Delete the index
        await sortIndex.delete();
        
        // Check that the index directory no longer exists
        const exists = await storage.dirExists('db/sort_indexes/test_collection/score_asc');
        expect(exists).toBe(false);        
    });
});