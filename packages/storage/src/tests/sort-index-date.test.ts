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
    createdAt: string; // ISO string date
    updatedAt: string; // ISO string date
    category: string;
}


describe('SortIndex with date type', () => {
    let storage: MockStorage;
    let sortIndexAsc: SortIndex<TestRecord>;
    let sortIndexDesc: SortIndex<TestRecord>;
    let collection: MockCollection<TestRecord>;
    
    const now = new Date();
    const testRecords: TestRecord[] = [
        { 
            _id: '123e4567-e89b-12d3-a456-426614174001', 
            name: 'Record 1', 
            createdAt: new Date(now.getTime() - 4 * 24 * 60 * 60 * 1000).toISOString(), // 4 days ago
            updatedAt: new Date(now.getTime() - 1 * 24 * 60 * 60 * 1000).toISOString(), // 1 day ago
            category: 'A' 
        },
        { 
            _id: '123e4567-e89b-12d3-a456-426614174002', 
            name: 'Record 2', 
            createdAt: new Date(now.getTime() - 2 * 24 * 60 * 60 * 1000).toISOString(), // 2 days ago
            updatedAt: new Date(now.getTime() - 2 * 24 * 60 * 60 * 1000).toISOString(), // 2 days ago
            category: 'B' 
        },
        { 
            _id: '123e4567-e89b-12d3-a456-426614174003', 
            name: 'Record 3', 
            createdAt: new Date(now.getTime() - 1 * 24 * 60 * 60 * 1000).toISOString(), // 1 day ago
            updatedAt: new Date(now.getTime() - 4 * 24 * 60 * 60 * 1000).toISOString(), // 4 days ago
            category: 'A' 
        },
        { 
            _id: '123e4567-e89b-12d3-a456-426614174004', 
            name: 'Record 4', 
            createdAt: new Date(now.getTime() - 3 * 24 * 60 * 60 * 1000).toISOString(), // 3 days ago
            updatedAt: new Date(now.getTime() - 3 * 24 * 60 * 60 * 1000).toISOString(), // 3 days ago
            category: 'C' 
        },
        { 
            _id: '123e4567-e89b-12d3-a456-426614174005', 
            name: 'Record 5', 
            createdAt: now.toISOString(), // today
            updatedAt: now.toISOString(), // today
            category: 'B' 
        },
    ];
    
    beforeEach(() => {
        storage = new MockStorage();
        collection = new MockCollection<TestRecord>(testRecords);
        
        // Create ascending index on createdAt field
        sortIndexAsc = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'test_collection',
            fieldName: 'createdAt',
            direction: 'asc',
            pageSize: 2,
            type: 'date', // Specify date type for proper comparison
            uuidGenerator: new RandomUuidGenerator()
        }, collection);
        
        // Create descending index on updatedAt field
        sortIndexDesc = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'test_collection',
            fieldName: 'updatedAt',
            direction: 'desc',
            pageSize: 2,
            type: 'date', // Specify date type for proper comparison
            uuidGenerator: new RandomUuidGenerator()
        }, collection);
    });
    
    test('should initialize the date sort indexes with records', async () => {
        // Initialize both indexes
        await sortIndexAsc.build();
        await sortIndexDesc.build();
        
        // Check that tree files have been written
        expect(await storage.fileExists('db/sort_indexes/test_collection/createdAt_asc/tree.dat')).toBe(true);
        expect(await storage.fileExists('db/sort_indexes/test_collection/updatedAt_desc/tree.dat')).toBe(true);
    });
    
    test('should retrieve records in ascending date order', async () => {
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
        
        // Verify records are in ascending date order
        for (let i = 1; i < allRecords.length; i++) {
            const prevDate = new Date(allRecords[i-1].createdAt);
            const currDate = new Date(allRecords[i].createdAt);
            expect(prevDate.getTime()).toBeLessThanOrEqual(currDate.getTime());
        }
        
        // First record should be the oldest (earliest date)
        expect(allRecords[0]._id).toBe('123e4567-e89b-12d3-a456-426614174001'); // Record 1 (4 days ago)
        
        // Last record should be the newest (latest date)
        expect(allRecords[allRecords.length - 1]._id).toBe('123e4567-e89b-12d3-a456-426614174005'); // Record 5 (today)
    });
    
    test('should retrieve records in descending date order', async () => {
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
        
        // Verify records are in descending date order
        for (let i = 1; i < allRecords.length; i++) {
            const prevDate = new Date(allRecords[i-1].updatedAt);
            const currDate = new Date(allRecords[i].updatedAt);
            expect(prevDate.getTime()).toBeGreaterThanOrEqual(currDate.getTime());
        }
        
        // First record should be the newest (latest date)
        expect(allRecords[0]._id).toBe('123e4567-e89b-12d3-a456-426614174005'); // Record 5 (today)
        
        // Last record should be the oldest (earliest date)
        expect(allRecords[allRecords.length - 1]._id).toBe('123e4567-e89b-12d3-a456-426614174003'); // Record 3 (updated 4 days ago)
    });
    
    test('should find records by exact date value', async () => {
        // Initialize the index
        await sortIndexAsc.build();
        
        // Find a record with a specific createdAt date
        const result = await sortIndexAsc.findByValue(testRecords[2].createdAt); // Record 3 (1 day ago)
        
        // Should find exactly one record with this date
        expect(result.length).toBe(1);
        expect(result[0]._id).toBe('123e4567-e89b-12d3-a456-426614174003');
        
        // Find a non-existent date
        const nonExistentDate = new Date(now.getTime() - 10 * 24 * 60 * 60 * 1000).toISOString(); // 10 days ago
        const noResult = await sortIndexAsc.findByValue(nonExistentDate);
        
        // Should find no records
        expect(noResult.length).toBe(0);
    });
    
    test('should find records by date range', async () => {
        // Initialize the index
        await sortIndexAsc.build();
        
        // Find records created between 3 days ago and 1 day ago (inclusive)
        const threeDay = new Date(now.getTime() - 3 * 24 * 60 * 60 * 1000).toISOString();
        const oneDay = new Date(now.getTime() - 1 * 24 * 60 * 60 * 1000).toISOString();
        
        const result = await sortIndexAsc.findByRange({
            min: threeDay,
            max: oneDay,
            minInclusive: true,
            maxInclusive: true
        });
        
        // Should find 3 records in this date range (Records 2, 3, and 4)
        expect(result.length).toBe(3);
        
        // All records should have createdAt between 3 days ago and 1 day ago
        for (const record of result) {
            const date = new Date(record.createdAt).getTime();
            const minDate = new Date(threeDay).getTime();
            const maxDate = new Date(oneDay).getTime();
            expect(date).toBeGreaterThanOrEqual(minDate);
            expect(date).toBeLessThanOrEqual(maxDate);
        }
        
        // Test exclusive range (between 4 days ago and today, non-inclusive)
        const fourDay = new Date(now.getTime() - 4 * 24 * 60 * 60 * 1000).toISOString();
        const today = now.toISOString();
        
        const exclusiveResult = await sortIndexAsc.findByRange({
            min: fourDay,
            max: today,
            minInclusive: false,
            maxInclusive: false
        });
        
        // Should find 3 records in this date range (Records 2, 3, and 4)
        expect(exclusiveResult.length).toBe(3);
        
        // Should not include the earliest (Record 1) or latest (Record 5) records
        const recordIds = exclusiveResult.map(r => r._id);
        expect(recordIds).not.toContain('123e4567-e89b-12d3-a456-426614174001'); // Record 1 (4 days ago)
        expect(recordIds).not.toContain('123e4567-e89b-12d3-a456-426614174005'); // Record 5 (today)
    });
    
    test('should update records with new dates in the index', async () => {
        // Initialize the index
        await sortIndexAsc.build();
        
        // Update a record with a new createdAt date
        const newDate = new Date(now.getTime() - 5 * 24 * 60 * 60 * 1000).toISOString(); // 5 days ago
        const updatedRecord: TestRecord = {
            ...testRecords[2], // Clone Record 3
            createdAt: newDate // Change date to 5 days ago (was 1 day ago)
        };
        
        await sortIndexAsc.updateRecord(updatedRecord, testRecords[2]);
        
        // Find records by the new date
        const result = await sortIndexAsc.findByValue(newDate);
        
        // Should find the updated record with the new date
        expect(result.length).toBe(1);
        expect(result[0]._id).toBe('123e4567-e89b-12d3-a456-426614174003');
        expect(result[0].createdAt).toBe(newDate);
        
        // Original date should no longer have this record
        const oldDateResult = await sortIndexAsc.findByValue(testRecords[2].createdAt);
        expect(oldDateResult.length).toBe(0);
        
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
        
        // First record should now be the updated Record 3 (5 days ago)
        expect(allRecords[0]._id).toBe('123e4567-e89b-12d3-a456-426614174003');
    });
    
    test('should add a new record with a date to the index', async () => {
        // Initialize the index
        await sortIndexAsc.build();
        
        // Add a new record with a specific date
        const newRecordDate = new Date(now.getTime() - 6 * 24 * 60 * 60 * 1000).toISOString(); // 6 days ago
        const newRecord: TestRecord = {
            _id: '123e4567-e89b-12d3-a456-426614174006',
            name: 'Record 6',
            createdAt: newRecordDate,
            updatedAt: now.toISOString(),
            category: 'A'
        };
        
        await sortIndexAsc.addRecord(newRecord);
        
        // Find the record by its date
        const result = await sortIndexAsc.findByValue(newRecordDate);
        
        // Should find the new record
        expect(result.length).toBe(1);
        expect(result[0]._id).toBe('123e4567-e89b-12d3-a456-426614174006');
        
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
        
        // First record should now be Record 6 (6 days ago)
        expect(allRecords[0]._id).toBe('123e4567-e89b-12d3-a456-426614174006');
        
        // Verify the total record count has increased
        expect(allRecords.length).toBe(6);
    });
});