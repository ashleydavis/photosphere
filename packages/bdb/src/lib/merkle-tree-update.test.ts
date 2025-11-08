import { expect, test, describe, beforeEach } from '@jest/globals';
import { MockStorage } from 'storage';
import { BsonDatabase, IBsonCollection } from '../index';
import { TestUuidGenerator } from 'node-utils';
import { MockTimestampProvider } from 'utils';
import { loadShardMerkleTree, loadCollectionMerkleTree, loadDatabaseMerkleTree, listShards } from './merkle-tree';
import stringify from 'json-stable-stringify';
import * as crypto from 'crypto';

describe('Merkle tree updates', () => {
    let storage: MockStorage;
    let database: BsonDatabase;
    let collection: IBsonCollection<any>;
    let uuidGenerator: TestUuidGenerator;

    beforeEach(async () => {
        storage = new MockStorage();
        uuidGenerator = new TestUuidGenerator();
        const timestampProvider = new MockTimestampProvider();

        database = new BsonDatabase({
            storage,
            uuidGenerator,
            timestampProvider,
        });

        collection = database.collection('test');
    });

    test('insertOne should update shard, collection, and database merkle trees', async () => {
        const recordId = uuidGenerator.generate();
        await collection.insertOne({
            _id: recordId,
            name: 'John',
            age: 30,
        });

        // Determine which shard the record went to
        const shardIds = await listShards(storage, 'test');
        expect(shardIds.length).toBeGreaterThan(0);
        const shardId = shardIds[0];
        
        // Check shard merkle tree exists
        const shardTree = await loadShardMerkleTree(storage, 'test', shardId);
        expect(shardTree).toBeDefined();
        expect(shardTree!.merkle).toBeDefined();
        expect(shardTree!.sort).toBeDefined();

        // Check collection merkle tree exists
        const collectionTree = await loadCollectionMerkleTree(storage, 'test');
        expect(collectionTree).toBeDefined();
        expect(collectionTree!.merkle).toBeDefined();

        // Check database merkle tree exists
        const databaseTree = await loadDatabaseMerkleTree(storage);
        expect(databaseTree).toBeDefined();
    });

    test('updateOne should update shard, collection, and database merkle trees', async () => {
        const recordId = uuidGenerator.generate();
        
        // Insert initial record
        await collection.insertOne({
            _id: recordId,
            name: 'John',
            age: 30,
        });

        // Determine which shard the record went to
        const shardIds = await listShards(storage, 'test');
        expect(shardIds.length).toBeGreaterThan(0);
        const shardId = shardIds[0];
        
        // Get initial shard tree hash
        const initialShardTree = await loadShardMerkleTree(storage, 'test', shardId);
        expect(initialShardTree).toBeDefined();
        expect(initialShardTree!.merkle).toBeDefined();
        const initialShardHash = initialShardTree!.merkle!.hash;

        // Update the record
        await collection.updateOne(recordId, {
            name: 'Jane',
            age: 31,
        });

        // Get updated shard tree hash
        const updatedShardTree = await loadShardMerkleTree(storage, 'test', shardId);
        expect(updatedShardTree).toBeDefined();
        expect(updatedShardTree!.merkle).toBeDefined();
        const updatedShardHash = updatedShardTree!.merkle!.hash;

        // The shard tree hash should have changed
        expect(Buffer.compare(initialShardHash, updatedShardHash)).not.toBe(0);

        // Collection tree should also be updated
        const collectionTree = await loadCollectionMerkleTree(storage, 'test');
        expect(collectionTree).toBeDefined();
        expect(collectionTree!.merkle).toBeDefined();
    });

    test('deleteOne should update shard, collection, and database merkle trees', async () => {
        const recordId = uuidGenerator.generate();
        
        // Insert initial record
        await collection.insertOne({
            _id: recordId,
            name: 'John',
            age: 30,
        });

        // Determine which shard the record went to
        const shardIds = await listShards(storage, 'test');
        expect(shardIds.length).toBeGreaterThan(0);
        const shardId = shardIds[0];
        
        // Get initial shard tree
        const initialShardTree = await loadShardMerkleTree(storage, 'test', shardId);
        expect(initialShardTree).toBeDefined();
        expect(initialShardTree?.sort).toBeDefined();
        const initialNodeCount = initialShardTree?.sort?.nodeCount;

        // Delete the record
        const deleted = await collection.deleteOne(recordId);
        expect(deleted).toBe(true);

        // Get updated shard tree
        const updatedShardTree = await loadShardMerkleTree(storage, 'test', shardId);
        
        // After deleting the last record, the shard tree file is deleted (empty shards don't have tree files)
        expect(updatedShardTree).toBeUndefined();

        // Collection tree is also deleted when the collection becomes empty (no shards with records)
        const collectionTree = await loadCollectionMerkleTree(storage, 'test');
        expect(collectionTree).toBeUndefined();
    });
});

