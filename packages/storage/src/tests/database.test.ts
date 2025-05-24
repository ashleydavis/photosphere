import { expect, jest, test, describe, beforeEach, afterEach } from '@jest/globals';
import { MockStorage } from './mock-storage';
import { BsonDatabase } from '../lib/bson-database/database';

describe('BsonDatabase', () => {
    let storage: MockStorage;
    let database: BsonDatabase;

    beforeEach(() => {
        storage = new MockStorage();
        database = new BsonDatabase({
            storage,
            maxCachedShards: 5
        });
    });

    afterEach(async () => {
        await database.close();
    });

    test('should create a new collection', () => {
        const collection = database.collection('users');
        expect(collection).toBeDefined();
    });

    test('should return the same collection instance for the same name', () => {
        const collection1 = database.collection('users');
        const collection2 = database.collection('users');
        expect(collection1).toBe(collection2);
    });

    test('should return different collection instances for different names', () => {
        const collection1 = database.collection('users');
        const collection2 = database.collection('products');
        expect(collection1).not.toBe(collection2);
    });

    test('should list collections', async () => {
        // Create some collections
        database.collection('users');
        database.collection('products');
        database.collection('orders');
        
        // Add some files in the storage to simulate existing collections
        await storage.write('metadata/1', undefined, Buffer.from('test'));
        
        const collections = await database.collections();
        
        // Should include collections from both memory and storage
        expect(collections).toContain('users');
        expect(collections).toContain('products');
        expect(collections).toContain('orders');
        expect(collections).toContain('metadata');
    });

    test('should close all collections', async () => {
        // Create some collections and perform operations
        const users = database.collection('users');
        const products = database.collection('products');
        
        // Spy on collection shutdown method
        const shutdownSpy = jest.spyOn(users, 'shutdown');
        
        // Close the database
        await database.close();
        
        // Verify that shutdown was called on all collections
        expect(shutdownSpy).toHaveBeenCalled();
        
        // Check internal state
        const collections = await database.collections();
        expect(collections).not.toContain('users');
        expect(collections).not.toContain('products');
    });
});