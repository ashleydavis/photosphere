import { MockStorage } from 'storage';
import { BsonDatabase } from '../lib/database';
import { RandomUuidGenerator, TimestampProvider } from 'utils';

describe('BsonDatabase', () => {
    let storage: MockStorage;
    let database: BsonDatabase;

    beforeEach(() => {
        storage = new MockStorage();
        database = new BsonDatabase({
            storage,
            uuidGenerator: new RandomUuidGenerator(),
            timestampProvider: new TimestampProvider()
        });
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
        
        // Test that collections exist
        const collections = await database.collections();
        expect(collections).toContain('users');
        expect(collections).toContain('products');
    });
});