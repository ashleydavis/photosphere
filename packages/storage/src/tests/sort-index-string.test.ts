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
    category: string;
    status: string;
    title: string;
}


describe('SortIndex with string type', () => {
    let storage: MockStorage;
    let sortIndexAsc: SortIndex<TestRecord>;
    let sortIndexDesc: SortIndex<TestRecord>;
    let collection: MockCollection<TestRecord>;
    
    const testRecords: TestRecord[] = [
        { 
            _id: '123e4567-e89b-12d3-a456-426614174001', 
            name: 'zebra', 
            category: 'animal',
            status: 'active',
            title: 'Mr. Zebra'
        },
        { 
            _id: '123e4567-e89b-12d3-a456-426614174002', 
            name: 'apple', 
            category: 'fruit',
            status: 'pending',
            title: 'Green Apple'
        },
        { 
            _id: '123e4567-e89b-12d3-a456-426614174003', 
            name: 'banana', 
            category: 'fruit',
            status: 'completed',
            title: 'Yellow Banana'
        },
        { 
            _id: '123e4567-e89b-12d3-a456-426614174004', 
            name: 'cat', 
            category: 'animal',
            status: 'active',
            title: 'Fluffy Cat'
        },
        { 
            _id: '123e4567-e89b-12d3-a456-426614174005', 
            name: 'orange', 
            category: 'fruit',
            status: 'inactive',
            title: 'Orange Fruit'
        },
        { 
            _id: '123e4567-e89b-12d3-a456-426614174006', 
            name: 'Apple', 
            category: 'fruit',
            status: 'active',
            title: 'Red Apple'
        },
        { 
            _id: '123e4567-e89b-12d3-a456-426614174007', 
            name: 'Zebra', 
            category: 'animal',
            status: 'pending',
            title: 'Big Zebra'
        },
    ];
    
    beforeEach(() => {
        storage = new MockStorage();
        collection = new MockCollection<TestRecord>(testRecords);
        
        // Create ascending index on name field
        sortIndexAsc = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'test_collection',
            fieldName: 'name',
            direction: 'asc',
            pageSize: 3,
            type: 'string', // Specify string type for proper comparison
            uuidGenerator: new RandomUuidGenerator(),
            isReadonly: false,
        }, collection);
        
        // Create descending index on status field
        sortIndexDesc = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'test_collection',
            fieldName: 'status',
            direction: 'desc',
            pageSize: 3,
            type: 'string', // Specify string type for proper comparison
            uuidGenerator: new RandomUuidGenerator(),
            isReadonly: false,
        }, collection);
    });
    
    test('should initialize the string sort indexes with records', async () => {
        // Initialize both indexes
        await sortIndexAsc.build();
        await sortIndexDesc.build();
        
        // Check that tree files have been written
        expect(await storage.fileExists('db/sort_indexes/test_collection/name_asc/tree.dat')).toBe(true);
        expect(await storage.fileExists('db/sort_indexes/test_collection/status_desc/tree.dat')).toBe(true);
    });
    
    test('should retrieve records in ascending string order', async () => {
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
        
        
        // Verify records are in ascending string order using localeCompare
        for (let i = 1; i < allRecords.length; i++) {
            const prevName = String(allRecords[i-1].name);
            const currName = String(allRecords[i].name);
            expect(prevName.localeCompare(currName)).toBeLessThanOrEqual(0);
        }
        
        // Check specific ordering - locale-aware string comparison
        // Using localeCompare, case differences are typically ignored for primary sorting
        const actualNames = allRecords.map(r => r.name);
        
        // With locale comparison, 'apple' and 'Apple' should be grouped together
        // and 'zebra' and 'Zebra' should be grouped together
        const appleIndex = actualNames.findIndex(name => name.toLowerCase() === 'apple');
        const bananaIndex = actualNames.findIndex(name => name === 'banana');
        const zebraIndex = actualNames.findIndex(name => name.toLowerCase() === 'zebra');
        
        expect(appleIndex).toBeLessThan(bananaIndex); // apple comes before banana
        expect(bananaIndex).toBeLessThan(zebraIndex); // banana comes before zebra
    });
    
    test('should retrieve records in descending string order', async () => {
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
        
        // Verify records are in descending string order
        for (let i = 1; i < allRecords.length; i++) {
            const prevStatus = String(allRecords[i-1].status);
            const currStatus = String(allRecords[i].status);
            expect(prevStatus.localeCompare(currStatus)).toBeGreaterThanOrEqual(0);
        }
        
        // Check specific ordering - descending alphabetical
        // Expected order: "pending", "pending", "inactive", "completed", "active", "active", "active"
        expect(allRecords[0].status).toBe('pending');
        expect(allRecords[allRecords.length - 1].status).toBe('active');
    });
    
    test('should find records by exact string value', async () => {
        // Initialize the index
        await sortIndexAsc.build();
        
        // Find records with exact string match
        const result = await sortIndexAsc.findByValue('apple');
        
        // Should find exactly one record with lowercase 'apple'
        expect(result.length).toBe(1);
        expect(result[0]._id).toBe('123e4567-e89b-12d3-a456-426614174002');
        expect(result[0].name).toBe('apple');
        
        // Find records with exact string match for 'Apple' (different case)
        const resultCaps = await sortIndexAsc.findByValue('Apple');
        
        // Should find exactly one record with uppercase 'Apple'
        expect(resultCaps.length).toBe(1);
        expect(resultCaps[0]._id).toBe('123e4567-e89b-12d3-a456-426614174006');
        expect(resultCaps[0].name).toBe('Apple');
        
        // Find a non-existent string
        const noResult = await sortIndexAsc.findByValue('nonexistent');
        
        // Should find no records
        expect(noResult.length).toBe(0);
    });
    
    test('should find records by string range', async () => {
        // Initialize the index
        await sortIndexAsc.build();
        
        // Find records with names between 'b' and 'o' (inclusive)
        const result = await sortIndexAsc.findByRange({
            min: 'b',
            max: 'o',
            minInclusive: true,
            maxInclusive: true
        });
        
        // Should find records: "banana", "cat"
        expect(result.length).toBe(2);
        const names = result.map(r => r.name).sort();
        expect(names).toEqual(['banana', 'cat']);
        
        // Test exclusive range (between 'a' and 'z', non-inclusive)
        const exclusiveResult = await sortIndexAsc.findByRange({
            min: 'a',
            max: 'z',
            minInclusive: false,
            maxInclusive: false
        });
        
        // Should find records that are greater than 'a' and less than 'z'
        // With localeCompare, both 'Apple' and 'apple' are > 'a', and both 'Zebra' and 'zebra' are > 'z'
        // So this will include: "Apple", "apple", "banana", "cat", "orange"
        expect(exclusiveResult.length).toBe(5);
        const exclusiveNames = exclusiveResult.map(r => r.name).sort();
        expect(exclusiveNames).toEqual(['Apple', 'apple', 'banana', 'cat', 'orange']);
        
        // Verify all results are properly within range
        for (const record of exclusiveResult) {
            expect(record.name.localeCompare('a')).toBeGreaterThan(0);
            expect(record.name.localeCompare('z')).toBeLessThan(0);
        }
    });
    
    test('should update records with new string values in the index', async () => {
        // Initialize the index
        await sortIndexAsc.build();
        
        // Update a record with a new name
        const updatedRecord: TestRecord = {
            ...testRecords[2], // Clone banana record
            name: 'kiwi' // Change name from 'banana' to 'kiwi'
        };
        
        await sortIndexAsc.updateRecord(updatedRecord, testRecords[2]);
        
        // Find records by the new name
        const result = await sortIndexAsc.findByValue('kiwi');
        
        // Should find the updated record with the new name
        expect(result.length).toBe(1);
        expect(result[0]._id).toBe('123e4567-e89b-12d3-a456-426614174003');
        expect(result[0].name).toBe('kiwi');
        
        // Original name should no longer have this record
        const oldNameResult = await sortIndexAsc.findByValue('banana');
        expect(oldNameResult.length).toBe(0);
        
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
        expect(allRecords[updatedRecordIndex].name).toBe('kiwi');
        
        // Verify sorting is still correct
        for (let i = 1; i < allRecords.length; i++) {
            const prevName = String(allRecords[i-1].name);
            const currName = String(allRecords[i].name);
            expect(prevName.localeCompare(currName)).toBeLessThanOrEqual(0);
        }
    });
    
    test('should add a new record with a string value to the index', async () => {
        // Initialize the index
        await sortIndexAsc.build();
        
        // Add a new record with a specific name
        const newRecord: TestRecord = {
            _id: '123e4567-e89b-12d3-a456-426614174008',
            name: 'grape',
            category: 'fruit',
            status: 'active',
            title: 'Purple Grape'
        };
        
        await sortIndexAsc.addRecord(newRecord);
        
        // Find the record by its name
        const result = await sortIndexAsc.findByValue('grape');
        
        // Should find the new record
        expect(result.length).toBe(1);
        expect(result[0]._id).toBe('123e4567-e89b-12d3-a456-426614174008');
        
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
        
        // Verify the new record is in the correct alphabetical position
        const grapeIndex = allRecords.findIndex(r => r.name === 'grape');
        expect(grapeIndex).toBeGreaterThan(-1);
        
        // Verify the total record count has increased
        expect(allRecords.length).toBe(8);
        
        // Verify sorting is still correct
        for (let i = 1; i < allRecords.length; i++) {
            const prevName = String(allRecords[i-1].name);
            const currName = String(allRecords[i].name);
            expect(prevName.localeCompare(currName)).toBeLessThanOrEqual(0);
        }
    });
    
    test('should handle mixed case string comparisons correctly', async () => {
        // Initialize the index
        await sortIndexAsc.build();
        
        // Get all records sorted
        let allRecords: TestRecord[] = [];
        let currentPage = await sortIndexAsc.getPage('');
        
        allRecords = [...allRecords, ...currentPage.records];
        
        while (currentPage.nextPageId) {
            currentPage = await sortIndexAsc.getPage(currentPage.nextPageId);
            allRecords = [...allRecords, ...currentPage.records];
        }
        
        // Extract just the names in order
        const sortedNames = allRecords.map(r => r.name);
        
        // Verify that locale-aware sorting groups similar words together
        // With localeCompare, case differences are secondary to alphabetical order
        // We should see apple/Apple grouped, zebra/Zebra grouped, etc.
        
        // Find positions of key words
        const appleVariants = sortedNames.filter(name => name.toLowerCase() === 'apple');
        const zebraVariants = sortedNames.filter(name => name.toLowerCase() === 'zebra');
        const bananaIndex = sortedNames.findIndex(name => name === 'banana');
        const catIndex = sortedNames.findIndex(name => name === 'cat');
        
        // Should have both Apple variants
        expect(appleVariants.length).toBe(2);
        expect(appleVariants).toContain('Apple');
        expect(appleVariants).toContain('apple');
        
        // Should have both Zebra variants
        expect(zebraVariants.length).toBe(2);
        expect(zebraVariants).toContain('Zebra');
        expect(zebraVariants).toContain('zebra');
        
        // Find both Apple and apple separately (they should still be distinct records)
        const upperApple = await sortIndexAsc.findByValue('Apple');
        const lowerApple = await sortIndexAsc.findByValue('apple');
        
        expect(upperApple.length).toBe(1);
        expect(lowerApple.length).toBe(1);
        expect(upperApple[0]._id).not.toBe(lowerApple[0]._id);
    });
    
    test('should handle numeric strings as strings, not numbers', async () => {
        // Add records with numeric strings
        const numericStringRecords: TestRecord[] = [
            { _id: 'num1', name: '10', category: 'number', status: 'active', title: 'Ten' },
            { _id: 'num2', name: '2', category: 'number', status: 'active', title: 'Two' },
            { _id: 'num3', name: '100', category: 'number', status: 'active', title: 'Hundred' },
            { _id: 'num4', name: '20', category: 'number', status: 'active', title: 'Twenty' },
        ];
        
        const numericCollection = new MockCollection(numericStringRecords);
        const numericSortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'numeric_test',
            fieldName: 'name',
            direction: 'asc',
            pageSize: 3,
            type: 'string',
            uuidGenerator: new RandomUuidGenerator(),
            isReadonly: false,
        }, numericCollection);
        
        await numericSortIndex.build();
        
        // Get all records sorted
        let allRecords: TestRecord[] = [];
        let currentPage = await numericSortIndex.getPage('');
        
        allRecords = [...allRecords, ...currentPage.records];
        
        while (currentPage.nextPageId) {
            currentPage = await numericSortIndex.getPage(currentPage.nextPageId);
            allRecords = [...allRecords, ...currentPage.records];
        }
        
        // Extract names in order
        const sortedNames = allRecords.map(r => r.name);
        
        // As strings with localeCompare, they should be sorted lexicographically: "10", "100", "2", "20"
        // NOT numerically which would be: "2", "10", "20", "100"
        // localeCompare typically gives the same result as ASCII for numeric strings
        expect(sortedNames).toEqual(["10", "100", "2", "20"]);
    });
});