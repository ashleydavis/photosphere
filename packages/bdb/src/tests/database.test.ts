import { MockStorage } from 'storage';
import { BsonDatabase } from '../lib/database';
import { RandomUuidGenerator, TimestampProvider } from 'utils';

//
// Valid UUID v4 strings for use as record IDs in tests.
//
const ID1 = '11111111-1111-4111-a111-111111111111';
const ID2 = '22222222-2222-4222-a222-222222222222';
const ID3 = '33333333-3333-4333-a333-333333333333';

describe('BsonDatabase', () => {
    let storage: MockStorage;
    let database: BsonDatabase;

    beforeEach(() => {
        storage = new MockStorage();
        database = new BsonDatabase(storage, "", new RandomUuidGenerator(), new TimestampProvider());
    });

    //
    // collection()
    //

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

    //
    // collections()
    //

    test('should list collections created in memory', async () => {
        database.collection('users');
        database.collection('products');
        database.collection('orders');

        const collections = await database.collections();

        expect(collections).toContain('users');
        expect(collections).toContain('products');
        expect(collections).toContain('orders');
    });

    test('should list collections from storage', async () => {
        await storage.write('collections/metadata/shards/0', undefined, Buffer.from('test'));

        const collections = await database.collections();

        expect(collections).toContain('metadata');
    });

    test('should merge in-memory and storage collections without duplicates', async () => {
        database.collection('users');
        await storage.write('collections/users/shards/0', undefined, Buffer.from('test'));
        await storage.write('collections/photos/shards/0', undefined, Buffer.from('test'));

        const collections = await database.collections();

        const userEntries = collections.filter(name => name === 'users');
        expect(userEntries).toHaveLength(1);
        expect(collections).toContain('photos');
    });

    test('should return empty array when no collections exist', async () => {
        const collections = await database.collections();
        expect(collections).toHaveLength(0);
    });

    //
    // commit()
    //

    test('commit should be a no-op when not dirty', async () => {
        // Should not throw and should complete quickly
        await database.commit();
    });

    test('commit should allow flush after completing', async () => {
        const users = database.collection<{ _id: string; name: string }>('users');
        await users.insertOne({ _id: ID1, name: 'Alice' });

        await database.commit();

        // After commit, flush should succeed (dirty flag cleared)
        expect(() => database.flush()).not.toThrow();
    });

    test('commit clears dirty flag so a second commit is a no-op', async () => {
        const users = database.collection<{ _id: string; name: string }>('users');
        await users.insertOne({ _id: ID1, name: 'Alice' });

        await database.commit();

        // Second commit should not throw and should be a no-op
        await database.commit();
    });

    test('commit processes multiple collections', async () => {
        const users = database.collection<{ _id: string; name: string }>('users');
        const products = database.collection<{ _id: string; title: string }>('products');

        await users.insertOne({ _id: ID1, name: 'Alice' });
        await products.insertOne({ _id: ID2, title: 'Widget' });

        // Should not throw when committing multiple collections
        await database.commit();
        expect(() => database.flush()).not.toThrow();
    });

    //
    // flush()
    //

    test('flush should throw when database is dirty', async () => {
        const users = database.collection<{ _id: string; name: string }>('users');
        await users.insertOne({ _id: ID1, name: 'Alice' });

        expect(() => database.flush()).toThrow();
    });

    test('flush should succeed when database is not dirty', () => {
        // Never modified — flush should not throw
        expect(() => database.flush()).not.toThrow();
    });

    test('flush should succeed after commit', async () => {
        const users = database.collection<{ _id: string; name: string }>('users');
        await users.insertOne({ _id: ID1, name: 'Alice' });

        await database.commit();
        expect(() => database.flush()).not.toThrow();
    });

    test('flush evicts collection internal state but keeps the collection object cached', async () => {
        const users = database.collection<{ _id: string; name: string }>('users');
        await users.insertOne({ _id: ID1, name: 'Alice' });
        await database.commit();

        database.flush();

        // The same collection instance is returned (collection objects stay cached)
        const users2 = database.collection<{ _id: string; name: string }>('users');
        expect(users2).toBe(users);
    });

    //
    // merkleTree()
    //

    test('merkleTree should return an IMerkleRef', () => {
        const ref = database.merkleTree();
        expect(ref).toBeDefined();
        expect(typeof ref.get).toBe('function');
        expect(typeof ref.upsert).toBe('function');
        expect(typeof ref.remove).toBe('function');
        expect(typeof ref.commit).toBe('function');
        expect(typeof ref.flush).toBe('function');
    });

    test('merkleTree should return the same instance on repeated calls', () => {
        const ref1 = database.merkleTree();
        const ref2 = database.merkleTree();
        expect(ref1).toBe(ref2);
    });

    test('merkleTree get should return undefined for an empty database', async () => {
        const tree = await database.merkleTree().get();
        expect(tree).toBeUndefined();
    });

    test('merkleTree should return a new instance after flush', async () => {
        const ref1 = database.merkleTree();
        // Must commit before flushing (even though nothing is dirty)
        database.flush();
        const ref2 = database.merkleTree();
        expect(ref2).not.toBe(ref1);
    });
});
