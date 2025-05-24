import { expect, test, describe, beforeEach } from '@jest/globals';
import { MockStorage } from './mock-storage';
import { IBsonCollection, IRecord, IShard } from '../lib/bson-database/collection';
import { SortManager } from '../lib/bson-database/sort-manager';

// Test interface
interface TestProduct extends IRecord {
    _id: string;
    name: string;
    price: number;
    category: string;
}

// Mock BsonCollection for testing SortManager
class MockCollection implements IBsonCollection<TestProduct> {
    private records: TestProduct[] = [];

    constructor(records: TestProduct[] = []) {
        this.records = [...records];
    }

    async insertOne(record: TestProduct): Promise<void> {
        this.records.push(record);
    }

    async getOne(id: string): Promise<TestProduct | undefined> {
        return this.records.find(r => r._id === id);
    }

    async *iterateRecords(): AsyncGenerator<TestProduct, void, unknown> {
        for (const record of this.records) {
            yield record;
        }
    }

    async *iterateShards(): AsyncGenerator<Iterable<TestProduct>, void, unknown> {
        for (let i = 0; i < this.records.length; i += 2) {
            yield this.records.slice(i, i + 2);
        }
    }

    async getAll(next?: string): Promise<{ records: TestProduct[], next?: string }> {
        return { records: this.records, next: undefined };
    }

    async getSorted(fieldName: string, options?: { direction?: 'asc' | 'desc'; page?: number; pageSize?: number }): Promise<{
        records: TestProduct[];
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

    async updateOne(id: string, updates: Partial<TestProduct>, options?: { upsert?: boolean }): Promise<boolean> {
        const index = this.records.findIndex(r => r._id === id);
        if (index === -1) {
            if (options?.upsert) {
                this.records.push({ _id: id, ...updates } as TestProduct);
                return true;
            }
            return false;
        }
        this.records[index] = { ...this.records[index], ...updates };
        return true;
    }

    async replaceOne(id: string, record: TestProduct, options?: { upsert?: boolean }): Promise<boolean> {
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

    async findByIndex(fieldName: string, value: any): Promise<TestProduct[]> {
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

    async loadShard(shardIndex: number): Promise<IShard<TestProduct>> {
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

describe('SortManager', () => {
    let storage: MockStorage;
    let sortManager: SortManager;
    let collection: MockCollection;
    
    const testProducts: TestProduct[] = [
        { _id: '123e4567-e89b-12d3-a456-426614174001', name: 'Product 1', price: 25.99, category: 'Electronics' },
        { _id: '123e4567-e89b-12d3-a456-426614174002', name: 'Product 2', price: 15.50, category: 'Books' },
        { _id: '123e4567-e89b-12d3-a456-426614174003', name: 'Product 3', price: 45.00, category: 'Electronics' },
        { _id: '123e4567-e89b-12d3-a456-426614174004', name: 'Product 4', price: 9.99, category: 'Books' },
        { _id: '123e4567-e89b-12d3-a456-426614174005', name: 'Product 5', price: 35.50, category: 'Clothing' },
    ];
    
    beforeEach(() => {
        storage = new MockStorage();
        sortManager = new SortManager({
            storage,
            baseDirectory: 'db',
            defaultPageSize: 2
        });
        collection = new MockCollection(testProducts);
    });
    
    test('should create and return a sort index', async () => {
        // Get sort index for price (ascending)
        const result = await sortManager.getSortedRecords<TestProduct>(
            collection,
            'products',
            'price',
            { direction: 'asc', page: 1 }
        );
        
        // Check that the index was created correctly
        expect(result.records.length).toBe(2);
        expect(result.totalRecords).toBe(5);
        expect(result.currentPage).toBe(1);
        expect(result.totalPages).toBe(3);
        expect(result.nextPage).toBe(2);
        expect(result.previousPage).toBeUndefined();
        
        // Check that records are sorted correctly
        expect(result.records[0].price).toBe(9.99); // Product 4
        expect(result.records[1].price).toBe(15.50); // Product 2
        
        // Get page 2
        const page2Result = await sortManager.getSortedRecords<TestProduct>(
            collection,
            'products',
            'price',
            { direction: 'asc', page: 2 }
        );
        
        // Check page 2 contents
        expect(page2Result.records.length).toBe(2);
        expect(page2Result.currentPage).toBe(2);
        expect(page2Result.previousPage).toBe(1);
        expect(page2Result.nextPage).toBe(3);
        
        // Check that records are sorted correctly
        expect(page2Result.records[0].price).toBe(25.99); // Product 1
        expect(page2Result.records[1].price).toBe(35.50); // Product 5
    });
    
    test('should get existing sort index if already created', async () => {
        // Create the index first
        await sortManager.getSortedRecords<TestProduct>(
            collection,
            'products',
            'price',
            { direction: 'asc' }
        );
        
        // Get the same index again
        const result1 = await sortManager.getSortedRecords<TestProduct>(
            collection,
            'products',
            'price',
            { direction: 'asc' }
        );
        
        // Ensure we got back valid data
        expect(result1.records.length).toBe(2);
        expect(result1.totalRecords).toBe(5);
    });
    
    test('should support descending order', async () => {
        // Get sort index for price (descending)
        const result = await sortManager.getSortedRecords<TestProduct>(
            collection,
            'products',
            'price',
            { direction: 'desc', page: 1 }
        );
        
        // Check that records are sorted correctly (high to low)
        expect(result.records[0].price).toBe(45.00); // Product 3
        expect(result.records[1].price).toBe(35.50); // Product 5
    });
    
    test('should list all sort indexes for a collection', async () => {
        // Create several indexes
        await sortManager.getSortedRecords<TestProduct>(
            collection,
            'products',
            'price',
            { direction: 'asc' }
        );
        
        await sortManager.getSortedRecords<TestProduct>(
            collection,
            'products',
            'price',
            { direction: 'desc' }
        );
        
        await sortManager.getSortedRecords<TestProduct>(
            collection,
            'products',
            'category',
            { direction: 'asc' }
        );
        
        // List the indexes
        const indexes = await sortManager.listSortIndexes('products');
        
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
        await sortManager.getSortedRecords<TestProduct>(
            collection,
            'products',
            'price',
            { direction: 'asc' }
        );
        
        // Delete the index
        const result = await sortManager.deleteSortIndex('products', 'price', 'asc');
        
        // Check that deletion was successful
        expect(result).toBe(true);
        
        // Check that the index is no longer in the list
        const indexes = await sortManager.listSortIndexes('products');
        expect(indexes.length).toBe(0);
        
        // Check that the directory is gone
        expect(await storage.dirExists('db/sort_indexes/products/price_asc')).toBe(false);
    });
    
    test('should rebuild an existing sort index', async () => {
        // Create the index first
        await sortManager.getSortedRecords<TestProduct>(
            collection,
            'products',
            'price',
            { direction: 'asc' }
        );
        
        // Add a new record to the collection
        const newProduct: TestProduct = {
            _id: '123e4567-e89b-12d3-a456-426614174006',
            name: 'Product 6',
            price: 5.99,
            category: 'Books'
        };
        await collection.insertOne(newProduct);
        
        // Rebuild the index to include the new record
        await sortManager.rebuildSortIndex<TestProduct>(
            collection,
            'products',
            'price',
            'asc'
        );
        
        // Get the updated index
        const result = await sortManager.getSortedRecords<TestProduct>(
            collection,
            'products',
            'price',
            { direction: 'asc', page: 1 }
        );
        
        // Check that the new record is included
        expect(result.totalRecords).toBe(6);
        expect(result.records[0].price).toBe(5.99); // The new Product 6
    });
    
    test('should delete all sort indexes for a collection', async () => {
        // Create several indexes
        await sortManager.getSortedRecords<TestProduct>(
            collection,
            'products',
            'price',
            { direction: 'asc' }
        );
        
        await sortManager.getSortedRecords<TestProduct>(
            collection,
            'products',
            'category',
            { direction: 'asc' }
        );
        
        // Delete all indexes for the collection
        await sortManager.deleteAllSortIndexes('products');
        
        // Check that no indexes remain
        const indexes = await sortManager.listSortIndexes('products');
        expect(indexes.length).toBe(0);
        
        // Check that the collection directory is gone
        expect(await storage.dirExists('db/sort_indexes/products')).toBe(false);
    });
});