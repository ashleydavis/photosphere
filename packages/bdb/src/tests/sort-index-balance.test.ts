import { SortIndex } from 'bdb';
import { IRecord } from 'bdb';
import { expect, test, describe, beforeEach } from '@jest/globals';
import { MockStorage } from 'storage';
import { MockCollection } from 'bdb';
import { RandomUuidGenerator } from 'utils';
import { toInternal } from '../lib/collection';

// Test interface
interface TestRecord extends IRecord {
    _id: string;
    value: number;
    name: string;
}

describe('SortIndex Tree Balance', () => {
    let storage: MockStorage;
    let collection: MockCollection<TestRecord>;

    beforeEach(() => {
        storage = new MockStorage();
    });

    // Helper function to create a record
    function createRecord(id: number, value: number): TestRecord {
        return {
            _id: `record-${id.toString().padStart(8, '0')}`,
            value,
            name: `Record ${id}`
        };
    }

    // Helper function to check if tree is balanced
    async function verifyTreeBalance(index: SortIndex): Promise<{
        isBalanced: boolean;
        treeHeight: number;
        leafDepths: number[];
        stats: any;
    }> {
        const stats = await index.analyzeTreeStructure();
        
        // A B-tree is balanced if all leaf nodes are at the same level
        // For this test, we'll check that no leaf is more than 1 level away from others
        const leafDepths: number[] = [];
        
        // Calculate depth of each leaf node by traversing from root
        const nodeDepths = new Map<string, number>();
        
        // Start with root at depth 0
        const visualization = await index.visualizeTree();

        const lines = visualization.split('\n');
        
        // Extract node structure from visualization
        for (const line of lines) {
            const indent = line.search(/\S/);
            if (indent >= 0 && line.includes('[') && line.includes(']')) {
                const depth = Math.floor(indent / 2);
                const nodeMatch = line.match(/\[([^\]]+)\]/);
                if (nodeMatch) {
                    const nodeId = nodeMatch[1];
                    nodeDepths.set(nodeId, depth);
                    
                    if (line.includes('LEAF')) {
                        leafDepths.push(depth);
                    }
                }
            }
        }
        
        // Calculate tree height and balance
        const minDepth = Math.min(...leafDepths);
        const maxDepth = Math.max(...leafDepths);
        const treeHeight = maxDepth;
        
        // Tree is considered balanced if depth difference is at most 1
        const isBalanced = (maxDepth - minDepth) <= 1;
        
        return {
            isBalanced,
            treeHeight,
            leafDepths,
            stats
        };
    }

    test('should maintain balanced tree with sequential insertions', async () => {
        const records: TestRecord[] = [];
        
        // Create 50 records with sequential values
        for (let i = 1; i <= 50; i++) {
            records.push(createRecord(i, i));
        }
        
        collection = new MockCollection<TestRecord>(records);
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'balance_test',
            fieldName: 'value',
            direction: 'asc',
            pageSize: 10,
            keySize: 5,
            uuidGenerator: new RandomUuidGenerator()
        });
        
        // Build the index
        await sortIndex.build(collection);
        
        // Verify tree balance
        const balance = await verifyTreeBalance(sortIndex);
        
        expect(balance.isBalanced).toBe(true);
        expect(balance.stats.leafNodes).toBeGreaterThan(1);
        expect(balance.stats.totalNodes).toBeGreaterThanOrEqual(balance.stats.leafNodes);
        
        // All leaf nodes should be at similar depths
        const minDepth = Math.min(...balance.leafDepths);
        const maxDepth = Math.max(...balance.leafDepths);
        expect(maxDepth - minDepth).toBeLessThanOrEqual(1);
        
    });

    test('should maintain balanced tree with random insertions', async () => {
        const records: TestRecord[] = [];
        const values = Array.from({ length: 100 }, (_, i) => i + 1);
        
        // Shuffle the values to create random insertion order
        for (let i = values.length - 1; i > 0; i--) {
            const j = Math.floor(Math.random() * (i + 1));
            [values[i], values[j]] = [values[j], values[i]];
        }
        
        // Create records with shuffled values
        for (let i = 0; i < values.length; i++) {
            records.push(createRecord(i + 1, values[i]));
        }
        
        collection = new MockCollection<TestRecord>(records);
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'random_test',
            fieldName: 'value',
            direction: 'asc',
            pageSize: 8,
            keySize: 4,
            uuidGenerator: new RandomUuidGenerator()
        });
        
        // Build the index
        await sortIndex.build(collection);
        
        // Verify tree balance
        const balance = await verifyTreeBalance(sortIndex);
        
        expect(balance.isBalanced).toBe(true);
        expect(balance.stats.leafNodes).toBeGreaterThan(1);
        
        // Check that tree height is reasonable for 100 records
        // For a B-tree with branching factor ~4, height should be around log_4(100) ≈ 3-4
        expect(balance.treeHeight).toBeLessThanOrEqual(5);
        
    });

    test('should maintain balance during record additions', async () => {
        // Start with empty collection
        collection = new MockCollection<TestRecord>([]);
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'dynamic_test',
            fieldName: 'value',
            direction: 'asc',
            pageSize: 5,
            keySize: 3,
            uuidGenerator: new RandomUuidGenerator()
        });
        
        // Build empty index
        await sortIndex.build(collection);
        
        // Add records one by one and check balance after each batch
        for (let batch = 1; batch <= 5; batch++) {
            // Add 10 records in each batch
            for (let i = 1; i <= 10; i++) {
                const recordNum = (batch - 1) * 10 + i;
                const record = createRecord(recordNum, recordNum);
                await sortIndex.addRecord(toInternal<TestRecord>(record));
            }
            
            // Verify balance after each batch
            const balance = await verifyTreeBalance(sortIndex);
            expect(balance.isBalanced).toBe(true);
            
            // Tree should not become too tall
            expect(balance.treeHeight).toBeLessThanOrEqual(4);
        }
        
    });

    test('should maintain balance with duplicate values', async () => {
        const records: TestRecord[] = [];
        
        // Create records with many duplicate values
        for (let i = 1; i <= 75; i++) {
            const value = Math.floor((i - 1) / 5) + 1; // Groups of 5 with same value
            records.push(createRecord(i, value));
        }
        
        collection = new MockCollection<TestRecord>(records);
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'duplicate_test',
            fieldName: 'value',
            direction: 'asc',
            pageSize: 6,
            keySize: 4,
            uuidGenerator: new RandomUuidGenerator()
        });
        
        // Build the index
        await sortIndex.build(collection);
        
        // Verify tree balance
        const balance = await verifyTreeBalance(sortIndex);
        
        expect(balance.isBalanced).toBe(true);
        expect(balance.stats.leafNodes).toBeGreaterThan(1);
        
        // Verify that records with same value can be found
        const duplicateRecords = await sortIndex.findByValue(5);
        expect(duplicateRecords.length).toBe(5);
        
    });

    test('should maintain balance after record deletions', async () => {
        const records: TestRecord[] = [];
        
        // Create 60 records
        for (let i = 1; i <= 60; i++) {
            records.push(createRecord(i, i));
        }
        
        collection = new MockCollection<TestRecord>(records);
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'deletion_test',
            fieldName: 'value',
            direction: 'asc',
            pageSize: 8,
            keySize: 4,
            uuidGenerator: new RandomUuidGenerator()
        });
        
        // Build the index
        await sortIndex.build(collection);
        
        // Delete every 3rd record
        for (let i = 3; i <= 60; i += 3) {
            await sortIndex.deleteRecord(`record-${i.toString().padStart(8, '0')}`, toInternal<TestRecord>(records[i - 1]));
        }
        
        // Verify tree balance after deletions
        const balance = await verifyTreeBalance(sortIndex);
        
        expect(balance.isBalanced).toBe(true);
        
        // Verify remaining records are still accessible
        const remaining = await sortIndex.findByValue(1);
        expect(remaining.length).toBe(1);
        
        const deleted = await sortIndex.findByValue(3);
        expect(deleted.length).toBe(0);
        
    });

    test('should maintain balance with mixed operations', async () => {
        const records: TestRecord[] = [];
        
        // Start with 30 records
        for (let i = 1; i <= 30; i++) {
            records.push(createRecord(i, i * 2)); // Even values
        }
        
        collection = new MockCollection<TestRecord>(records);
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'mixed_test',
            fieldName: 'value',
            direction: 'asc',
            pageSize: 6,
            keySize: 3,
            uuidGenerator: new RandomUuidGenerator()
        });
        
        // Build the index
        await sortIndex.build(collection);
        
        // Perform mixed operations
        for (let i = 1; i <= 15; i++) {
            // Add odd values
            const newRecord = createRecord(100 + i, i * 2 - 1);
            await sortIndex.addRecord(toInternal<TestRecord>(newRecord));
            
            // Update some existing records
            if (i <= 10) {
                const updatedRecord = createRecord(i, i * 2 + 100);
                const oldRecord = records[i - 1];
                await sortIndex.updateRecord(toInternal<TestRecord>(updatedRecord), toInternal<TestRecord>(oldRecord));
            }
            
            // Delete some records
            if (i <= 5) {
                await sortIndex.deleteRecord(`record-${(i + 15).toString().padStart(8, '0')}`, toInternal<TestRecord>(records[i - 1]));
            }
        }
        
        // Verify tree balance after mixed operations
        const balance = await verifyTreeBalance(sortIndex);
        
        expect(balance.isBalanced).toBe(true);
        expect(balance.stats.totalNodes).toBeGreaterThan(0);
        
        // Tree should still be reasonably shallow
        expect(balance.treeHeight).toBeLessThanOrEqual(4);
        
    });

    test('should handle large datasets while maintaining balance', async () => {
        const records: TestRecord[] = [];
        
        // Create 500 records
        for (let i = 1; i <= 500; i++) {
            records.push(createRecord(i, i));
        }
        
        collection = new MockCollection<TestRecord>(records);
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'large_test',
            fieldName: 'value',
            direction: 'asc',
            pageSize: 20,
            keySize: 10,
            uuidGenerator: new RandomUuidGenerator()
        });
        
        // Build the index
        await sortIndex.build(collection);
        
        // Verify tree balance
        const balance = await verifyTreeBalance(sortIndex);
        
        expect(balance.isBalanced).toBe(true);
        expect(balance.stats.leafNodes).toBeGreaterThan(10);
        
        // For 500 records with branching factor ~10, height should be around log_10(500) ≈ 3
        expect(balance.treeHeight).toBeLessThanOrEqual(4);
        
        // Verify tree structure is reasonable
        expect(balance.stats.leafStats.avgRecordsPerLeaf).toBeGreaterThan(10);
        expect(balance.stats.leafStats.avgRecordsPerLeaf).toBeLessThanOrEqual(25);
        
        if (balance.stats.internalNodes > 0) {
            expect(balance.stats.internalStats.avgKeysPerInternal).toBeGreaterThan(2);
            expect(balance.stats.internalStats.avgKeysPerInternal).toBeLessThanOrEqual(12);
        }
        
    });
});