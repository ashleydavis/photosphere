import { BlockGraph, IBlock } from "../../lib/block-graph";
import { DatabaseUpdate, IFieldUpdate, IUpsertUpdate, IDeleteUpdate } from "../../lib/database-update";
import { MockStorage } from "storage/src/tests/mock-storage";
import { v4 as uuid } from "uuid";

describe('BlockGraph', () => {
    let storage: MockStorage;
    let metadataStorage: MockStorage;
    let blockGraph: BlockGraph<DatabaseUpdate>;

    // Helper function to get file contents as string
    const getFileContents = async (filePath: string): Promise<string | undefined> => {
        const buffer = await metadataStorage.read(filePath);
        return buffer ? buffer.toString('utf8') : undefined;
    };

    beforeEach(() => {
        storage = new MockStorage();
        metadataStorage = new MockStorage();
        blockGraph = new BlockGraph<DatabaseUpdate>(storage, metadataStorage);
    });

    describe('initialization', () => {
        test('should initialize with empty head blocks', async () => {
            const headBlockIds = await blockGraph.getHeadBlockIds();
            expect(headBlockIds).toEqual([]);
        });

        test('should load existing head blocks from storage', async () => {
            // Pre-populate storage with head blocks
            const headBlocksData = {
                headBlockIds: ['block-1', 'block-2']
            };
            await metadataStorage.write('head-blocks.json', 'application/json', 
                Buffer.from(JSON.stringify(headBlocksData), 'utf8'));

            const headBlockIds = await blockGraph.getHeadBlockIds();
            expect(headBlockIds).toEqual(['block-1', 'block-2']);
        });

        test('should throw error on corrupted head blocks file', async () => {
            // Write invalid JSON
            await metadataStorage.write('head-blocks.json', 'application/json', 
                Buffer.from('invalid json', 'utf8'));

            await expect(blockGraph.getHeadBlockIds()).rejects.toThrow();
        });
    });

    describe('block operations', () => {
        test('should create and commit a block with no predecessors', async () => {

            const updates: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: Date.now(),
                    collection: 'test',
                    _id: uuid(),
                    document: { name: 'Test Document' },
                },
            ];

            const block = await blockGraph.commitBlock(`blocks`, updates);

            expect(block._id).toBeDefined();
            expect(block.prevBlocks).toEqual([]);
            expect(block.data).toEqual(updates);

            // Verify block is stored
            const blockExists = await blockGraph.hasBlock(`blocks`, block._id);
            expect(blockExists).toBe(true);

            // Verify head blocks updated
            const headBlockIds = await blockGraph.getHeadBlockIds();
            expect(headBlockIds).toEqual([block._id]);
        });

        test('should create a block with predecessors', async () => {

            // Create first block
            const updates1: DatabaseUpdate[] = [
                {
                    type: 'field',
                    timestamp: Date.now(),
                    collection: 'test',
                    _id: uuid(),
                    field: 'name',
                    value: 'First',
                },
            ];
            const block1 = await blockGraph.commitBlock(`blocks`, updates1);

            // Create second block
            const updates2: DatabaseUpdate[] = [
                {
                    type: 'field',
                    timestamp: Date.now(),
                    collection: 'test',
                    _id: uuid(),
                    field: 'name',
                    value: 'Second',
                },
            ];
            const block2 = await blockGraph.commitBlock(`blocks`, updates2);

            expect(block2.prevBlocks).toEqual([block1._id]);
            
            // Verify head blocks points to latest block
            const headBlockIds = await blockGraph.getHeadBlockIds();
            expect(headBlockIds).toEqual([block2._id]);
        });

        test('should retrieve blocks from storage', async () => {

            const updates: DatabaseUpdate[] = [
                {
                    type: 'delete',
                    timestamp: Date.now(),
                    collection: 'test',
                    _id: uuid(),
                },
            ];

            const originalBlock = await blockGraph.commitBlock(`blocks`, updates);

            // Create new block graph instance (simulating restart)
            const newBlockGraph = new BlockGraph<DatabaseUpdate>(storage, metadataStorage);
            
            // Should be able to retrieve the block from storage
            const retrievedBlock = await newBlockGraph.getBlock(`blocks`, originalBlock._id);
            expect(retrievedBlock).toEqual(originalBlock);
        });

        test('should return undefined for non-existent block', async () => {
            const block = await blockGraph.getBlock(`blocks`, 'non-existent-id');
            expect(block).toBeUndefined();
        });

        test('should check block existence correctly', async () => {

            const updates: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: Date.now(),
                    collection: 'test',
                    _id: uuid(),
                    document: { test: true },
                },
            ];

            const block = await blockGraph.commitBlock(`blocks`, updates);

            expect(await blockGraph.hasBlock(`blocks`, block._id)).toBe(true);
            expect(await blockGraph.hasBlock(`blocks`, 'non-existent')).toBe(false);
        });
    });

    describe('head block management', () => {
        test('should get head blocks', async () => {

            const updates: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: Date.now(),
                    collection: 'test',
                    _id: uuid(),
                    document: { value: 1 },
                },
            ];

            const block = await blockGraph.commitBlock(`blocks`, updates);
            const headBlocks = await blockGraph.getHeadBlocks(`blocks`);

            expect(headBlocks).toHaveLength(1);
            expect(headBlocks[0]).toEqual(block);
        });

        test('should handle empty head blocks list', async () => {
            const headBlocks = await blockGraph.getHeadBlocks(`blocks`);
            expect(headBlocks).toEqual([]);
        });
    });

    describe('block integration', () => {
        test('should integrate external block', async () => {

            // Create an external block (simulating from another node)
            const externalBlock: IBlock<DatabaseUpdate> = {
                _id: uuid(),
                prevBlocks: [],
                data: [
                    {
                        type: 'upsert',
                        timestamp: Date.now(),
                        collection: 'external',
                        _id: uuid(),
                        document: { source: 'external' },
                    },
                ]
            };

            await blockGraph.integrateBlock(`blocks`, externalBlock);

            // Should be able to retrieve the block
            const retrievedBlock = await blockGraph.getBlock(`blocks`, externalBlock._id);
            expect(retrievedBlock).toEqual(externalBlock);

            // Should be added to head blocks
            const headBlockIds = await blockGraph.getHeadBlockIds();
            expect(headBlockIds).toContain(externalBlock._id);
        });

        test('should handle block integration with predecessors', async () => {

            // Create first block locally
            const updates1: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: Date.now(),
                    collection: 'test',
                    _id: uuid(),
                    document: { version: 1 },
                },
            ];
            const block1 = await blockGraph.commitBlock(`blocks`, updates1);

            // Create external block that references first block
            const externalBlock: IBlock<DatabaseUpdate> = {
                _id: 'external-block-id',
                prevBlocks: [block1._id],
                data: [
                    {
                        type: 'field',
                        timestamp: Date.now(),
                        collection: 'test',
                        _id: uuid(),
                        field: 'version',
                        value: 2,
                    },
                ]
            };

            await blockGraph.integrateBlock(`blocks`, externalBlock);

            // First block should no longer be a head (it has a successor)
            // External block should be the new head
            const headBlockIds = await blockGraph.getHeadBlockIds();
            expect(headBlockIds).toEqual([externalBlock._id]);
            expect(headBlockIds).not.toContain(block1._id);
        });
    });

    describe('persistence', () => {
        test('should persist blocks to correct paths', async () => {

            const updates: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: Date.now(),
                    collection: 'test',
                    _id: uuid(),
                    document: { persisted: true },
                },
            ];

            const block = await blockGraph.commitBlock(`blocks`, updates);

            // Check that block file exists at expected path (no extension in current implementation)
            const blockPath = `blocks/${block._id}`;
            expect(await storage.fileExists(blockPath)).toBe(true);

            // Check block content (binary format, so just verify it exists and has content)
            const blockContent = await storage.read(blockPath);
            expect(blockContent).toBeDefined();
            expect(blockContent!.length).toBeGreaterThan(0);
        });

        test('should persist head blocks to correct path', async () => {

            const updates: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: Date.now(),
                    collection: 'test',
                    _id: uuid(),
                    document: { test: true },
                },
            ];

            const block = await blockGraph.commitBlock(`blocks`, updates);

            // Check that head blocks file exists
            const headBlocksPath = 'head-blocks.json';
            expect(await metadataStorage.fileExists(headBlocksPath)).toBe(true);

            // Check head blocks content
            const headBlocksContent = await getFileContents(headBlocksPath);
            expect(headBlocksContent).toBeDefined();
            const parsedHeadBlocks = JSON.parse(headBlocksContent!);
            expect(parsedHeadBlocks.headBlockIds).toEqual([block._id]);
        });
    });

    describe('multiple database update types', () => {
        test('should handle field updates', async () => {

            const fieldUpdate: IFieldUpdate = {
                type: 'field',
                timestamp: Date.now(),
                collection: 'users',
                _id: 'user1',
                field: 'name',
                value: 'John Doe'
            };

            const block = await blockGraph.commitBlock(`blocks`, [fieldUpdate]);
            expect(block.data[0]).toEqual(fieldUpdate);
        });

        test('should handle upsert updates', async () => {

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

            const block = await blockGraph.commitBlock(`blocks`, [upsertUpdate]);
            expect(block.data[0]).toEqual(upsertUpdate);
        });

        test('should handle delete updates', async () => {

            const deleteUpdate: IDeleteUpdate = {
                type: 'delete',
                timestamp: Date.now(),
                collection: 'temp',
                _id: 'temp1'
            };

            const block = await blockGraph.commitBlock(`blocks`, [deleteUpdate]);
            expect(block.data[0]).toEqual(deleteUpdate);
        });

        test('should handle mixed update types in single block', async () => {

            const mixedUpdates: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: Date.now(),
                    collection: 'users',
                    _id: uuid(),
                    document: { name: 'Jane', email: 'jane@example.com' },
                },
                {
                    type: 'field',
                    timestamp: Date.now(),
                    collection: 'users',
                    _id: uuid(),
                    field: 'active',
                    value: false,
                },
                {
                    type: 'delete',
                    timestamp: Date.now(),
                    collection: 'users',
                    _id: uuid(),
                }
            ];

            const block = await blockGraph.commitBlock(`blocks`, mixedUpdates);
            expect(block.data).toEqual(mixedUpdates);
            expect(block.data).toHaveLength(3);
        });
    });

    describe('error handling', () => {
        test('should throw error on storage errors', async () => {
            // Create a new MockStorage instance and override methods to throw errors
            const errorStorage = new MockStorage();
            const errorMetadataStorage = new MockStorage();
            const originalRead = errorMetadataStorage.read.bind(errorMetadataStorage);
            errorMetadataStorage.read = async () => { throw new Error('Storage error'); };

            const errorBlockGraph = new BlockGraph<DatabaseUpdate>(errorStorage, errorMetadataStorage);
            
            // Should throw storage error
            await expect(errorBlockGraph.getHeadBlockIds()).rejects.toThrow('Storage error');
        });
    });
});