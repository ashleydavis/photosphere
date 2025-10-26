import { expect, jest, test, describe, beforeEach, afterEach } from '@jest/globals';
import { MockStorage } from 'storage';
import { BsonCollection } from 'bdb';
import type { IRecord } from 'bdb';
import { RandomUuidGenerator } from 'utils';
import crypto from 'crypto';

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
        collection = new BsonCollection<TestUser>('users', {
            storage,
            directory: 'users',
            uuidGenerator: new RandomUuidGenerator(),
            numShards: 10
        });
    });
        
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
});