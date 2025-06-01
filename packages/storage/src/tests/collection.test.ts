import { expect, test, describe, beforeEach, afterEach } from '@jest/globals';
import { MockStorage } from './mock-storage';
import { BsonCollection, IRecord } from '../lib/bson-database/collection';

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
        collection = new BsonCollection<TestUser>('users', {
            storage,
            directory: 'users',
            numShards: 10, 
            maxCachedShards: 5
        });
    });
    
    afterEach(async () => {
        // Ensure collection is properly shut down to avoid async issues
        await collection.shutdown();
    });
    
    // Helper function to force a save by manually calling saveDirtyShards
    async function forceSave(): Promise<void> {
        // Use any casting to access private method
        await (collection as any).saveDirtyShards();
    }
    
    test('should insert and retrieve a record', async () => {
        const user: TestUser = {
            _id: '123e4567-e89b-12d3-a456-426614174000',
            name: 'John Doe',
            email: 'john@example.com',
            age: 30,
            role: 'user'
        };
        
        await collection.insertOne(user);
        await forceSave();
        
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
        await forceSave();
        
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
        await forceSave();
        
        const updates = {
            age: 31,
            role: 'admin'
        };
        
        const updateResult = await collection.updateOne(user._id, updates);
        expect(updateResult).toBe(true);
        await forceSave();
        
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
        await forceSave();
        
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
        await forceSave();
        
        const replacement: TestUser = {
            _id: user._id,
            name: 'John Smith',
            email: 'smith@example.com',
            age: 35,
            role: 'admin'
        };
        
        const replaceResult = await collection.replaceOne(user._id, replacement);
        expect(replaceResult).toBe(true);
        await forceSave();
        
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
        await forceSave();
        
        const deleteResult = await collection.deleteOne(user._id);
        expect(deleteResult).toBe(true);
        await forceSave();
        
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
        
        // Force save all records
        await forceSave();
        
        // Collect all records from the iterator
        const retrievedUsers: TestUser[] = [];
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
        
        // Force save all records
        await forceSave();
        
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
        
        // Force save all records
        await forceSave();
        
        // Create an index on the age field
        await collection.ensureSortIndex('age', 'asc', 'number');
        
        // Get sorted records
        const result = await collection.getSorted('age', 'asc');
        
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
        
        // Force save all records
        await forceSave();
        
        // Create an index on the role field
        await collection.ensureSortIndex('role', 'asc', 'string');
        
        // Find users with role 'user'
        const userRoleResults = await collection.findByIndex('role', 'user');
        expect(userRoleResults.length).toBe(2);
        expect(userRoleResults.every(u => u.role === 'user')).toBe(true);
        
        // Find users with role 'admin'
        const adminRoleResults = await collection.findByIndex('role', 'admin');
        expect(adminRoleResults.length).toBe(1);
        expect(adminRoleResults[0].role).toBe('admin');
        
        // Create an index on the age field
        await collection.ensureSortIndex('age', 'asc', 'number');
        
        // Find users with age 30
        const age30Results = await collection.findByIndex('age', 30);
        expect(age30Results.length).toBe(2);
        expect(age30Results.every(u => u.age === 30)).toBe(true);
    });
    
    test('should list and delete sort indexes', async () => {
        // Create some indexes
        await collection.ensureSortIndex('age', 'asc', 'number');
        await collection.ensureSortIndex('role', 'asc', 'string');
        await collection.ensureSortIndex('name', 'desc', 'string');
        
        // List indexes
        const indexes = await collection.listSortIndexes();
        
        // Check that all indexes are listed
        expect(indexes.length).toBe(3);
        expect(indexes.some(idx => idx.fieldName === 'age' && idx.direction === 'asc')).toBe(true);
        expect(indexes.some(idx => idx.fieldName === 'role' && idx.direction === 'asc')).toBe(true);
        expect(indexes.some(idx => idx.fieldName === 'name' && idx.direction === 'desc')).toBe(true);
        
        // Delete an index
        const deleteResult = await collection.deleteSortIndex('age', 'asc');
        expect(deleteResult).toBe(true);
        
        // Check that the index is deleted
        const indexesAfterDelete = await collection.listSortIndexes();
        expect(indexesAfterDelete.length).toBe(2);
        expect(indexesAfterDelete.some(idx => idx.fieldName === 'age' && idx.direction === 'asc')).toBe(false);
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
        await forceSave();
        
        // Create an index
        await collection.ensureSortIndex('role', 'asc', 'string');
        
        // Drop the collection
        await collection.drop();
        
        // Check that the record is gone
        const dropped = await collection.getOne(user._id);
        expect(dropped).toBeUndefined();
        
        // Check that indexes are gone
        const indexes = await collection.listSortIndexes();
        expect(indexes.length).toBe(0);
    });
});