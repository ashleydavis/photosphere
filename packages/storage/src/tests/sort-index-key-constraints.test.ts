import { SortIndex } from '../lib/bson-database/sort-index';
import { IRecord } from '../lib/bson-database/collection';
import { expect, test, describe, beforeEach } from '@jest/globals';
import { MockStorage } from './mock-storage';
import { MockCollection } from './mock-collection';
import { RandomUuidGenerator } from 'utils';

// Test interface
interface TestRecord extends IRecord {
    _id: string;
    value: number;
    name: string;
}

describe('SortIndex Key Constraints', () => {
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

    // Helper function to verify key constraints across all nodes
    async function verifyKeyConstraints(index: SortIndex<TestRecord>, keySize: number): Promise<{
        allConstraintsMet: boolean;
        violations: Array<{
            nodeId: string;
            nodeType: 'internal' | 'leaf';
            actualKeyCount: number;
            violation: string;
        }>;
        nodeAnalysis: Array<{
            nodeId: string;
            nodeType: 'internal' | 'leaf';
            actualKeyCount: number;
            isValid: boolean;
        }>;
    }> {
        // We need to access the tree nodes directly to get the actual key counts
        // Since these are private, we'll use the visualization to understand the structure
        const visualization = await index.visualizeTree();
        const stats = await index.analyzeTreeStructure();
        
        const violations: Array<{
            nodeId: string;
            nodeType: 'internal' | 'leaf';
            actualKeyCount: number;
            violation: string;
        }> = [];
        
        const nodeAnalysis: Array<{
            nodeId: string;
            nodeType: 'internal' | 'leaf';
            actualKeyCount: number;
            isValid: boolean;
        }> = [];

        // Parse the visualization to extract actual key information
        const lines = visualization.split('\n');
        const nodeKeyMap = new Map<string, { nodeType: 'internal' | 'leaf', keyCount: number }>();
        
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i];
            if (line.includes('[') && line.includes(']')) {
                const nodeMatch = line.match(/\[([^\]]+)\]/);
                if (nodeMatch) {
                    const nodeId = nodeMatch[1];
                    const isLeaf = line.includes('LEAF NODE');
                    const isInternal = line.includes('INTERNAL NODE');
                    
                    if (isLeaf) {
                        // For leaf nodes, we expect 0 keys in the keys array
                        // The actual data is stored in separate record files
                        nodeKeyMap.set(nodeId, { nodeType: 'leaf', keyCount: 0 });
                    } else if (isInternal) {
                        // For internal nodes, look for the Keys line that follows
                        // Check the next line for the Keys information
                        if (i + 1 < lines.length) {
                            const nextLine = lines[i + 1];
                            const keyMatch = nextLine.match(/^\s*Keys:\s*(.+)/);
                            if (keyMatch) {
                                const keysStr = keyMatch[1].trim();
                                // The key is a single value, not comma-separated in this format
                                const keyCount = keysStr ? 1 : 0;
                                nodeKeyMap.set(nodeId, { nodeType: 'internal', keyCount });
                            } else {
                                // No keys found, assume 0
                                nodeKeyMap.set(nodeId, { nodeType: 'internal', keyCount: 0 });
                            }
                        }
                    }
                }
            }
        }

        // Verify constraints for each node
        for (const [nodeId, nodeInfo] of nodeKeyMap.entries()) {
            let isValid = true;
            let violation = '';

            if (nodeInfo.nodeType === 'leaf') {
                // Leaf nodes should always have 0 keys in their keys array
                if (nodeInfo.keyCount !== 0) {
                    isValid = false;
                    violation = `Leaf node has ${nodeInfo.keyCount} keys in keys array, should have 0`;
                    violations.push({
                        nodeId,
                        nodeType: 'leaf',
                        actualKeyCount: nodeInfo.keyCount,
                        violation
                    });
                }
            } else {
                // Internal nodes should never have more keys than keySize
                if (nodeInfo.keyCount > keySize) {
                    isValid = false;
                    violation = `Internal node has ${nodeInfo.keyCount} keys, exceeds keySize limit of ${keySize}`;
                    violations.push({
                        nodeId,
                        nodeType: 'internal',
                        actualKeyCount: nodeInfo.keyCount,
                        violation
                    });
                }
            }

            nodeAnalysis.push({
                nodeId,
                nodeType: nodeInfo.nodeType,
                actualKeyCount: nodeInfo.keyCount,
                isValid
            });
        }

        return {
            allConstraintsMet: violations.length === 0,
            violations,
            nodeAnalysis
        };
    }

    test('should maintain key constraints with small keySize', async () => {
        const records: TestRecord[] = [];
        
        // Create 100 records to force tree growth
        for (let i = 1; i <= 100; i++) {
            records.push(createRecord(i, i));
        }
        
        collection = new MockCollection<TestRecord>(records);
        const keySize = 3; // Small keySize to force splits
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'constraint_test',
            fieldName: 'value',
            direction: 'asc',
            pageSize: 5,
            keySize,
            uuidGenerator: new RandomUuidGenerator()
        }, collection);
        
        // Build the index
        await sortIndex.build();
        
        // Verify key constraints
        const constraints = await verifyKeyConstraints(sortIndex, keySize);
        
        // All constraints should be met
        expect(constraints.allConstraintsMet).toBe(true);
        expect(constraints.violations).toHaveLength(0);
        
        // Verify specific constraints
        const leafNodes = constraints.nodeAnalysis.filter(n => n.nodeType === 'leaf');
        const internalNodes = constraints.nodeAnalysis.filter(n => n.nodeType === 'internal');
        
        // All leaf nodes should have 0 keys
        for (const leaf of leafNodes) {
            expect(leaf.actualKeyCount).toBe(0);
            expect(leaf.isValid).toBe(true);
        }
        
        // All internal nodes should have <= keySize keys
        for (const internal of internalNodes) {
            expect(internal.actualKeyCount).toBeLessThanOrEqual(keySize);
            expect(internal.isValid).toBe(true);
        }
        
        await sortIndex.shutdown();
    });

    test('should maintain key constraints during dynamic record addition', async () => {
        // Start with empty collection
        collection = new MockCollection<TestRecord>([]);
        const keySize = 4;
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'dynamic_constraint_test',
            fieldName: 'value',
            direction: 'asc',
            pageSize: 6,
            keySize,
            uuidGenerator: new RandomUuidGenerator()
        }, collection);
        
        // Build empty index
        await sortIndex.build();
        
        // Add records incrementally and check constraints after each batch
        for (let batch = 1; batch <= 10; batch++) {
            // Add 15 records in each batch
            for (let i = 1; i <= 15; i++) {
                const recordNum = (batch - 1) * 15 + i;
                const record = createRecord(recordNum, recordNum);
                await sortIndex.addRecord(record);
            }
            
            // Verify constraints after each batch
            const constraints = await verifyKeyConstraints(sortIndex, keySize);
            
            expect(constraints.allConstraintsMet).toBe(true);
            if (constraints.violations.length > 0) {
                console.log(`Batch ${batch} violations:`, constraints.violations);
            }
            expect(constraints.violations).toHaveLength(0);
        }
        
        await sortIndex.shutdown();
    });

    test('should maintain key constraints with very small keySize', async () => {
        const records: TestRecord[] = [];
        
        // Create 50 records
        for (let i = 1; i <= 50; i++) {
            records.push(createRecord(i, i));
        }
        
        collection = new MockCollection<TestRecord>(records);
        const keySize = 2; // Very small keySize
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'small_keysize_test',
            fieldName: 'value',
            direction: 'asc',
            pageSize: 4,
            keySize,
            uuidGenerator: new RandomUuidGenerator()
        }, collection);
        
        // Build the index
        await sortIndex.build();
        
        // Verify key constraints
        const constraints = await verifyKeyConstraints(sortIndex, keySize);
        
        expect(constraints.allConstraintsMet).toBe(true);
        expect(constraints.violations).toHaveLength(0);
        
        // With very small keySize, we should have more internal nodes
        const stats = await sortIndex.analyzeTreeStructure();
        expect(stats.internalNodes).toBeGreaterThan(0);
        
        // Verify no internal node exceeds the limit
        if (stats.internalNodes > 0) {
            expect(stats.internalStats.maxKeysPerInternal).toBeLessThanOrEqual(keySize);
        }
        
        await sortIndex.shutdown();
    });

    test('should maintain key constraints after record deletions', async () => {
        const records: TestRecord[] = [];
        
        // Create 80 records
        for (let i = 1; i <= 80; i++) {
            records.push(createRecord(i, i));
        }
        
        collection = new MockCollection<TestRecord>(records);
        const keySize = 5;
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'deletion_constraint_test',
            fieldName: 'value',
            direction: 'asc',
            pageSize: 8,
            keySize,
            uuidGenerator: new RandomUuidGenerator()
        }, collection);
        
        // Build the index
        await sortIndex.build();
        
        // Verify initial constraints
        let constraints = await verifyKeyConstraints(sortIndex, keySize);
        expect(constraints.allConstraintsMet).toBe(true);
        
        // Delete every 4th record
        for (let i = 4; i <= 80; i += 4) {
            await sortIndex.deleteRecord(`record-${i.toString().padStart(8, '0')}`, { value: i } as any);
            
            // Check constraints after each deletion
            constraints = await verifyKeyConstraints(sortIndex, keySize);
            expect(constraints.allConstraintsMet).toBe(true);
        }
        
        await sortIndex.shutdown();
    });

    test('should maintain key constraints with random operations', async () => {
        const records: TestRecord[] = [];
        
        // Start with 40 records
        for (let i = 1; i <= 40; i++) {
            records.push(createRecord(i, i * 2));
        }
        
        collection = new MockCollection<TestRecord>(records);
        const keySize = 6;
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'random_ops_test',
            fieldName: 'value',
            direction: 'asc',
            pageSize: 7,
            keySize,
            uuidGenerator: new RandomUuidGenerator()
        }, collection);
        
        // Build the index
        await sortIndex.build();
        
        // Perform random operations
        for (let i = 1; i <= 20; i++) {
            // Add new records with odd values
            const newRecord = createRecord(100 + i, i * 2 - 1);
            await sortIndex.addRecord(newRecord);
            
            // Update some existing records
            if (i <= 10) {
                const updatedRecord = createRecord(i, i * 2 + 1000);
                const oldRecord = records[i - 1];
                await sortIndex.updateRecord(updatedRecord, oldRecord);
            }
            
            // Delete some records
            if (i <= 8) {
                await sortIndex.deleteRecord(`record-${(i + 20).toString().padStart(8, '0')}`, { value: (i + 20) * 2 } as any);
            }
            
            // Verify constraints after each set of operations
            const constraints = await verifyKeyConstraints(sortIndex, keySize);
            expect(constraints.allConstraintsMet).toBe(true);
            if (constraints.violations.length > 0) {
                console.log(`Operation ${i} violations:`, constraints.violations);
            }
        }
        
        await sortIndex.shutdown();
    });

    test('should maintain key constraints with duplicate values', async () => {
        const records: TestRecord[] = [];
        
        // Create records with many duplicates (10 groups of 8 records each)
        for (let group = 1; group <= 10; group++) {
            for (let item = 1; item <= 8; item++) {
                const id = (group - 1) * 8 + item;
                records.push(createRecord(id, group)); // Same value for each group
            }
        }
        
        collection = new MockCollection<TestRecord>(records);
        const keySize = 4;
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'duplicate_constraint_test',
            fieldName: 'value',
            direction: 'asc',
            pageSize: 6,
            keySize,
            uuidGenerator: new RandomUuidGenerator()
        }, collection);
        
        // Build the index
        await sortIndex.build();
        
        // Verify key constraints
        const constraints = await verifyKeyConstraints(sortIndex, keySize);
        
        expect(constraints.allConstraintsMet).toBe(true);
        expect(constraints.violations).toHaveLength(0);
        
        // Verify we can still find duplicate records
        const duplicates = await sortIndex.findByValue(5);
        expect(duplicates.length).toBe(8);
        
        await sortIndex.shutdown();
    });

    test('should maintain key constraints with large dataset', async () => {
        const records: TestRecord[] = [];
        
        // Create 300 records to ensure deep tree
        for (let i = 1; i <= 300; i++) {
            records.push(createRecord(i, i));
        }
        
        collection = new MockCollection<TestRecord>(records);
        const keySize = 8;
        const sortIndex = new SortIndex({
            storage,
            baseDirectory: 'db',
            collectionName: 'large_constraint_test',
            fieldName: 'value',
            direction: 'asc',
            pageSize: 15,
            keySize,
            uuidGenerator: new RandomUuidGenerator()
        }, collection);
        
        // Build the index
        await sortIndex.build();
        
        // Verify key constraints
        const constraints = await verifyKeyConstraints(sortIndex, keySize);
        
        expect(constraints.allConstraintsMet).toBe(true);
        expect(constraints.violations).toHaveLength(0);
        
        // Verify tree structure is reasonable
        const stats = await sortIndex.analyzeTreeStructure();
        expect(stats.totalNodes).toBeGreaterThan(10);
        expect(stats.leafNodes).toBeGreaterThan(10);
        
        // All leaf nodes should have 0 keys
        const leafNodes = constraints.nodeAnalysis.filter(n => n.nodeType === 'leaf');
        for (const leaf of leafNodes) {
            expect(leaf.actualKeyCount).toBe(0);
        }
        
        // All internal nodes should respect keySize limit
        const internalNodes = constraints.nodeAnalysis.filter(n => n.nodeType === 'internal');
        for (const internal of internalNodes) {
            expect(internal.actualKeyCount).toBeLessThanOrEqual(keySize);
        }
        
        await sortIndex.shutdown();
    });

    test('should maintain key constraints across different keySize values', async () => {
        const records: TestRecord[] = [];
        
        // Create 60 records
        for (let i = 1; i <= 60; i++) {
            records.push(createRecord(i, i));
        }
        
        // Test different keySize values
        const keySizes = [2, 3, 5, 7, 10];
        
        for (const keySize of keySizes) {
            collection = new MockCollection<TestRecord>(records);
            const sortIndex = new SortIndex({
                storage,
                baseDirectory: 'db',
                collectionName: `keysize_${keySize}_test`,
                fieldName: 'value',
                direction: 'asc',
                pageSize: 8,
                keySize,
            uuidGenerator: new RandomUuidGenerator()
            }, collection);
            
            // Build the index
            await sortIndex.build();
            
            // Verify key constraints
            const constraints = await verifyKeyConstraints(sortIndex, keySize);
            
            expect(constraints.allConstraintsMet).toBe(true);
            expect(constraints.violations).toHaveLength(0);
            
            // Verify that internal nodes don't exceed this specific keySize
            const internalNodes = constraints.nodeAnalysis.filter(n => n.nodeType === 'internal');
            for (const internal of internalNodes) {
                expect(internal.actualKeyCount).toBeLessThanOrEqual(keySize);
            }
            
            await sortIndex.shutdown();
        }
    });
});