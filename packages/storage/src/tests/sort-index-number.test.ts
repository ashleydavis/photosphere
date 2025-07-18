import { SortIndex, ISortedIndexEntry } from '../lib/bson-database/sort-index';
import { IBsonCollection, IRecord, IShard } from '../lib/bson-database/collection';
import { expect, jest, test, describe, beforeEach, afterEach } from '@jest/globals';
import { MockStorage } from './mock-storage';
import { MockCollection } from './mock-collection';
import { BSON } from 'bson';
import fs from 'fs-extra';
import path from 'path';
import os from 'os';
import { RandomUuidGenerator } from 'utils';

// Test interface
interface TestRecord extends IRecord {
    _id: string;
    name: string;
    score: number;
    price: number;
    quantity: number;
    rating: number;
}


describe('SortIndex with number type', () => {
    let storage: MockStorage;
    let sortIndexAsc: SortIndex<TestRecord>;
    let sortIndexDesc: SortIndex<TestRecord>;
    let collection: MockCollection<TestRecord>;
    
    const testRecords: TestRecord[] = [
        { 
            _id: '123e4567-e89b-12d3-a456-426614174001', 
            name: 'Product A', 
            score: 85.5,
            price: 29.99,
            quantity: 100,
            rating: 4.2
        },
        { 
            _id: '123e4567-e89b-12d3-a456-426614174002', 
            name: 'Product B', 
            score: 92.1,
            price: 15.50,
            quantity: 50,
            rating: 4.8
        },
        { 
            _id: '123e4567-e89b-12d3-a456-426614174003', 
            name: 'Product C', 
            score: 78.3,
            price: 99.99,
            quantity: 25,
            rating: 3.5
        },
        { 
            _id: '123e4567-e89b-12d3-a456-426614174004', 
            name: 'Product D', 
            score: 88.7,
            price: 45.00,
            quantity: 75,
            rating: 4.1
        },
        { 
            _id: '123e4567-e89b-12d3-a456-426614174005', 
            name: 'Product E', 
            score: 95.2,
            price: 12.99,
            quantity: 200,
            rating: 4.9
        },
        { 
            _id: '123e4567-e89b-12d3-a456-426614174006', 
            name: 'Product F', 
            score: 82.0,
            price: 35.75,
            quantity: 0,
            rating: 3.8
        },
    ];
    
    beforeEach(() => {
        storage = new MockStorage();
        collection = new MockCollection<TestRecord>(testRecords);
        
        // Create ascending index on score field
        sortIndexAsc = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'test_collection',
            fieldName: 'score',
            direction: 'asc',
            pageSize: 3,
            type: 'number', // Specify number type for proper comparison
            uuidGenerator: new RandomUuidGenerator()
        }, collection);
        
        // Create descending index on price field
        sortIndexDesc = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'test_collection',
            fieldName: 'price',
            direction: 'desc',
            pageSize: 3,
            type: 'number', // Specify number type for proper comparison
            uuidGenerator: new RandomUuidGenerator()
        }, collection);
    });
    
    test('should initialize the number sort indexes with records', async () => {
        // Initialize both indexes
        await sortIndexAsc.build();
        await sortIndexDesc.build();
        
        // Check that tree files have been written
        expect(await storage.fileExists('db/sort_indexes/test_collection/score_asc/tree.dat')).toBe(true);
        expect(await storage.fileExists('db/sort_indexes/test_collection/price_desc/tree.dat')).toBe(true);
    });
    
    test('should retrieve records in ascending numeric order', async () => {
        // Initialize the index
        await sortIndexAsc.build();
        
        // Get all records by traversing pages
        let allRecords: TestRecord[] = [];
        let currentPage = await sortIndexAsc.getPage('');
        
        // Add records from first page
        allRecords = [...allRecords, ...currentPage.records];
        
        // Follow next page links until we've visited all pages
        while (currentPage.nextPageId) {
            currentPage = await sortIndexAsc.getPage(currentPage.nextPageId);
            allRecords = [...allRecords, ...currentPage.records];
        }
        
        // Verify records are in ascending numeric order
        for (let i = 1; i < allRecords.length; i++) {
            const prevScore = Number(allRecords[i-1].score);
            const currScore = Number(allRecords[i].score);
            expect(prevScore).toBeLessThanOrEqual(currScore);
        }
        
        // Check specific ordering
        // Expected order by score: 78.3, 82.0, 85.5, 88.7, 92.1, 95.2
        expect(allRecords[0].score).toBe(78.3); // Product C
        expect(allRecords[1].score).toBe(82.0); // Product F
        expect(allRecords[2].score).toBe(85.5); // Product A
        expect(allRecords[3].score).toBe(88.7); // Product D
        expect(allRecords[4].score).toBe(92.1); // Product B
        expect(allRecords[5].score).toBe(95.2); // Product E
    });
    
    test('should retrieve records in descending numeric order', async () => {
        // Initialize the index
        await sortIndexDesc.build();
        
        // Get all records by traversing pages
        let allRecords: TestRecord[] = [];
        let currentPage = await sortIndexDesc.getPage('');
        
        // Add records from first page
        allRecords = [...allRecords, ...currentPage.records];
        
        // Follow next page links until we've visited all pages
        while (currentPage.nextPageId) {
            currentPage = await sortIndexDesc.getPage(currentPage.nextPageId);
            allRecords = [...allRecords, ...currentPage.records];
        }
        
        // Verify records are in descending numeric order
        for (let i = 1; i < allRecords.length; i++) {
            const prevPrice = Number(allRecords[i-1].price);
            const currPrice = Number(allRecords[i].price);
            expect(prevPrice).toBeGreaterThanOrEqual(currPrice);
        }
        
        // Check specific ordering
        // Expected order by price: 99.99, 45.00, 35.75, 29.99, 15.50, 12.99
        expect(allRecords[0].price).toBe(99.99); // Product C
        expect(allRecords[1].price).toBe(45.00); // Product D
        expect(allRecords[2].price).toBe(35.75); // Product F
        expect(allRecords[3].price).toBe(29.99); // Product A
        expect(allRecords[4].price).toBe(15.50); // Product B
        expect(allRecords[5].price).toBe(12.99); // Product E
    });
    
    test('should find records by exact numeric value', async () => {
        // Initialize the index
        await sortIndexAsc.build();
        
        // Find records with exact numeric match
        const result = await sortIndexAsc.findByValue(85.5);
        
        // Should find exactly one record with score 85.5
        expect(result.length).toBe(1);
        expect(result[0]._id).toBe('123e4567-e89b-12d3-a456-426614174001');
        expect(result[0].score).toBe(85.5);
        
        // Find a non-existent score
        const noResult = await sortIndexAsc.findByValue(90.0);
        
        // Should find no records
        expect(noResult.length).toBe(0);
    });
    
    test('should find records by numeric range', async () => {
        // Initialize the index
        await sortIndexAsc.build();
        
        // Find records with scores between 80 and 90 (inclusive)
        const result = await sortIndexAsc.findByRange({
            min: 80,
            max: 90,
            minInclusive: true,
            maxInclusive: true
        });
        
        // Should find records with scores: 82.0, 85.5, 88.7
        expect(result.length).toBe(3);
        const scores = result.map(r => r.score).sort((a, b) => a - b);
        expect(scores).toEqual([82.0, 85.5, 88.7]);
        
        // Test exclusive range (between 78 and 95, non-inclusive)
        const exclusiveResult = await sortIndexAsc.findByRange({
            min: 78,
            max: 95,
            minInclusive: false,
            maxInclusive: false
        });
        
        
        // Should find records that are greater than 78 and less than 95
        // Since 78.3 > 78, it should be included: 78.3, 82.0, 85.5, 88.7, 92.1
        expect(exclusiveResult.length).toBe(5);
        const exclusiveScores = exclusiveResult.map(r => r.score).sort((a, b) => a - b);
        expect(exclusiveScores).toEqual([78.3, 82.0, 85.5, 88.7, 92.1]);
        
        // Should not include 95.2 (which equals or exceeds max)
        for (const record of exclusiveResult) {
            expect(record.score).toBeGreaterThan(78);
            expect(record.score).toBeLessThan(95);
        }
    });
    
    test('should update records with new numeric values in the index', async () => {
        // Initialize the index
        await sortIndexAsc.build();
        
        // Update a record with a new score
        const updatedRecord: TestRecord = {
            ...testRecords[2], // Clone Product C
            score: 90.5 // Change score from 78.3 to 90.5
        };
        
        await sortIndexAsc.updateRecord(updatedRecord, testRecords[2]);
        
        // Find records by the new score
        const result = await sortIndexAsc.findByValue(90.5);
        
        // Should find the updated record with the new score
        expect(result.length).toBe(1);
        expect(result[0]._id).toBe('123e4567-e89b-12d3-a456-426614174003');
        expect(result[0].score).toBe(90.5);
        
        // Original score should no longer have this record
        const oldScoreResult = await sortIndexAsc.findByValue(78.3);
        expect(oldScoreResult.length).toBe(0);
        
        // Get all records and verify proper sorting
        let allRecords: TestRecord[] = [];
        let currentPage = await sortIndexAsc.getPage('');
        
        // Add records from first page
        allRecords = [...allRecords, ...currentPage.records];
        
        // Follow next page links until we've visited all pages
        while (currentPage.nextPageId) {
            currentPage = await sortIndexAsc.getPage(currentPage.nextPageId);
            allRecords = [...allRecords, ...currentPage.records];
        }
        
        // Verify the updated record is in the correct position
        const updatedRecordIndex = allRecords.findIndex(r => r._id === '123e4567-e89b-12d3-a456-426614174003');
        expect(updatedRecordIndex).toBeGreaterThan(-1);
        expect(allRecords[updatedRecordIndex].score).toBe(90.5);
        
        // Verify sorting is still correct
        for (let i = 1; i < allRecords.length; i++) {
            const prevScore = Number(allRecords[i-1].score);
            const currScore = Number(allRecords[i].score);
            expect(prevScore).toBeLessThanOrEqual(currScore);
        }
    });
    
    test('should add a new record with a numeric value to the index', async () => {
        // Initialize the index
        await sortIndexAsc.build();
        
        // Add a new record with a specific score
        const newRecord: TestRecord = {
            _id: '123e4567-e89b-12d3-a456-426614174007',
            name: 'Product G',
            score: 89.0,
            price: 22.50,
            quantity: 150,
            rating: 4.3
        };
        
        await sortIndexAsc.addRecord(newRecord);
        
        // Find the record by its score
        const result = await sortIndexAsc.findByValue(89.0);
        
        // Should find the new record
        expect(result.length).toBe(1);
        expect(result[0]._id).toBe('123e4567-e89b-12d3-a456-426614174007');
        
        // Get all records and verify the new record is in the correct position
        let allRecords: TestRecord[] = [];
        let currentPage = await sortIndexAsc.getPage('');
        
        // Add records from first page
        allRecords = [...allRecords, ...currentPage.records];
        
        // Follow next page links until we've visited all pages
        while (currentPage.nextPageId) {
            currentPage = await sortIndexAsc.getPage(currentPage.nextPageId);
            allRecords = [...allRecords, ...currentPage.records];
        }
        
        // Verify the new record is in the correct numeric position
        const newRecordIndex = allRecords.findIndex(r => r.score === 89.0);
        expect(newRecordIndex).toBeGreaterThan(-1);
        
        // Verify the total record count has increased
        expect(allRecords.length).toBe(7);
        
        // Verify sorting is still correct
        for (let i = 1; i < allRecords.length; i++) {
            const prevScore = Number(allRecords[i-1].score);
            const currScore = Number(allRecords[i].score);
            expect(prevScore).toBeLessThanOrEqual(currScore);
        }
    });
    
    test('should handle integer and floating point numbers correctly', async () => {
        // Initialize the index
        await sortIndexAsc.build();
        
        // Get all records sorted by score
        let allRecords: TestRecord[] = [];
        let currentPage = await sortIndexAsc.getPage('');
        
        allRecords = [...allRecords, ...currentPage.records];
        
        while (currentPage.nextPageId) {
            currentPage = await sortIndexAsc.getPage(currentPage.nextPageId);
            allRecords = [...allRecords, ...currentPage.records];
        }
        
        // Extract scores in order
        const sortedScores = allRecords.map(r => r.score);
        
        // Verify mixed integer and floating point sorting
        // Expected: [78.3, 82.0, 85.5, 88.7, 92.1, 95.2]
        expect(sortedScores).toEqual([78.3, 82.0, 85.5, 88.7, 92.1, 95.2]);
        
        // Verify that integer 82.0 is treated as a number, not string
        const integerRecord = allRecords.find(r => r.score === 82.0);
        expect(integerRecord).toBeDefined();
        expect(typeof integerRecord!.score).toBe('number');
    });
    
    test('should handle string numbers correctly when type is number', async () => {
        // Add records with string numeric values
        const stringNumericRecords: TestRecord[] = [
            { _id: 'str1', name: 'StringNum A', score: 10 as any, price: 0, quantity: 0, rating: 0 },
            { _id: 'str2', name: 'StringNum B', score: '2' as any, price: 0, quantity: 0, rating: 0 },
            { _id: 'str3', name: 'StringNum C', score: '100' as any, price: 0, quantity: 0, rating: 0 },
            { _id: 'str4', name: 'StringNum D', score: '20' as any, price: 0, quantity: 0, rating: 0 },
        ];
        
        const stringNumericCollection = new MockCollection<TestRecord>(stringNumericRecords);
        const stringNumericSortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'string_numeric_test',
            fieldName: 'score',
            direction: 'asc',
            pageSize: 3,
            type: 'number',
            uuidGenerator: new RandomUuidGenerator()
        }, stringNumericCollection);
        
        await stringNumericSortIndex.build();
        
        // Get all records sorted
        let allRecords: TestRecord[] = [];
        let currentPage = await stringNumericSortIndex.getPage('');
        
        allRecords = [...allRecords, ...currentPage.records];
        
        while (currentPage.nextPageId) {
            currentPage = await stringNumericSortIndex.getPage(currentPage.nextPageId);
            allRecords = [...allRecords, ...currentPage.records];
        }
        
        // Extract scores in order
        const sortedScores = allRecords.map(r => Number(r.score));
        
        // As numbers, they should be sorted numerically: 2, 10, 20, 100
        // NOT lexicographically which would be: "10", "100", "2", "20"
        expect(sortedScores).toEqual([2, 10, 20, 100]);
    });
    
    test('should handle NaN values correctly', async () => {
        // Add records with NaN and invalid numeric values
        const nanRecords: TestRecord[] = [
            { _id: 'nan1', name: 'Valid', score: 50, price: 0, quantity: 0, rating: 0 },
            { _id: 'nan2', name: 'NaN', score: NaN, price: 0, quantity: 0, rating: 0 },
            { _id: 'nan3', name: 'Invalid', score: 'invalid' as any, price: 0, quantity: 0, rating: 0 },
            { _id: 'nan4', name: 'Another Valid', score: 25, price: 0, quantity: 0, rating: 0 },
        ];
        
        const nanCollection = new MockCollection<TestRecord>(nanRecords);
        const nanSortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'nan_test',
            fieldName: 'score',
            direction: 'asc',
            pageSize: 3,
            type: 'number',
            uuidGenerator: new RandomUuidGenerator()
        }, nanCollection);
        
        await nanSortIndex.build();
        
        // Get all records sorted
        let allRecords: TestRecord[] = [];
        let currentPage = await nanSortIndex.getPage('');
        
        allRecords = [...allRecords, ...currentPage.records];
        
        while (currentPage.nextPageId) {
            currentPage = await nanSortIndex.getPage(currentPage.nextPageId);
            allRecords = [...allRecords, ...currentPage.records];
        }
        
        // NaN values should be sorted to the beginning (treated as smallest)
        // Expected order: NaN, NaN, 25, 50
        expect(allRecords.length).toBe(4);
        expect(isNaN(Number(allRecords[0].score))).toBe(true); // NaN or invalid
        expect(isNaN(Number(allRecords[1].score))).toBe(true); // NaN or invalid
        expect(Number(allRecords[2].score)).toBe(25);
        expect(Number(allRecords[3].score)).toBe(50);
    });
    
    test('should handle zero and negative numbers correctly', async () => {
        // Add records with zero and negative numbers
        const zeroNegativeRecords: TestRecord[] = [
            { _id: 'pos', name: 'Positive', score: 10, price: 0, quantity: 0, rating: 0 },
            { _id: 'zero', name: 'Zero', score: 0, price: 0, quantity: 0, rating: 0 },
            { _id: 'neg1', name: 'Negative Small', score: -5, price: 0, quantity: 0, rating: 0 },
            { _id: 'neg2', name: 'Negative Large', score: -15, price: 0, quantity: 0, rating: 0 },
        ];
        
        const zeroNegativeCollection = new MockCollection<TestRecord>(zeroNegativeRecords);
        const zeroNegativeSortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'zero_negative_test',
            fieldName: 'score',
            direction: 'asc',
            pageSize: 3,
            type: 'number',
            uuidGenerator: new RandomUuidGenerator()
        }, zeroNegativeCollection);
        
        await zeroNegativeSortIndex.build();
        
        // Get all records sorted
        let allRecords: TestRecord[] = [];
        let currentPage = await zeroNegativeSortIndex.getPage('');
        
        allRecords = [...allRecords, ...currentPage.records];
        
        while (currentPage.nextPageId) {
            currentPage = await zeroNegativeSortIndex.getPage(currentPage.nextPageId);
            allRecords = [...allRecords, ...currentPage.records];
        }
        
        // Extract scores in order
        const sortedScores = allRecords.map(r => r.score);
        
        // Expected order: -15, -5, 0, 10
        expect(sortedScores).toEqual([-15, -5, 0, 10]);
    });
});