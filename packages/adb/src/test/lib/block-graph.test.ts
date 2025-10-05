import { BlockGraph } from "../../lib/block-graph";
import { DatabaseUpdate, IFieldUpdate, IUpsertUpdate, IDeleteUpdate } from "../../lib/database-update";
import { MockStorage } from "storage/src/tests/mock-storage";
import { IStorage } from "storage";

describe('BlockGraph', () => {
    let storage: MockStorage;
    let blockGraph: BlockGraph<DatabaseUpdate[]>;

    // Helper function to get file contents as string
    const getFileContents = async (filePath: string): Promise<string | undefined> => {
        const buffer = await storage.read(filePath);
        return buffer ? buffer.toString('utf8') : undefined;
    };

    beforeEach(() => {
        storage = new MockStorage();
        blockGraph = new BlockGraph<DatabaseUpdate[]>(storage);
    });

    describe('initialization', () => {
        test('should initialize with empty head blocks', async () => {
            await blockGraph.loadHeadBlocks();
            const headBlockIds = blockGraph.getHeadBlockIds();
            expect(headBlockIds).toEqual([]);
        });

        test('should load existing head blocks from storage', async () => {
            // Pre-populate storage with head blocks
            const headBlocksData = {
                headBlockIds: ['block-1', 'block-2'],
                lastUpdated: new Date().toISOString()
            };
            await storage.write('head-blocks.json', 'application/json', 
                Buffer.from(JSON.stringify(headBlocksData), 'utf8'));

            await blockGraph.loadHeadBlocks();
            const headBlockIds = blockGraph.getHeadBlockIds();
            expect(headBlockIds).toEqual(['block-1', 'block-2']);
        });

        test('should handle corrupted head blocks file gracefully', async () => {
            // Write invalid JSON
            await storage.write('head-blocks.json', 'application/json', 
                Buffer.from('invalid json', 'utf8'));

            await blockGraph.loadHeadBlocks();
            const headBlockIds = blockGraph.getHeadBlockIds();
            expect(headBlockIds).toEqual([]);
        });
    });

    describe('block operations', () => {
        test('should create and commit a block with no predecessors', async () => {
            await blockGraph.loadHeadBlocks();

            const updates: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: Date.now(),
                    collection: 'test',
                    _id: 'doc1',
                    document: { name: 'Test Document' }
                } as IUpsertUpdate
            ];

            const block = await blockGraph.commitBlock(updates);

            expect(block._id).toBeDefined();
            expect(block.prevBlocks).toEqual([]);
            expect(block.data).toEqual(updates);

            // Verify block is stored
            const blockExists = await blockGraph.hasBlock(block._id);
            expect(blockExists).toBe(true);

            // Verify head blocks updated
            const headBlockIds = blockGraph.getHeadBlockIds();
            expect(headBlockIds).toEqual([block._id]);
        });

        test('should create a block with predecessors', async () => {
            await blockGraph.loadHeadBlocks();

            // Create first block
            const updates1: DatabaseUpdate[] = [
                {
                    type: 'field',
                    timestamp: Date.now(),
                    collection: 'test',
                    _id: 'doc1',
                    field: 'name',
                    value: 'First'
                } as IFieldUpdate
            ];
            const block1 = await blockGraph.commitBlock(updates1);

            // Create second block
            const updates2: DatabaseUpdate[] = [
                {
                    type: 'field',
                    timestamp: Date.now(),
                    collection: 'test',
                    _id: 'doc1',
                    field: 'name',
                    value: 'Second'
                } as IFieldUpdate
            ];
            const block2 = await blockGraph.commitBlock(updates2);

            expect(block2.prevBlocks).toEqual([block1._id]);
            
            // Verify head blocks points to latest block
            const headBlockIds = blockGraph.getHeadBlockIds();
            expect(headBlockIds).toEqual([block2._id]);
        });

        test('should retrieve blocks from storage', async () => {
            await blockGraph.loadHeadBlocks();

            const updates: DatabaseUpdate[] = [
                {
                    type: 'delete',
                    timestamp: Date.now(),
                    collection: 'test',
                    _id: 'doc1'
                } as IDeleteUpdate
            ];

            const originalBlock = await blockGraph.commitBlock(updates);

            // Create new block graph instance (simulating restart)
            const newBlockGraph = new BlockGraph<DatabaseUpdate[]>(storage);
            
            // Should be able to retrieve the block
            const retrievedBlock = await newBlockGraph.getBlock(originalBlock._id);
            expect(retrievedBlock).toEqual(originalBlock);
        });

        test('should return undefined for non-existent block', async () => {
            const block = await blockGraph.getBlock('non-existent-id');
            expect(block).toBeUndefined();
        });

        test('should check block existence correctly', async () => {
            await blockGraph.loadHeadBlocks();

            const updates: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: Date.now(),
                    collection: 'test',
                    _id: 'doc1',
                    document: { test: true }
                } as IUpsertUpdate
            ];

            const block = await blockGraph.commitBlock(updates);

            expect(await blockGraph.hasBlock(block._id)).toBe(true);
            expect(await blockGraph.hasBlock('non-existent')).toBe(false);
        });
    });

    describe('head block management', () => {
        test('should get head blocks', async () => {
            await blockGraph.loadHeadBlocks();

            const updates: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: Date.now(),
                    collection: 'test',
                    _id: 'doc1',
                    document: { value: 1 }
                } as IUpsertUpdate
            ];

            const block = await blockGraph.commitBlock(updates);
            const headBlocks = await blockGraph.getHeadBlocks();

            expect(headBlocks).toHaveLength(1);
            expect(headBlocks[0]).toEqual(block);
        });

        test('should handle empty head blocks list', async () => {
            await blockGraph.loadHeadBlocks();
            const headBlocks = await blockGraph.getHeadBlocks();
            expect(headBlocks).toEqual([]);
        });
    });

    describe('block integration', () => {
        test('should integrate external block', async () => {
            await blockGraph.loadHeadBlocks();

            // Create an external block (simulating from another node)
            const externalBlock = {
                _id: 'external-block-id',
                prevBlocks: [],
                data: [
                    {
                        type: 'upsert',
                        timestamp: Date.now(),
                        collection: 'external',
                        _id: 'doc1',
                        document: { source: 'external' }
                    } as IUpsertUpdate
                ]
            };

            await blockGraph.integrateBlock(externalBlock);

            // Should be able to retrieve the block
            const retrievedBlock = await blockGraph.getBlock(externalBlock._id);
            expect(retrievedBlock).toEqual(externalBlock);

            // Should be added to head blocks
            const headBlockIds = blockGraph.getHeadBlockIds();
            expect(headBlockIds).toContain(externalBlock._id);
        });

        test('should handle block integration with predecessors', async () => {
            await blockGraph.loadHeadBlocks();

            // Create first block locally
            const updates1: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: Date.now(),
                    collection: 'test',
                    _id: 'doc1',
                    document: { version: 1 }
                } as IUpsertUpdate
            ];
            const block1 = await blockGraph.commitBlock(updates1);

            // Create external block that references first block
            const externalBlock = {
                _id: 'external-block-id',
                prevBlocks: [block1._id],
                data: [
                    {
                        type: 'field',
                        timestamp: Date.now(),
                        collection: 'test',
                        _id: 'doc1',
                        field: 'version',
                        value: 2
                    } as IFieldUpdate
                ]
            };

            await blockGraph.integrateBlock(externalBlock);

            // First block should no longer be a head (it has a successor)
            // External block should be the new head
            const headBlockIds = blockGraph.getHeadBlockIds();
            expect(headBlockIds).toEqual([externalBlock._id]);
            expect(headBlockIds).not.toContain(block1._id);
        });
    });

    describe('persistence', () => {
        test('should persist blocks to correct paths', async () => {
            await blockGraph.loadHeadBlocks();

            const updates: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: Date.now(),
                    collection: 'test',
                    _id: 'doc1',
                    document: { persisted: true }
                } as IUpsertUpdate
            ];

            const block = await blockGraph.commitBlock(updates);

            // Check that block file exists at expected path
            const blockPath = `blocks/${block._id}.json`;
            expect(await storage.fileExists(blockPath)).toBe(true);

            // Check block content
            const blockContent = await getFileContents(blockPath);
            expect(blockContent).toBeDefined();
            const parsedBlock = JSON.parse(blockContent!);
            expect(parsedBlock._id).toBe(block._id);
            expect(parsedBlock.data).toEqual(updates);
        });

        test('should persist head blocks to correct path', async () => {
            await blockGraph.loadHeadBlocks();

            const updates: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: Date.now(),
                    collection: 'test',
                    _id: 'doc1',
                    document: { test: true }
                } as IUpsertUpdate
            ];

            const block = await blockGraph.commitBlock(updates);

            // Check that head blocks file exists
            const headBlocksPath = 'head-blocks.json';
            expect(await storage.fileExists(headBlocksPath)).toBe(true);

            // Check head blocks content
            const headBlocksContent = await getFileContents(headBlocksPath);
            expect(headBlocksContent).toBeDefined();
            const parsedHeadBlocks = JSON.parse(headBlocksContent!);
            expect(parsedHeadBlocks.headBlockIds).toEqual([block._id]);
            expect(parsedHeadBlocks.lastUpdated).toBeDefined();
        });
    });

    describe('multiple database update types', () => {
        test('should handle field updates', async () => {
            await blockGraph.loadHeadBlocks();

            const fieldUpdate: IFieldUpdate = {
                type: 'field',
                timestamp: Date.now(),
                collection: 'users',
                _id: 'user1',
                field: 'name',
                value: 'John Doe'
            };

            const block = await blockGraph.commitBlock([fieldUpdate]);
            expect(block.data[0]).toEqual(fieldUpdate);
        });

        test('should handle upsert updates', async () => {
            await blockGraph.loadHeadBlocks();

            const upsertUpdate: IUpsertUpdate = {
                type: 'upsert',
                timestamp: Date.now(),
                collection: 'products',
                _id: 'prod1',
                document: {
                    name: 'Widget',
                    price: 99.99,
                    category: 'gadgets'
                }
            };

            const block = await blockGraph.commitBlock([upsertUpdate]);
            expect(block.data[0]).toEqual(upsertUpdate);
        });

        test('should handle delete updates', async () => {
            await blockGraph.loadHeadBlocks();

            const deleteUpdate: IDeleteUpdate = {
                type: 'delete',
                timestamp: Date.now(),
                collection: 'temp',
                _id: 'temp1'
            };

            const block = await blockGraph.commitBlock([deleteUpdate]);
            expect(block.data[0]).toEqual(deleteUpdate);
        });

        test('should handle mixed update types in single block', async () => {
            await blockGraph.loadHeadBlocks();

            const mixedUpdates: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: Date.now(),
                    collection: 'users',
                    _id: 'user1',
                    document: { name: 'Jane', email: 'jane@example.com' }
                } as IUpsertUpdate,
                {
                    type: 'field',
                    timestamp: Date.now(),
                    collection: 'users',
                    _id: 'user2',
                    field: 'active',
                    value: false
                } as IFieldUpdate,
                {
                    type: 'delete',
                    timestamp: Date.now(),
                    collection: 'users',
                    _id: 'user3'
                } as IDeleteUpdate
            ];

            const block = await blockGraph.commitBlock(mixedUpdates);
            expect(block.data).toEqual(mixedUpdates);
            expect(block.data).toHaveLength(3);
        });
    });

    describe('error handling', () => {
        test('should handle storage errors gracefully', async () => {
            // Create a new MockStorage instance and override methods to throw errors
            const errorStorage = new MockStorage();
            const originalRead = errorStorage.read.bind(errorStorage);
            errorStorage.read = async () => { throw new Error('Storage error'); };

            const errorBlockGraph = new BlockGraph<DatabaseUpdate[]>(errorStorage);
            
            // Should handle load error gracefully
            await expect(errorBlockGraph.loadHeadBlocks()).resolves.toBeUndefined();
            expect(errorBlockGraph.getHeadBlockIds()).toEqual([]);
        });
    });
});