import { getAllBlocks, getBlocksBehindHeads, getBlocksToApply, applyDatabaseUpdates } from './debug-build-snapshot';
import { BlockGraph, DatabaseUpdate, IBlock, IFieldUpdate, IUpsertUpdate, IDeleteUpdate } from 'adb';
import { MockStorage, MockDatabase } from 'storage';
import { IStorage } from 'storage';

// Mock BlockGraph
class MockBlockGraph extends BlockGraph<DatabaseUpdate[]> {
    private mockBlocks = new Map<string, IBlock<DatabaseUpdate[]>>();

    constructor(storage: IStorage) {
        super(storage);
    }

    addMockBlock(block: IBlock<DatabaseUpdate[]>): void {
        this.mockBlocks.set(block._id, block);
    }

    async getBlock(id: string): Promise<IBlock<DatabaseUpdate[]> | undefined> {
        return this.mockBlocks.get(id);
    }
}

describe('debug-build-snapshot functions', () => {
    let storage: MockStorage;
    let blockGraph: MockBlockGraph;
    let bsonDatabase: MockDatabase;

    beforeEach(() => {
        storage = new MockStorage();
        blockGraph = new MockBlockGraph(storage);
        bsonDatabase = new MockDatabase();
    });

    describe('getAllBlocks', () => {
        test('should return empty array when no blocks exist', async () => {
            const blocks = await getAllBlocks(blockGraph, storage);
            expect(blocks).toEqual([]);
        });

        test('should return all blocks from storage', async () => {
            // Setup mock storage with block files
            const block1: IBlock<DatabaseUpdate[]> = {
                _id: 'block1',
                prevBlocks: [],
                data: [{ type: 'upsert', timestamp: 1000, collection: 'test', _id: 'doc1', document: { name: 'test1' } } as IUpsertUpdate]
            };
            const block2: IBlock<DatabaseUpdate[]> = {
                _id: 'block2',
                prevBlocks: ['block1'],
                data: [{ type: 'field', timestamp: 2000, collection: 'test', _id: 'doc1', field: 'name', value: 'test2' } as IFieldUpdate]
            };

            // Add mock files to storage to simulate blocks directory
            await storage.write('blocks/block1', 'application/octet-stream', Buffer.from('mock-data-1'));
            await storage.write('blocks/block2', 'application/octet-stream', Buffer.from('mock-data-2'));
            
            // Add blocks to mock block graph
            blockGraph.addMockBlock(block1);
            blockGraph.addMockBlock(block2);

            const blocks = await getAllBlocks(blockGraph, storage);
            
            expect(blocks).toHaveLength(2);
            expect(blocks).toContainEqual(block1);
            expect(blocks).toContainEqual(block2);
        });

        test('should handle pagination correctly', async () => {
            const block1: IBlock<DatabaseUpdate[]> = {
                _id: 'block1',
                prevBlocks: [],
                data: [{ type: 'upsert', timestamp: 1000, collection: 'test', _id: 'doc1', document: { name: 'test1' } } as IUpsertUpdate]
            };
            const block2: IBlock<DatabaseUpdate[]> = {
                _id: 'block2',
                prevBlocks: [],
                data: [{ type: 'upsert', timestamp: 2000, collection: 'test', _id: 'doc2', document: { name: 'test2' } } as IUpsertUpdate]
            };

            // Add many mock files to test pagination (MockStorage has default limit in implementation)
            for (let i = 0; i < 10; i++) {
                await storage.write(`blocks/block${i}`, 'application/octet-stream', Buffer.from(`mock-data-${i}`));
            }
            
            blockGraph.addMockBlock(block1);
            blockGraph.addMockBlock(block2);

            const blocks = await getAllBlocks(blockGraph, storage);
            
            // Should get the blocks that were actually added to the mock block graph
            expect(blocks).toHaveLength(2);
            expect(blocks.map(b => b._id)).toContain('block1');
            expect(blocks.map(b => b._id)).toContain('block2');
        });

        test('should skip blocks that cannot be loaded', async () => {
            const block1: IBlock<DatabaseUpdate[]> = {
                _id: 'block1',
                prevBlocks: [],
                data: [{ type: 'upsert', timestamp: 1000, collection: 'test', _id: 'doc1', document: { name: 'test1' } } as IUpsertUpdate]
            };

            // Add files to storage but only add one block to the mock block graph
            await storage.write('blocks/block1', 'application/octet-stream', Buffer.from('mock-data-1'));
            await storage.write('blocks/missing-block', 'application/octet-stream', Buffer.from('mock-data-missing'));
            
            blockGraph.addMockBlock(block1);
            // Don't add missing-block to mock block graph

            const blocks = await getAllBlocks(blockGraph, storage);
            
            expect(blocks).toHaveLength(1);
            expect(blocks[0]).toEqual(block1);
        });
    });

    describe('getBlocksBehindHeads', () => {
        test('should return empty set for empty head blocks', async () => {
            const behindBlocks = await getBlocksBehindHeads(blockGraph, []);
            expect(behindBlocks.size).toBe(0);
        });

        test('should return single block when head has no predecessors', async () => {
            const block1: IBlock<DatabaseUpdate[]> = {
                _id: 'block1',
                prevBlocks: [],
                data: []
            };

            blockGraph.addMockBlock(block1);

            const behindBlocks = await getBlocksBehindHeads(blockGraph, ['block1']);
            
            expect(behindBlocks.size).toBe(1);
            expect(behindBlocks.has('block1')).toBe(true);
        });

        test('should traverse backwards through predecessor blocks', async () => {
            const block1: IBlock<DatabaseUpdate[]> = {
                _id: 'block1',
                prevBlocks: [],
                data: []
            };
            const block2: IBlock<DatabaseUpdate[]> = {
                _id: 'block2',
                prevBlocks: ['block1'],
                data: []
            };
            const block3: IBlock<DatabaseUpdate[]> = {
                _id: 'block3',
                prevBlocks: ['block2'],
                data: []
            };

            blockGraph.addMockBlock(block1);
            blockGraph.addMockBlock(block2);
            blockGraph.addMockBlock(block3);

            const behindBlocks = await getBlocksBehindHeads(blockGraph, ['block3']);
            
            expect(behindBlocks.size).toBe(3);
            expect(behindBlocks.has('block1')).toBe(true);
            expect(behindBlocks.has('block2')).toBe(true);
            expect(behindBlocks.has('block3')).toBe(true);
        });

        test('should handle multiple head blocks', async () => {
            const block1: IBlock<DatabaseUpdate[]> = {
                _id: 'block1',
                prevBlocks: [],
                data: []
            };
            const block2: IBlock<DatabaseUpdate[]> = {
                _id: 'block2',
                prevBlocks: [],
                data: []
            };
            const block3: IBlock<DatabaseUpdate[]> = {
                _id: 'block3',
                prevBlocks: ['block1'],
                data: []
            };

            blockGraph.addMockBlock(block1);
            blockGraph.addMockBlock(block2);
            blockGraph.addMockBlock(block3);

            const behindBlocks = await getBlocksBehindHeads(blockGraph, ['block2', 'block3']);
            
            expect(behindBlocks.size).toBe(3);
            expect(behindBlocks.has('block1')).toBe(true);
            expect(behindBlocks.has('block2')).toBe(true);
            expect(behindBlocks.has('block3')).toBe(true);
        });

        test('should handle diamond-shaped graph correctly', async () => {
            const block1: IBlock<DatabaseUpdate[]> = {
                _id: 'block1',
                prevBlocks: [],
                data: []
            };
            const block2: IBlock<DatabaseUpdate[]> = {
                _id: 'block2',
                prevBlocks: ['block1'],
                data: []
            };
            const block3: IBlock<DatabaseUpdate[]> = {
                _id: 'block3',
                prevBlocks: ['block1'],
                data: []
            };
            const block4: IBlock<DatabaseUpdate[]> = {
                _id: 'block4',
                prevBlocks: ['block2', 'block3'],
                data: []
            };

            blockGraph.addMockBlock(block1);
            blockGraph.addMockBlock(block2);
            blockGraph.addMockBlock(block3);
            blockGraph.addMockBlock(block4);

            const behindBlocks = await getBlocksBehindHeads(blockGraph, ['block4']);
            
            expect(behindBlocks.size).toBe(4);
            expect(behindBlocks.has('block1')).toBe(true);
            expect(behindBlocks.has('block2')).toBe(true);
            expect(behindBlocks.has('block3')).toBe(true);
            expect(behindBlocks.has('block4')).toBe(true);
        });

        test('should handle missing blocks gracefully', async () => {
            const block2: IBlock<DatabaseUpdate[]> = {
                _id: 'block2',
                prevBlocks: ['missing-block'],
                data: []
            };

            blockGraph.addMockBlock(block2);

            const behindBlocks = await getBlocksBehindHeads(blockGraph, ['block2']);
            
            expect(behindBlocks.size).toBe(2);
            expect(behindBlocks.has('block2')).toBe(true);
            expect(behindBlocks.has('missing-block')).toBe(true);
        });
    });

    describe('getBlocksToApply', () => {
        test('should return all blocks when no stored head hashes', async () => {
            const block1: IBlock<DatabaseUpdate[]> = {
                _id: 'block1',
                prevBlocks: [],
                data: [{ type: 'upsert', timestamp: 1000, collection: 'test', _id: 'doc1', document: { name: 'test1' } } as IUpsertUpdate]
            };

            await storage.write('blocks/block1', 'application/octet-stream', Buffer.from('mock-data-1'));
            blockGraph.addMockBlock(block1);

            const blocksToApply = await getBlocksToApply(blockGraph, storage, []);
            
            expect(blocksToApply).toHaveLength(1);
            expect(blocksToApply[0]).toEqual(block1);
        });

        test('should return empty array when no unapplied blocks', async () => {
            const block1: IBlock<DatabaseUpdate[]> = {
                _id: 'block1',
                prevBlocks: [],
                data: [{ type: 'upsert', timestamp: 1000, collection: 'test', _id: 'doc1', document: { name: 'test1' } } as IUpsertUpdate]
            };

            await storage.write('blocks/block1', 'application/octet-stream', Buffer.from('mock-data-1'));
            blockGraph.addMockBlock(block1);

            // All blocks are behind the head hash
            const blocksToApply = await getBlocksToApply(blockGraph, storage, ['block1']);
            
            expect(blocksToApply).toHaveLength(0);
        });

        test('should find blocks after minimum timestamp of unapplied blocks', async () => {
            const block1: IBlock<DatabaseUpdate[]> = {
                _id: 'block1',
                prevBlocks: [],
                data: [{ type: 'upsert', timestamp: 1000, collection: 'test', _id: 'doc1', document: { name: 'test1' } } as IUpsertUpdate]
            };
            const block2: IBlock<DatabaseUpdate[]> = {
                _id: 'block2',
                prevBlocks: ['block1'],
                data: [{ type: 'field', timestamp: 2000, collection: 'test', _id: 'doc1', field: 'name', value: 'test2' } as IFieldUpdate]
            };
            const block3: IBlock<DatabaseUpdate[]> = {
                _id: 'block3',
                prevBlocks: [],
                data: [{ type: 'upsert', timestamp: 3000, collection: 'test', _id: 'doc2', document: { name: 'test3' } } as IUpsertUpdate]
            };
            const block4: IBlock<DatabaseUpdate[]> = {
                _id: 'block4',
                prevBlocks: [],
                data: [{ type: 'field', timestamp: 4000, collection: 'test', _id: 'doc2', field: 'name', value: 'test4' } as IFieldUpdate]
            };

            // Add blocks to storage
            await storage.write('blocks/block1', 'application/octet-stream', Buffer.from('mock-data-1'));
            await storage.write('blocks/block2', 'application/octet-stream', Buffer.from('mock-data-2'));
            await storage.write('blocks/block3', 'application/octet-stream', Buffer.from('mock-data-3'));
            await storage.write('blocks/block4', 'application/octet-stream', Buffer.from('mock-data-4'));
            
            blockGraph.addMockBlock(block1);
            blockGraph.addMockBlock(block2);
            blockGraph.addMockBlock(block3);
            blockGraph.addMockBlock(block4);

            // Only block1 and block2 are behind the stored head hash
            const blocksToApply = await getBlocksToApply(blockGraph, storage, ['block2']);
            
            // block3 and block4 are unapplied, minimum timestamp is 3000
            // Should return blocks with timestamp >= 3000, which are block3 and block4
            expect(blocksToApply).toHaveLength(2);
            expect(blocksToApply.map(b => b._id).sort()).toEqual(['block3', 'block4']);
        });

        test('should include applied blocks if they have updates at or after minimum timestamp', async () => {
            const block1: IBlock<DatabaseUpdate[]> = {
                _id: 'block1',
                prevBlocks: [],
                data: [
                    { type: 'upsert', timestamp: 1000, collection: 'test', _id: 'doc1', document: { name: 'test1' } } as IUpsertUpdate,
                    { type: 'field', timestamp: 3500, collection: 'test', _id: 'doc1', field: 'name', value: 'updated' } as IFieldUpdate
                ]
            };
            const block2: IBlock<DatabaseUpdate[]> = {
                _id: 'block2',
                prevBlocks: [],
                data: [{ type: 'upsert', timestamp: 4000, collection: 'test', _id: 'doc2', document: { name: 'test2' } } as IUpsertUpdate]
            };

            await storage.write('blocks/block1', 'application/octet-stream', Buffer.from('mock-data-1'));
            await storage.write('blocks/block2', 'application/octet-stream', Buffer.from('mock-data-2'));
            
            blockGraph.addMockBlock(block1);
            blockGraph.addMockBlock(block2);

            // block1 is applied (behind head hash), block2 is unapplied
            const blocksToApply = await getBlocksToApply(blockGraph, storage, ['block1']);
            
            // block2 is unapplied with min timestamp 4000
            // block1 has an update at 3500, which is < 4000, so block1 should not be included
            // Only block2 should be returned
            expect(blocksToApply).toHaveLength(1);
            expect(blocksToApply[0]._id).toBe('block2');
        });

        test('should handle blocks with updates spanning the minimum timestamp', async () => {
            const block1: IBlock<DatabaseUpdate[]> = {
                _id: 'block1',
                prevBlocks: [],
                data: [
                    { type: 'upsert', timestamp: 1000, collection: 'test', _id: 'doc1', document: { name: 'old' } } as IUpsertUpdate,
                    { type: 'field', timestamp: 4500, collection: 'test', _id: 'doc1', field: 'name', value: 'new' } as IFieldUpdate
                ]
            };
            const block2: IBlock<DatabaseUpdate[]> = {
                _id: 'block2', 
                prevBlocks: [],
                data: [{ type: 'upsert', timestamp: 4000, collection: 'test', _id: 'doc2', document: { name: 'test2' } } as IUpsertUpdate]
            };

            await storage.write('blocks/block1', 'application/octet-stream', Buffer.from('mock-data-1'));
            await storage.write('blocks/block2', 'application/octet-stream', Buffer.from('mock-data-2'));
            
            blockGraph.addMockBlock(block1);
            blockGraph.addMockBlock(block2);

            // block1 is applied (behind head hash), block2 is unapplied
            const blocksToApply = await getBlocksToApply(blockGraph, storage, ['block1']);
            
            // block2 is unapplied with min timestamp 4000
            // block1 has an update at 4500, which is >= 4000, so both blocks should be returned
            expect(blocksToApply).toHaveLength(2);
            expect(blocksToApply.map(b => b._id).sort()).toEqual(['block1', 'block2']);
        });

        test('should handle complex graph with multiple unapplied branches', async () => {
            // Create a graph:
            // block1 -> block2 (applied branch)
            //        -> block3 (unapplied branch, timestamp 3000)
            // block4 (independent unapplied, timestamp 5000)
            const block1: IBlock<DatabaseUpdate[]> = {
                _id: 'block1',
                prevBlocks: [],
                data: [{ type: 'upsert', timestamp: 1000, collection: 'test', _id: 'doc1', document: { name: 'test1' } } as IUpsertUpdate]
            };
            const block2: IBlock<DatabaseUpdate[]> = {
                _id: 'block2',
                prevBlocks: ['block1'],
                data: [{ type: 'field', timestamp: 2000, collection: 'test', _id: 'doc1', field: 'name', value: 'test2' } as IFieldUpdate]
            };
            const block3: IBlock<DatabaseUpdate[]> = {
                _id: 'block3',
                prevBlocks: ['block1'],
                data: [{ type: 'upsert', timestamp: 3000, collection: 'test', _id: 'doc3', document: { name: 'test3' } } as IUpsertUpdate]
            };
            const block4: IBlock<DatabaseUpdate[]> = {
                _id: 'block4',
                prevBlocks: [],
                data: [{ type: 'upsert', timestamp: 5000, collection: 'test', _id: 'doc4', document: { name: 'test4' } } as IUpsertUpdate]
            };

            await storage.write('blocks/block1', 'application/octet-stream', Buffer.from('mock-data-1'));
            await storage.write('blocks/block2', 'application/octet-stream', Buffer.from('mock-data-2'));
            await storage.write('blocks/block3', 'application/octet-stream', Buffer.from('mock-data-3'));
            await storage.write('blocks/block4', 'application/octet-stream', Buffer.from('mock-data-4'));
            
            blockGraph.addMockBlock(block1);
            blockGraph.addMockBlock(block2);
            blockGraph.addMockBlock(block3);
            blockGraph.addMockBlock(block4);

            // Only block1 and block2 are applied (behind head hash)
            const blocksToApply = await getBlocksToApply(blockGraph, storage, ['block2']);
            
            // block3 and block4 are unapplied, minimum timestamp is 3000
            // Should return blocks with timestamp >= 3000, which are block3 and block4
            expect(blocksToApply).toHaveLength(2);
            expect(blocksToApply.map(b => b._id).sort()).toEqual(['block3', 'block4']);
        });

        test('should handle mixed timestamps where applied block has later updates', async () => {
            const block1: IBlock<DatabaseUpdate[]> = {
                _id: 'block1',
                prevBlocks: [],
                data: [
                    { type: 'upsert', timestamp: 1000, collection: 'test', _id: 'doc1', document: { name: 'early' } } as IUpsertUpdate,
                    { type: 'field', timestamp: 6000, collection: 'test', _id: 'doc1', field: 'name', value: 'late' } as IFieldUpdate
                ]
            };
            const block2: IBlock<DatabaseUpdate[]> = {
                _id: 'block2',
                prevBlocks: [],
                data: [{ type: 'upsert', timestamp: 5000, collection: 'test', _id: 'doc2', document: { name: 'test2' } } as IUpsertUpdate]
            };

            await storage.write('blocks/block1', 'application/octet-stream', Buffer.from('mock-data-1'));
            await storage.write('blocks/block2', 'application/octet-stream', Buffer.from('mock-data-2'));
            
            blockGraph.addMockBlock(block1);
            blockGraph.addMockBlock(block2);

            // block1 is applied, block2 is unapplied
            const blocksToApply = await getBlocksToApply(blockGraph, storage, ['block1']);
            
            // block2 is unapplied with min timestamp 5000
            // block1 has an update at 6000, which is >= 5000, so both should be returned
            expect(blocksToApply).toHaveLength(2);
            expect(blocksToApply.map(b => b._id).sort()).toEqual(['block1', 'block2']);
        });

        test('should exclude applied blocks when all their updates are before minimum timestamp', async () => {
            const block1: IBlock<DatabaseUpdate[]> = {
                _id: 'block1',
                prevBlocks: [],
                data: [
                    { type: 'upsert', timestamp: 1000, collection: 'test', _id: 'doc1', document: { name: 'early1' } } as IUpsertUpdate,
                    { type: 'field', timestamp: 2000, collection: 'test', _id: 'doc1', field: 'name', value: 'early2' } as IFieldUpdate
                ]
            };
            const block2: IBlock<DatabaseUpdate[]> = {
                _id: 'block2',
                prevBlocks: [],
                data: [{ type: 'upsert', timestamp: 5000, collection: 'test', _id: 'doc2', document: { name: 'test2' } } as IUpsertUpdate]
            };

            await storage.write('blocks/block1', 'application/octet-stream', Buffer.from('mock-data-1'));
            await storage.write('blocks/block2', 'application/octet-stream', Buffer.from('mock-data-2'));
            
            blockGraph.addMockBlock(block1);
            blockGraph.addMockBlock(block2);

            // block1 is applied, block2 is unapplied
            const blocksToApply = await getBlocksToApply(blockGraph, storage, ['block1']);
            
            // block2 is unapplied with min timestamp 5000
            // block1's latest update is at 2000, which is < 5000, so only block2 should be returned
            expect(blocksToApply).toHaveLength(1);
            expect(blocksToApply[0]._id).toBe('block2');
        });
    });

    describe('applyDatabaseUpdates', () => {
        test('should apply upsert updates correctly', async () => {
            const updates: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: 1000,
                    collection: 'users',
                    _id: 'user1',
                    document: { _id: 'user1', name: 'John', email: 'john@example.com' }
                } as IUpsertUpdate
            ];

            await applyDatabaseUpdates(bsonDatabase, updates);

            const collection = bsonDatabase.getMockCollection('users');
            const user = await collection.getOne('user1');
            expect(user).toEqual({ _id: 'user1', name: 'John', email: 'john@example.com' });
        });

        test('should apply field updates correctly', async () => {
            const updates: DatabaseUpdate[] = [
                {
                    type: 'field',
                    timestamp: 1000,
                    collection: 'users',
                    _id: 'user1',
                    field: 'name',
                    value: 'Jane'
                } as IFieldUpdate
            ];

            await applyDatabaseUpdates(bsonDatabase, updates);

            const collection = bsonDatabase.getMockCollection('users');
            const user = await collection.getOne('user1');
            expect(user).toEqual({ _id: 'user1', name: 'Jane' });
        });

        test('should apply delete updates correctly', async () => {
            // First create a user to delete
            await bsonDatabase.collection('users').replaceOne('user1', { _id: 'user1', name: 'John' }, { upsert: true });
            
            const updates: DatabaseUpdate[] = [
                {
                    type: 'delete',
                    timestamp: 1000,
                    collection: 'users',
                    _id: 'user1'
                } as IDeleteUpdate
            ];

            await applyDatabaseUpdates(bsonDatabase, updates);

            const collection = bsonDatabase.getMockCollection('users');
            const user = await collection.getOne('user1');
            expect(user).toBeUndefined();
        });

        test('should apply multiple updates in order', async () => {
            const updates: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: 1000,
                    collection: 'users',
                    _id: 'user1',
                    document: { _id: 'user1', name: 'John' }
                } as IUpsertUpdate,
                {
                    type: 'field',
                    timestamp: 2000,
                    collection: 'users',
                    _id: 'user1',
                    field: 'email',
                    value: 'john@example.com'
                } as IFieldUpdate,
                {
                    type: 'delete',
                    timestamp: 3000,
                    collection: 'users',
                    _id: 'user2'
                } as IDeleteUpdate
            ];

            await applyDatabaseUpdates(bsonDatabase, updates);

            const collection = bsonDatabase.getMockCollection('users');
            const user1 = await collection.getOne('user1');
            expect(user1).toEqual({ _id: 'user1', name: 'John', email: 'john@example.com' });
            
            const user2 = await collection.getOne('user2');
            expect(user2).toBeUndefined(); // Should be deleted (or never existed)
        });

        test('should handle multiple collections', async () => {
            const updates: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: 1000,
                    collection: 'users',
                    _id: 'user1',
                    document: { _id: 'user1', name: 'John' }
                } as IUpsertUpdate,
                {
                    type: 'upsert',
                    timestamp: 2000,
                    collection: 'products',
                    _id: 'prod1',
                    document: { _id: 'prod1', name: 'Widget' }
                } as IUpsertUpdate
            ];

            await applyDatabaseUpdates(bsonDatabase, updates);

            const usersCollection = bsonDatabase.getMockCollection('users');
            const productsCollection = bsonDatabase.getMockCollection('products');
            
            const user = await usersCollection.getOne('user1');
            const product = await productsCollection.getOne('prod1');
            
            expect(user).toEqual({ _id: 'user1', name: 'John' });
            expect(product).toEqual({ _id: 'prod1', name: 'Widget' });
        });

        test('should handle errors gracefully and continue processing', async () => {
            // Override collection method to throw error for specific collection
            const originalCollection = bsonDatabase.collection.bind(bsonDatabase);
            bsonDatabase.collection = (name: string) => {
                if (name === 'error-collection') {
                    return {
                        replaceOne: async () => { throw new Error('Database error'); },
                        updateOne: async () => { throw new Error('Database error'); },
                        deleteOne: async () => { throw new Error('Database error'); },
                    } as any;
                }
                return originalCollection(name);
            };

            const updates: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: 1000,
                    collection: 'error-collection',
                    _id: 'doc1',
                    document: { _id: 'doc1', name: 'test' }
                } as IUpsertUpdate,
                {
                    type: 'upsert',
                    timestamp: 2000,
                    collection: 'good-collection',
                    _id: 'doc2',
                    document: { _id: 'doc2', name: 'test2' }
                } as IUpsertUpdate
            ];

            // Should not throw, but continue processing
            await expect(applyDatabaseUpdates(bsonDatabase, updates)).resolves.toBeUndefined();
            
            // Verify the good collection still worked
            const goodCollection = bsonDatabase.getMockCollection('good-collection');
            const doc = await goodCollection.getOne('doc2');
            expect(doc).toEqual({ _id: 'doc2', name: 'test2' });
        });
    });
});