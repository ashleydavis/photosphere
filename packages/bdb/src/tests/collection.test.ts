import { MockStorage } from 'storage';
import { BsonCollection, type IRecord } from '../lib/collection';
import type { IInternalRecord } from '../lib/shard';
import { RandomUuidGenerator, TimestampProvider } from 'utils';

// Test interfaces
interface TestUser extends IRecord {
    _id: string;
    name: string;
    email: string;
    age: number;
    role: string;
}

describe('BsonCollection', () => {
    let storage: MockStorage;
    let collection: BsonCollection<TestUser>;
    
    beforeEach(() => {
        storage = new MockStorage();
        collection = new BsonCollection<TestUser>(
            'users',
            '',
            storage,
            '',
            new RandomUuidGenerator(),
            new TimestampProvider(),
            () => {},
        );
    });
        
    test('should insert and retrieve a record', async () => {
        const user: TestUser = {
            _id: '123e4567-e89b-12d3-a456-426614174000',
            name: 'John Doe',
            email: 'john@example.com',
            age: 30,
            role: 'user'
        };
        
        await collection.insertOne(user);
        
        const retrieved = await collection.getOne(user._id);
        expect(retrieved).toEqual(user);
    });
    
    test('should generate an ID if not provided', async () => {
        const user: TestUser = {
            _id: '', // Empty ID will be replaced
            name: 'Jane Doe',
            email: 'jane@example.com',
            age: 25,
            role: 'admin'
        };
        
        await collection.insertOne(user as any); // Cast to any to bypass TypeScript error
        
        // Get all records to find the one we inserted
        const result = await collection.getAll();
        expect(result.records.length).toBe(1);
        
        const retrieved = result.records[0];
        expect(retrieved.name).toBe('Jane Doe');
        expect(retrieved._id).toBeTruthy(); // ID should have been generated
        expect(retrieved._id.length).toBe(36); // UUID format
    });
    
    test('should update a record', async () => {
        const user: TestUser = {
            _id: '123e4567-e89b-12d3-a456-426614174000',
            name: 'John Doe',
            email: 'john@example.com',
            age: 30,
            role: 'user'
        };
        
        await collection.insertOne(user);
        
        const updates = {
            age: 31,
            role: 'admin'
        };
        
        const updateResult = await collection.updateOne(user._id, updates);
        expect(updateResult).toBe(true);
        
        const updated = await collection.getOne(user._id);
        expect(updated).toEqual({
            ...user,
            ...updates
        });
    });
    
    test('should return false when updating non-existent record', async () => {
        const nonExistentId = '123e4567-e89b-12d3-a456-000000000000';
        const updates = { name: 'New Name' };
        
        const updateResult = await collection.updateOne(nonExistentId, updates);
        expect(updateResult).toBe(false);
    });
    
    test('should upsert a record', async () => {
        const id = '123e4567-e89b-12d3-a456-426614174001';
        const updates = {
            name: 'Upserted User',
            email: 'upsert@example.com',
            age: 40,
            role: 'guest'
        };
        
        const updateResult = await collection.updateOne(id, updates, { upsert: true });
        expect(updateResult).toBe(true);
        
        const upserted = await collection.getOne(id);
        expect(upserted).toEqual({
            _id: id,
            ...updates
        });
    });
    
    test('should replace a record', async () => {
        const user: TestUser = {
            _id: '123e4567-e89b-12d3-a456-426614174000',
            name: 'John Doe',
            email: 'john@example.com',
            age: 30,
            role: 'user'
        };
        
        await collection.insertOne(user);
        
        const replacement: TestUser = {
            _id: user._id,
            name: 'John Smith',
            email: 'smith@example.com',
            age: 35,
            role: 'admin'
        };
        
        const replaceResult = await collection.replaceOne(user._id, replacement);
        expect(replaceResult).toBe(true);
        
        const replaced = await collection.getOne(user._id);
        expect(replaced).toEqual(replacement);
    });
    
    test('should delete a record', async () => {
        const user: TestUser = {
            _id: '123e4567-e89b-12d3-a456-426614174000',
            name: 'John Doe',
            email: 'john@example.com',
            age: 30,
            role: 'user'
        };
        
        await collection.insertOne(user);
        
        const deleteResult = await collection.deleteOne(user._id);
        expect(deleteResult).toBe(true);
        
        const deleted = await collection.getOne(user._id);
        expect(deleted).toBeUndefined();
    });
    
    test('should return false when deleting non-existent record', async () => {
        const nonExistentId = '123e4567-e89b-12d3-a456-000000000000';
        
        const deleteResult = await collection.deleteOne(nonExistentId);
        expect(deleteResult).toBe(false);
    });
    
    test('should iterate through all records', async () => {
        const users = [
            {
                _id: '123e4567-e89b-12d3-a456-426614174001',
                name: 'User 1',
                email: 'user1@example.com',
                age: 30,
                role: 'user'
            },
            {
                _id: '123e4567-e89b-12d3-a456-426614174002',
                name: 'User 2',
                email: 'user2@example.com',
                age: 35,
                role: 'admin'
            },
            {
                _id: '123e4567-e89b-12d3-a456-426614174003',
                name: 'User 3',
                email: 'user3@example.com',
                age: 25,
                role: 'user'
            }
        ];
        
        // Insert all users
        for (const user of users) {
            await collection.insertOne(user);
        }
                
        // Collect all records from the iterator
        const retrievedUsers: IInternalRecord[] = [];
        for await (const user of collection.iterateRecords()) {
            retrievedUsers.push(user);
        }
        
        // Check that all users were retrieved
        expect(retrievedUsers.length).toBe(users.length);
        
        // Check that each user was retrieved
        for (const user of users) {
            expect(retrievedUsers.some(u => u._id === user._id)).toBe(true);
        }
    });
    
    test('should paginate through records', async () => {
        const users = [
            {
                _id: '123e4567-e89b-12d3-a456-426614174001',
                name: 'User 1',
                email: 'user1@example.com',
                age: 30,
                role: 'user'
            },
            {
                _id: '123e4567-e89b-12d3-a456-426614174002',
                name: 'User 2',
                email: 'user2@example.com',
                age: 35,
                role: 'admin'
            },
            {
                _id: '123e4567-e89b-12d3-a456-426614174003',
                name: 'User 3',
                email: 'user3@example.com',
                age: 25,
                role: 'user'
            }
        ];
        
        // Insert all users
        for (const user of users) {
            await collection.insertOne(user);
        }
                
        // Get first page
        let result = await collection.getAll();
        expect(result.records.length).toBeGreaterThan(0);
        expect(result.next).toBeDefined();
        
        let allUsers: TestUser[] = [...result.records];
        
        // Continue pagination if there are more pages
        while (result.next) {
            result = await collection.getAll(result.next);
            allUsers = [...allUsers, ...result.records];
        }
        
        // Check that all users were retrieved
        expect(allUsers.length).toBe(users.length);
        
        // Check that each user was retrieved
        for (const user of users) {
            expect(allUsers.some(u => u._id === user._id)).toBe(true);
        }
    });
    
    test('should create and use a sort index', async () => {
        const users = [
            {
                _id: '123e4567-e89b-12d3-a456-426614174001',
                name: 'John Doe',
                email: 'john@example.com',
                age: 30,
                role: 'user'
            },
            {
                _id: '123e4567-e89b-12d3-a456-426614174002',
                name: 'Alice Smith',
                email: 'alice@example.com',
                age: 25,
                role: 'admin'
            },
            {
                _id: '123e4567-e89b-12d3-a456-426614174003',
                name: 'Bob Johnson',
                email: 'bob@example.com',
                age: 35,
                role: 'user'
            }
        ];
        
        // Insert all users
        for (const user of users) {
            await collection.insertOne(user);
        }
                
        // Create an index on the age field
        await collection.sortIndex('age', 'asc').ensure(collection, 'number');

        // Get sorted records
        const result = await collection.sortIndex('age', 'asc').getPage();

        // Check that the records are sorted by age
        expect(result.records.length).toBe(users.length);
        expect(result.records[0].age).toBe(25); // Alice
        expect(result.records[1].age).toBe(30); // John
        expect(result.records[2].age).toBe(35); // Bob
    });
    
    test('should find records by index value', async () => {
        const users = [
            {
                _id: '123e4567-e89b-12d3-a456-426614174001',
                name: 'User 1',
                email: 'user1@example.com',
                age: 30,
                role: 'user'
            },
            {
                _id: '123e4567-e89b-12d3-a456-426614174002',
                name: 'User 2',
                email: 'user2@example.com',
                age: 35,
                role: 'admin'
            },
            {
                _id: '123e4567-e89b-12d3-a456-426614174003',
                name: 'User 3',
                email: 'user3@example.com',
                age: 30,
                role: 'user'
            }
        ];
        
        // Insert all users
        for (const user of users) {
            await collection.insertOne(user);
        }
                
        // Create an index on the role field
        await collection.sortIndex('role', 'asc').ensure(collection, 'string');

        // Find users with role 'user'
        const userRoleResults = await collection.sortIndex('role', 'asc').findByValue('user') as TestUser[];
        expect(userRoleResults.length).toBe(2);
        expect(userRoleResults.every(u => u.role === 'user')).toBe(true);
        
        // Find users with role 'admin'
        const adminRoleResults = await collection.sortIndex('role', 'asc').findByValue('admin') as TestUser[];
        expect(adminRoleResults.length).toBe(1);
        expect(adminRoleResults[0].role).toBe('admin');
        
        // Create an index on the age field
        await collection.sortIndex('age', 'asc').ensure(collection, 'number');

        // Find users with age 30
        const age30Results = await collection.sortIndex('age', 'asc').findByValue(30) as TestUser[];
        expect(age30Results.length).toBe(2);
        expect(age30Results.every(u => u.age === 30)).toBe(true);
    });
    
    test('should list and delete sort indexes', async () => {
        // Create some indexes
        await collection.sortIndex('age', 'asc').ensure(collection, 'number');
        await collection.sortIndex('role', 'asc').ensure(collection, 'string');
        await collection.sortIndex('name', 'desc').ensure(collection, 'string');

        // List indexes
        const indexes = await collection.sortIndexes();
        
        // Check that all indexes are listed
        expect(indexes.length).toBe(3);
        expect(indexes.some(idx => idx.fieldName === 'age' && idx.direction === 'asc')).toBe(true);
        expect(indexes.some(idx => idx.fieldName === 'role' && idx.direction === 'asc')).toBe(true);
        expect(indexes.some(idx => idx.fieldName === 'name' && idx.direction === 'desc')).toBe(true);
        
        // Delete an index
        const deleteResult = await collection.sortIndex('age', 'asc').drop();
        expect(deleteResult).toBe(true);
        
        // Check that the index is deleted
        const indexesAfterDelete = await collection.sortIndexes();
        expect(indexesAfterDelete.length).toBe(2);
        expect(indexesAfterDelete.some(idx => idx.fieldName === 'age' && idx.direction === 'asc')).toBe(false);
    });
    
    test('should update sort index when record is updated', async () => {
        const users = [
            {
                _id: '123e4567-e89b-12d3-a456-426614174001',
                name: 'John Doe',
                email: 'john@example.com',
                age: 30,
                role: 'user'
            },
            {
                _id: '123e4567-e89b-12d3-a456-426614174002',
                name: 'Alice Smith',
                email: 'alice@example.com',
                age: 25,
                role: 'admin'
            }
        ];
        
        // Insert users
        for (const user of users) {
            await collection.insertOne(user);
        }
        
        // Create an index on age
        await collection.sortIndex('age', 'asc').ensure(collection, 'number');

        // Verify initial sort order
        let result = await collection.sortIndex('age', 'asc').getPage();
        expect(result.records[0].age).toBe(25); // Alice first
        expect(result.records[1].age).toBe(30); // John second
        
        // Update John's age to 20 (should move him before Alice)
        await collection.updateOne(users[0]._id, { age: 20 });
        
        // Verify sort order is updated
        result = await collection.sortIndex('age', 'asc').getPage();
        expect(result.records[0].age).toBe(20); // John first now
        expect(result.records[1].age).toBe(25); // Alice second now
    });
    
    test('should update sort index when record is deleted', async () => {
        const users = [
            {
                _id: '123e4567-e89b-12d3-a456-426614174001',
                name: 'John Doe',
                email: 'john@example.com',
                age: 30,
                role: 'user'
            },
            {
                _id: '123e4567-e89b-12d3-a456-426614174002',
                name: 'Alice Smith',
                email: 'alice@example.com',
                age: 25,
                role: 'admin'
            }
        ];
        
        // Insert users
        for (const user of users) {
            await collection.insertOne(user);
        }
        
        // Create an index on age
        await collection.sortIndex('age', 'asc').ensure(collection, 'number');

        // Verify initial sort order
        let result = await collection.sortIndex('age', 'asc').getPage();
        expect(result.records.length).toBe(2);
        expect(result.totalRecords).toBe(2);
        
        // Delete Alice
        await collection.deleteOne(users[1]._id);
        
        // Verify sort index is updated
        result = await collection.sortIndex('age', 'asc').getPage();
        expect(result.records.length).toBe(1);
        expect(result.totalRecords).toBe(1);
        expect(result.records[0].age).toBe(30); // Only John remains
    });
    
    test('should support pagination with sort indexes', async () => {
        const users = [
            {
                _id: '123e4567-e89b-12d3-a456-426614174001',
                name: 'John Doe',
                email: 'john@example.com',
                age: 30,
                role: 'user'
            },
            {
                _id: '123e4567-e89b-12d3-a456-426614174002',
                name: 'Alice Smith',
                email: 'alice@example.com',
                age: 25,
                role: 'admin'
            },
            {
                _id: '123e4567-e89b-12d3-a456-426614174003',
                name: 'Bob Johnson',
                email: 'bob@example.com',
                age: 35,
                role: 'user'
            }
        ];
        
        // Insert users
        for (const user of users) {
            await collection.insertOne(user);
        }
        
        // Create an index on age
        await collection.sortIndex('age', 'asc').ensure(collection, 'number');

        // Get first page
        let result = await collection.sortIndex('age', 'asc').getPage();
        expect(result.records.length).toBeGreaterThan(0);
        expect(result.totalRecords).toBe(3);
        expect(result.totalPages).toBeGreaterThan(0);
        
        // Collect all records across pages
        const allRecords = [...result.records];
        let currentPageId = result.nextPageId;
        
        while (currentPageId) {
            result = await collection.sortIndex('age', 'asc').getPage(currentPageId);
            allRecords.push(...result.records);
            currentPageId = result.nextPageId;
        }
        
        // Verify we got all records
        expect(allRecords.length).toBe(3);
        
        // Verify they're sorted correctly
        expect(allRecords[0].age).toBe(25); // Alice
        expect(allRecords[1].age).toBe(30); // John
        expect(allRecords[2].age).toBe(35); // Bob
    });
    
    test('should support descending order with sort indexes', async () => {
        const users = [
            {
                _id: '123e4567-e89b-12d3-a456-426614174001',
                name: 'John Doe',
                email: 'john@example.com',
                age: 30,
                role: 'user'
            },
            {
                _id: '123e4567-e89b-12d3-a456-426614174002',
                name: 'Alice Smith',
                email: 'alice@example.com',
                age: 25,
                role: 'admin'
            },
            {
                _id: '123e4567-e89b-12d3-a456-426614174003',
                name: 'Bob Johnson',
                email: 'bob@example.com',
                age: 35,
                role: 'user'
            }
        ];
        
        // Insert users
        for (const user of users) {
            await collection.insertOne(user);
        }
        
        // Create a descending index on age
        await collection.sortIndex('age', 'desc').ensure(collection, 'number');

        // Get sorted records in descending order
        const result = await collection.sortIndex('age', 'desc').getPage();

        // Verify records are sorted in descending order
        expect(result.records.length).toBe(users.length);
        expect(result.records[0].age).toBe(35); // Bob first
        expect(result.records[1].age).toBe(30); // John second
        expect(result.records[2].age).toBe(25); // Alice last
    });
    
    test('should drop the collection', async () => {
        const user: TestUser = {
            _id: '123e4567-e89b-12d3-a456-426614174000',
            name: 'John Doe',
            email: 'john@example.com',
            age: 30,
            role: 'user'
        };

        await collection.insertOne(user);

        // Create an index
        await collection.sortIndex('role', 'asc').ensure(collection, 'string');

        // Drop the collection
        await collection.drop();

        // Check that the record is gone
        const dropped = await collection.getOne(user._id);
        expect(dropped).toBeUndefined();

        // Check that indexes are gone
        const indexes = await collection.sortIndexes();
        expect(indexes.length).toBe(0);
    });

    test('should throw when inserting a record with a duplicate ID', async () => {
        const user: TestUser = {
            _id: '123e4567-e89b-12d3-a456-426614174000',
            name: 'John Doe',
            email: 'john@example.com',
            age: 30,
            role: 'user'
        };

        await collection.insertOne(user);

        await expect(collection.insertOne(user)).rejects.toThrow();
    });

    test('should set an internal record preserving metadata', async () => {
        const internalRecord: IInternalRecord = {
            _id: '123e4567-e89b-12d3-a456-426614174000',
            fields: { name: 'Sync User', age: 42 },
            metadata: { timestamp: 1000000, fields: { name: { timestamp: 999 } } }
        };

        await collection.setInternalRecord(internalRecord);

        const retrieved = await collection.getOne(internalRecord._id);
        expect(retrieved).toBeDefined();
        expect(retrieved!.name).toBe('Sync User');
        expect(retrieved!.age).toBe(42);
    });

    test('setInternalRecord should upsert (update existing record)', async () => {
        const user: TestUser = {
            _id: '123e4567-e89b-12d3-a456-426614174000',
            name: 'Original',
            email: 'orig@example.com',
            age: 20,
            role: 'user'
        };

        await collection.insertOne(user);

        const updated: IInternalRecord = {
            _id: user._id,
            fields: { name: 'Updated', email: 'updated@example.com', age: 21, role: 'admin' },
            metadata: { timestamp: 9999999 }
        };

        await collection.setInternalRecord(updated);

        const retrieved = await collection.getOne(user._id);
        expect(retrieved!.name).toBe('Updated');
        expect(retrieved!.age).toBe(21);
    });

    test('hasIndex should return true when index exists and false otherwise', async () => {
        expect(await collection.sortIndex('age', 'asc').exists()).toBe(false);

        await collection.sortIndex('age', 'asc').ensure(collection, 'number');

        expect(await collection.sortIndex('age', 'asc').exists()).toBe(true);
        expect(await collection.sortIndex('age', 'desc').exists()).toBe(false);
    });

    test('should find records by range', async () => {
        const users = [
            { _id: '123e4567-e89b-12d3-a456-426614174001', name: 'A', email: 'a@x.com', age: 10, role: 'user' },
            { _id: '123e4567-e89b-12d3-a456-426614174002', name: 'B', email: 'b@x.com', age: 20, role: 'user' },
            { _id: '123e4567-e89b-12d3-a456-426614174003', name: 'C', email: 'c@x.com', age: 30, role: 'user' },
            { _id: '123e4567-e89b-12d3-a456-426614174004', name: 'D', email: 'd@x.com', age: 40, role: 'user' },
        ];

        for (const user of users) {
            await collection.insertOne(user);
        }

        await collection.sortIndex('age', 'asc').ensure(collection, 'number');

        const results = await collection.sortIndex('age', 'asc').findByRange({ min: 15, max: 35, minInclusive: true, maxInclusive: true }) as TestUser[];

        expect(results.length).toBe(2);
        expect(results.every(record => record.age >= 15 && record.age <= 35)).toBe(true);
    });

    test('findByRange should return empty when index does not exist', async () => {
        const result = await collection.sortIndex('age', 'asc').findByRange({ min: 0, max: 100 });
        expect(result).toEqual([]);
    });

    test('deleteIndex should delete both asc and desc indexes', async () => {
        await collection.sortIndex('age', 'asc').ensure(collection, 'number');
        await collection.sortIndex('age', 'desc').ensure(collection, 'number');

        expect(await collection.sortIndex('age', 'asc').exists()).toBe(true);
        expect(await collection.sortIndex('age', 'desc').exists()).toBe(true);

        const resultAsc = await collection.sortIndex('age', 'asc').drop();
        const resultDesc = await collection.sortIndex('age', 'desc').drop();
        const result = resultAsc || resultDesc;
        expect(result).toBe(true);

        expect(await collection.sortIndex('age', 'asc').exists()).toBe(false);
        expect(await collection.sortIndex('age', 'desc').exists()).toBe(false);
    });

    test('deleteIndex should return false when neither index exists', async () => {
        const resultAsc = await collection.sortIndex('nonexistent', 'asc').drop();
        const resultDesc = await collection.sortIndex('nonexistent', 'desc').drop();
        expect(resultAsc).toBe(false);
        expect(resultDesc).toBe(false);
    });

    test('drop should return false for non-existent index', async () => {
        const result = await collection.sortIndex('nonexistent', 'asc').drop();
        expect(result).toBe(false);
    });

    test('getSorted should return empty when sort index does not exist', async () => {
        const result = await collection.sortIndex('age', 'asc').getPage();
        expect(result.records).toEqual([]);
        expect(result.totalRecords).toBe(0);
    });

    test('findByIndex should return empty when no index exists on either direction', async () => {
        const result = await collection.sortIndex('role', 'asc').findByValue('user');
        expect(result).toEqual([]);
    });


    test('getShardId should return consistent shard IDs for the same record', () => {
        const id = '123e4567-e89b-12d3-a456-426614174000';

        const shardId1 = collection.getShardId(id);
        const shardId2 = collection.getShardId(id);

        expect(shardId1).toBe(shardId2);
        expect(Number(shardId1)).toBeGreaterThanOrEqual(0);
        expect(Number(shardId1)).toBeLessThan(100);
    });

    test('getShardId should throw for an invalid record ID', () => {
        expect(() => collection.getShardId('not-a-valid-uuid')).toThrow();
    });

    test('iterateShards should only yield non-empty shards', async () => {
        const users = [
            { _id: '123e4567-e89b-12d3-a456-426614174001', name: 'A', email: 'a@x.com', age: 10, role: 'user' },
            { _id: '123e4567-e89b-12d3-a456-426614174002', name: 'B', email: 'b@x.com', age: 20, role: 'user' },
        ];

        for (const user of users) {
            await collection.insertOne(user);
        }

        const shards: IInternalRecord[][] = [];
        for await (const shard of collection.iterateShards()) {
            shards.push(Array.from(shard));
        }

        // All yielded shards must be non-empty
        expect(shards.every(shard => shard.length > 0)).toBe(true);

        // Total records across all shards matches
        const totalRecords = shards.reduce((sum, shard) => sum + shard.length, 0);
        expect(totalRecords).toBe(users.length);
    });

    test('replaceOne with upsert should create a new record', async () => {
        const id = '123e4567-e89b-12d3-a456-426614174099';
        const replacement: TestUser = {
            _id: id,
            name: 'New User',
            email: 'new@example.com',
            age: 22,
            role: 'guest'
        };

        const result = await collection.replaceOne(id, replacement, { upsert: true });
        expect(result).toBe(true);

        const retrieved = await collection.getOne(id);
        expect(retrieved).toEqual(replacement);
    });

    test('replaceOne should return false for non-existent record without upsert', async () => {
        const id = '123e4567-e89b-12d3-a456-000000000099';
        const replacement: TestUser = {
            _id: id,
            name: 'Ghost',
            email: 'ghost@example.com',
            age: 0,
            role: 'none'
        };

        const result = await collection.replaceOne(id, replacement);
        expect(result).toBe(false);
    });

    test('commit should flush dirty state and allow flush to succeed', async () => {
        const user: TestUser = {
            _id: '123e4567-e89b-12d3-a456-426614174000',
            name: 'Committed',
            email: 'commit@example.com',
            age: 30,
            role: 'user'
        };

        await collection.insertOne(user);

        // commit should not throw
        await collection.commit();

        // flush should succeed after commit
        expect(() => collection.flush()).not.toThrow();
    });

    test('flush should throw when collection is dirty', async () => {
        const user: TestUser = {
            _id: '123e4567-e89b-12d3-a456-426614174000',
            name: 'Dirty',
            email: 'dirty@example.com',
            age: 30,
            role: 'user'
        };

        await collection.insertOne(user);

        // flush without commit should throw because the collection is dirty
        expect(() => collection.flush()).toThrow();
    });

    test('merkleTree should return a usable IMerkleRef', async () => {
        const merkleRef = collection.merkleTree();
        expect(merkleRef).toBeDefined();

        // A fresh uncommitted collection has no persisted tree yet
        const tree = await merkleRef.get();
        expect(tree).toBeUndefined();
    });

    test('sortIndex load should populate the sort index cache', async () => {
        const users = [
            { _id: '123e4567-e89b-12d3-a456-426614174001', name: 'A', email: 'a@x.com', age: 10, role: 'user' },
            { _id: '123e4567-e89b-12d3-a456-426614174002', name: 'B', email: 'b@x.com', age: 20, role: 'user' },
        ];

        for (const user of users) {
            await collection.insertOne(user);
        }

        await collection.sortIndex('age', 'asc').ensure(collection, 'number');

        // load on a non-existent index should be a no-op (no throw)
        await collection.sortIndex('name', 'asc').load();

        // load on an existing index should succeed
        await collection.sortIndex('age', 'asc').load();
    });

    test('shard should return the same cached instance for the same shardId', () => {
        const shardA = collection.shard('0');
        const shardB = collection.shard('0');

        expect(shardA).toBe(shardB);
    });
});