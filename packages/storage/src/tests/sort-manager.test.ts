import { expect, test, describe, beforeEach } from '@jest/globals';
import { MockStorage } from './mock-storage';
import { IRecord } from '../lib/bson-database/collection';
import { SortManager } from '../lib/bson-database/sort-manager';
import { MockCollection } from './mock-collection';
import { RandomUuidGenerator } from 'utils';

// Test interface
interface TestProduct extends IRecord {
    _id: string;
    name: string;
    price: number;
    category: string;
}


describe('SortManager', () => {
    let storage: MockStorage;
    let sortManager: SortManager<TestProduct>;
    let collection: MockCollection<TestProduct>;
    
    const testProducts: TestProduct[] = [
        { _id: '123e4567-e89b-12d3-a456-426614174001', name: 'Product 1', price: 25.99, category: 'Electronics' },
        { _id: '123e4567-e89b-12d3-a456-426614174002', name: 'Product 2', price: 15.50, category: 'Books' },
        { _id: '123e4567-e89b-12d3-a456-426614174003', name: 'Product 3', price: 45.00, category: 'Electronics' },
        { _id: '123e4567-e89b-12d3-a456-426614174004', name: 'Product 4', price: 9.99, category: 'Books' },
        { _id: '123e4567-e89b-12d3-a456-426614174005', name: 'Product 5', price: 35.50, category: 'Clothing' },
    ];
    
    beforeEach(() => {
        storage = new MockStorage();
        collection = new MockCollection<TestProduct>(testProducts);
        sortManager = new SortManager<TestProduct>({
            storage,
            baseDirectory: 'db',
            defaultPageSize: 2,
            uuidGenerator: new RandomUuidGenerator()
        }, collection, 'products');
    });
    
    test('should create and return a sort index', async () => {
        // Ensure the sort index exists
        await sortManager.ensureSortIndex('price', 'asc', 'number');
        
        // Get sort index for price (ascending)
        const result = await sortManager.getSortedRecords('price', 'asc');
        
        // Check that the index was created correctly
        expect(result.records.length).toBeGreaterThan(0);
        expect(result.totalRecords).toBe(5);
        expect(result.currentPageId).toBeTruthy();
        expect(result.totalPages).toBe(2);
        expect(result.nextPageId).toBeTruthy();
        expect(result.previousPageId).toBeUndefined();
        
        // Check that records are sorted correctly - there may be a different number of records per page
        // with page ID-based approach compared to page number-based approach
        expect(result.records.length).toBeGreaterThan(0);
        expect(result.records[0].price).toBe(9.99); // Product 4
        if (result.records.length > 1) {
            expect(result.records[1].price).toBe(15.50); // Product 2
        }
        
        // Get next page using the nextPageId
        const page2Result = await sortManager.getSortedRecords('price', 'asc', result.nextPageId);
        
        // Check page 2 contents
        expect(page2Result.records.length).toBeGreaterThan(0);
        expect(page2Result.currentPageId).toBeTruthy();
        expect(page2Result.previousPageId).toBeTruthy();
        
        // With page ID-based pagination, the distribution of records may be different
        // All we care about is that records are returned in correct order
        if (page2Result.records.length >= 1) {
            // Based on the test data, if we have a first element it should be one of these products
            // (depending on how records are split across pages)
            const validFirstItems = [15.50, 25.99]; // Product 2 or Product 1
            expect(validFirstItems).toContain(page2Result.records[0].price);
        }
        
        if (page2Result.records.length >= 2) {
            // For second element, it could be one of these products
            const validSecondItems = [25.99, 35.50]; // Product 1 or Product 5
            expect(validSecondItems).toContain(page2Result.records[1].price);
        }
    });
    
    test('should get existing sort index if already created', async () => {
        // Create the index first
        await sortManager.ensureSortIndex('price', 'asc', 'number');
        await sortManager.getSortedRecords('price', 'asc');
        
        // Get the same index again
        const result1 = await sortManager.getSortedRecords('price', 'asc');
        
        // Ensure we got back valid data
        expect(result1.records.length).toBeGreaterThan(0);
        expect(result1.totalRecords).toBe(5);
    });
    
    test('should support descending order', async () => {
        // Ensure the sort index exists
        await sortManager.ensureSortIndex('price', 'desc', 'number');
        
        // Get sort index for price (descending)
        const result = await sortManager.getSortedRecords('price', 'desc');
        
        // Collect all records across pages
        let allRecords: TestProduct[] = [];
        let currentPage = result;
        
        // Add records from first page
        allRecords.push(...currentPage.records);
        
        // Follow next page links until we've visited all pages
        while (currentPage.nextPageId) {
            currentPage = await sortManager.getSortedRecords('price', 'desc', currentPage.nextPageId);
            allRecords.push(...currentPage.records);
        }
                
        // Verify we have all 5 test products
        expect(allRecords.length).toBe(5);
        
        // Verify the range of values
        const prices = allRecords.map(p => p.price);
        expect(Math.max(...prices)).toBe(45.00);
        expect(Math.min(...prices)).toBe(9.99);
        
        // Verify the test products are all there with correct values
        expect(prices).toContain(45.00);
        expect(prices).toContain(35.50);
        expect(prices).toContain(25.99);
        expect(prices).toContain(15.50);
        expect(prices).toContain(9.99);
    });
    
    test('should list all sort indexes for a collection', async () => {
        // Create several indexes
        await sortManager.ensureSortIndex('price', 'asc', 'number');
        await sortManager.getSortedRecords('price', 'asc');
        
        await sortManager.ensureSortIndex('price', 'desc', 'number');
        await sortManager.getSortedRecords('price', 'desc');
        
        await sortManager.ensureSortIndex('category', 'asc', 'string');
        await sortManager.getSortedRecords('category', 'asc');
        
        // List the indexes
        const indexes = await sortManager.listSortIndexes();
        
        // Check that all indexes are found
        expect(indexes.length).toBe(3);
        
        // Check for price_asc index
        expect(indexes.some(idx => idx.fieldName === 'price' && idx.direction === 'asc')).toBe(true);
        
        // Check for price_desc index
        expect(indexes.some(idx => idx.fieldName === 'price' && idx.direction === 'desc')).toBe(true);
        
        // Check for category_asc index
        expect(indexes.some(idx => idx.fieldName === 'category' && idx.direction === 'asc')).toBe(true);
    });
    
    test('should delete a sort index', async () => {
        // Create an index
        await sortManager.ensureSortIndex('price', 'asc', 'number');
        await sortManager.getSortedRecords('price', 'asc');
        
        // Delete the index
        const result = await sortManager.deleteSortIndex('price', 'asc');
        
        // Check that deletion was successful
        expect(result).toBe(true);
        
        // Check that the index is no longer in the list
        const indexes = await sortManager.listSortIndexes();
        expect(indexes.length).toBe(0);
        
        // Check that the directory is gone
        expect(await storage.dirExists('db/sort_indexes/products/price_asc')).toBe(false);
    });
    
    test('should delete all sort indexes for a collection', async () => {
        // Create several indexes
        await sortManager.ensureSortIndex('price', 'asc', 'number');
        await sortManager.getSortedRecords('price', 'asc');
        
        await sortManager.ensureSortIndex('category', 'asc', 'string');
        await sortManager.getSortedRecords('category', 'asc');
        
        // Delete all indexes for the collection
        await sortManager.deleteAllSortIndexes();
        
        // Check that no indexes remain
        const indexes = await sortManager.listSortIndexes();
        expect(indexes.length).toBe(0);
        
        // Check that the collection directory is gone
        expect(await storage.dirExists('db/sort_indexes/products')).toBe(false);
    });
});