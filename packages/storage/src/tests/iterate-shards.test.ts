import { expect, jest, test, describe, beforeEach, afterEach } from '@jest/globals';
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

describe('BsonCollection.iterateShards', () => {
    let storage: MockStorage;
    let collection: BsonCollection<TestUser>;
    
    beforeEach(() => {
        storage = new MockStorage();
        collection = new BsonCollection<TestUser>({
            storage,
            directory: 'users',
            numShards: 10, 
            maxCachedShards: 5
        });
    });
    
    afterEach(async () => {
        await collection.shutdown();
    });
    
    // Helper function to force a save by manually calling saveDirtyShards
    async function forceSave(): Promise<void> {
        // Use any casting to access private method
        await (collection as any).saveDirtyShards();
    }
    
    test('should iterate through empty collection shards', async () => {
        const shards: Array<Iterable<TestUser>> = [];
        
        for await (const shard of collection.iterateShards()) {
            shards.push(shard);
        }
        
        expect(shards.length).toBe(0);
    });
    
    test('should iterate through collection shards', async () => {
        // Create test users - choose IDs that will hash to different shards
        const users = [
            {
                _id: '123e4567-e89b-12d3-a456-426614174001',
                name: 'User 1',
                email: 'user1@example.com',
                age: 30,
                role: 'user'
            },
            {
                _id: '223e4567-e89b-12d3-a456-426614174002',
                name: 'User 2',
                email: 'user2@example.com',
                age: 35,
                role: 'admin'
            },
            {
                _id: '323e4567-e89b-12d3-a456-426614174003',
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
        
        // Collect all shards from the iterator
        const shards: Array<Iterable<TestUser>> = [];
        for await (const shard of collection.iterateShards()) {
            shards.push(shard);
        }
        
        // Count total number of records across all shards
        let totalRecords = 0;
        for (const shard of shards) {
            const shardRecords = Array.from(shard);
            totalRecords += shardRecords.length;
        }
        
        // Verify we got all records
        expect(totalRecords).toBe(users.length);
        
        // Each shard should contain users
        expect(shards.length).toBeGreaterThan(0);
    });
    
    test('should handle cached and uncached shards', async () => {
        // Create multiple users
        const users = Array(20).fill(0).map((_, i) => ({
            _id: crypto.randomUUID(),
            name: `User ${i}`,
            email: `user${i}@example.com`,
            age: 20 + i,
            role: i % 2 === 0 ? 'user' : 'admin'
        }));
       
        // Insert all users
        for (const user of users) {
            await collection.insertOne(user);
        }
        
        // Force save all records
        await forceSave();
        
        // Access some records to cache their shards
        for (let i = 0; i < 3; i++) {
            await collection.getOne(users[i]._id);
        }
        
        // Now iterate through shards and verify
        const retrievedRecords: TestUser[] = [];
        const usersRetreived = new Set<string>();

        for await (const shard of collection.iterateShards()) {
            for (const record of shard) {
                retrievedRecords.push(record);
                usersRetreived.add(record._id);
            }
        }
       
        expect(retrievedRecords.length).toBe(users.length);
        
        // Check that each user was retrieved
        for (const user of users) {
            expect(usersRetreived.has(user._id)).toBe(true);
        }
    });
    
    test('should process shards independently', async () => {
        // Create users in different roles to test shard-based processing
        const users = [
            {
                _id: '123e4567-e89b-12d3-a456-426614174001',
                name: 'User 1',
                email: 'user1@example.com',
                age: 30,
                role: 'user'
            },
            {
                _id: '223e4567-e89b-12d3-a456-426614174002',
                name: 'User 2',
                email: 'user2@example.com',
                age: 35,
                role: 'admin'
            },
            {
                _id: '323e4567-e89b-12d3-a456-426614174003',
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
        
        // Process shards to compute shard-level statistics
        const shardStats = [];
        for await (const shard of collection.iterateShards()) {
            const shardRecords = Array.from(shard);
            
            // Calculate average age per shard
            const totalAge = shardRecords.reduce((sum, user) => sum + user.age, 0);
            const avgAge = shardRecords.length > 0 ? totalAge / shardRecords.length : 0;
            
            // Count roles per shard
            const roles: Record<string, number> = {};
            for (const record of shardRecords) {
                roles[record.role] = (roles[record.role] || 0) + 1;
            }
            
            shardStats.push({
                recordCount: shardRecords.length,
                avgAge,
                roles
            });
        }
        
        // Verify we have statistics for non-empty shards
        expect(shardStats.filter(stats => stats.recordCount > 0).length).toBeGreaterThan(0);
        
        // Total records across all shards should match our input
        const totalRecords = shardStats.reduce((sum, stat) => sum + stat.recordCount, 0);
        expect(totalRecords).toBe(users.length);
    });
    
    test('should handle shards with mix of cached and uncached records', async () => {
        // Generate a set of users with IDs that will hash to the same shard
        const shardId = 3; // Pick an arbitrary shard ID
        
        // Mock the generateShardId method to always return our chosen shardId
        const originalMethod = (collection as any).generateShardId;
        (collection as any).generateShardId = jest.fn().mockReturnValue(shardId);
        
        const users = [
            {
                _id: '123e4567-e89b-12d3-a456-426614174001',
                name: 'User 1',
                email: 'user1@example.com',
                age: 30,
                role: 'user'
            },
            {
                _id: '223e4567-e89b-12d3-a456-426614174002', 
                name: 'User 2',
                email: 'user2@example.com',
                age: 35,
                role: 'admin'
            },
            {
                _id: '323e4567-e89b-12d3-a456-426614174003',
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
        
        // Access some records to cache their shards
        await collection.getOne(users[0]._id);
        
        // Clear the shard cache (simulate time passing and cache being evicted)
        (collection as any).shardCache.clear();
        
        // Access one record to cache just part of the shard
        await collection.getOne(users[1]._id);
        
        // Now iterate through shards 
        const retrievedRecords: TestUser[] = [];
        for await (const shard of collection.iterateShards()) {
            retrievedRecords.push(...Array.from(shard));
        }
        
        // Check that all users were retrieved
        expect(retrievedRecords.length).toBe(users.length);
        
        // Restore the original method
        (collection as any).generateShardId = originalMethod;
    });
});