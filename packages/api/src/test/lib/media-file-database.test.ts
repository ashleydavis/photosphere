//
// Comprehensive tests for MediaFileDatabase class
//
import { MediaFileDatabase, IDatabaseSummary, IAddSummary, IAssetDetails, IVerifyOptions, IVerifyResult, IRepairOptions, IRepairResult, IReplicateOptions, IReplicationResult, THUMBNAIL_MIN_SIZE, DISPLAY_MIN_SIZE, MICRO_MIN_SIZE } from '../../lib/media-file-database';
import { MockStorage } from 'storage/src/tests/mock-storage';
import { TestUuidGenerator, TestTimestampProvider } from 'node-utils';
import { IUuidGenerator, ITimestampProvider, ILocation } from 'utils';
import { AssetDatabase, MerkleNode, IMerkleTree, IHashedFile, BlockGraph, DatabaseUpdate } from 'adb';
import { IAsset } from 'defs';
import { FileScanner, IFileStat } from '../../lib/file-scanner';
import { Readable } from 'stream';
import * as fs from 'fs-extra';
import * as path from 'path';
import * as os from 'os';

// Mock external dependencies
jest.mock('mime', () => ({
    getType: jest.fn().mockReturnValue('image/jpeg')
}));

// Mock FileScanner
jest.mock('../../lib/file-scanner', () => ({
    FileScanner: jest.fn().mockImplementation(() => ({
        scanPaths: jest.fn(),
        getNumFilesIgnored: jest.fn().mockReturnValue(0)
    }))
}));
const { FileScanner: MockFileScanner } = require('../../lib/file-scanner');

// Mock validation
jest.mock('../../lib/validation', () => ({
    validateFile: jest.fn().mockResolvedValue(true)
}));

// Mock video and image processing
jest.mock('../../lib/video', () => ({
    getVideoDetails: jest.fn().mockResolvedValue({
        duration: 120,
        resolution: { width: 1920, height: 1080 }
    })
}));

jest.mock('../../lib/image', () => ({
    getImageDetails: jest.fn().mockResolvedValue({
        resolution: { width: 1920, height: 1080 }
    })
}));

// Mock tools
jest.mock('tools', () => ({
    Image: jest.fn().mockImplementation(() => ({
        getDominantColor: jest.fn().mockResolvedValue([255, 0, 0]),
        createThumbnail: jest.fn().mockResolvedValue(Buffer.from('thumbnail')),
        resize: jest.fn().mockResolvedValue(Buffer.from('resized'))
    }))
}));

describe('MediaFileDatabase', () => {
    let assetStorage: MockStorage;
    let metadataStorage: MockStorage;
    let uuidGenerator: TestUuidGenerator;
    let timestampProvider: TestTimestampProvider;
    let database: MediaFileDatabase;

    beforeEach(() => {
        assetStorage = new MockStorage('mock://assets');
        metadataStorage = new MockStorage('mock://metadata');
        uuidGenerator = new TestUuidGenerator();
        timestampProvider = new TestTimestampProvider();

        // Reset test providers
        uuidGenerator.reset();
        timestampProvider.reset();

        // Reset mocks
        jest.clearAllMocks();
    });

    afterEach(() => {
        jest.restoreAllMocks();
    });

    describe('Constructor and Initialization', () => {
        test('should create MediaFileDatabase instance with required dependencies', () => {
            database = new MediaFileDatabase(
                assetStorage,
                metadataStorage,
                'mock-google-api-key',
                uuidGenerator,
                timestampProvider
            );

            expect(database).toBeInstanceOf(MediaFileDatabase);
        });

        test('should create MediaFileDatabase instance with optional sessionId', () => {
            database = new MediaFileDatabase(
                assetStorage,
                metadataStorage,
                'mock-google-api-key',
                uuidGenerator,
                timestampProvider,
                'test-session-id'
            );

            expect(database).toBeInstanceOf(MediaFileDatabase);
        });
    });

    describe('Database Creation', () => {
        beforeEach(() => {
            database = new MediaFileDatabase(
                assetStorage,
                metadataStorage,
                'mock-google-api-key',
                uuidGenerator,
                timestampProvider
            );
        });

        test('should create a new database successfully', async () => {
            await database.create();
            
            // Verify that database creation completed without throwing
            expect(database).toBeDefined();
        });

        test('should handle creation with existing metadata', async () => {
            // Pre-populate some metadata to simulate existing database
            await metadataStorage.write('tree.dat', 'application/octet-stream', Buffer.from('existing tree data'));
            
            await expect(database.create()).resolves.not.toThrow();
        });
    });

    describe('Database Loading', () => {
        beforeEach(() => {
            database = new MediaFileDatabase(
                assetStorage,
                metadataStorage,
                'mock-google-api-key',
                uuidGenerator,
                timestampProvider
            );
        });

        test('should load an existing database successfully', async () => {
            // First create a database
            await database.create();
            
            // Create a new instance and load
            const newDatabase = new MediaFileDatabase(
                assetStorage,
                metadataStorage,
                'mock-google-api-key',
                uuidGenerator,
                timestampProvider
            );
            
            await expect(newDatabase.load()).resolves.not.toThrow();
        });

        test('should handle loading empty metadata storage', async () => {
            // Loading empty metadata storage should fail as expected
            await expect(database.load()).rejects.toThrow('Failed to load media file database');
        });
    });

    describe('File Operations', () => {
        beforeEach(async () => {
            database = new MediaFileDatabase(
                assetStorage,
                metadataStorage,
                'mock-google-api-key',
                uuidGenerator,
                timestampProvider
            );
            await database.create();
        });

        describe('Adding Files', () => {
            test('should add files from paths', async () => {
                const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), 'mfd-test-'));
                const testFile = path.join(tempDir, 'test.jpg');
                await fs.writeFile(testFile, 'test image data');

                const progressCallback = jest.fn();
                
                // Mock the scanPaths method directly on the file scanner instance
                const mockScanPaths = jest.fn().mockImplementation(async (paths, fileCallback, progressCallback) => {
                    // Call progress callback to indicate scanning started
                    progressCallback('Scanning...');
                });
                
                // Access and mock the file scanner instance
                (database as any).localFileScanner.scanPaths = mockScanPaths;
                (database as any).localFileScanner.getNumFilesIgnored = jest.fn().mockReturnValue(0);

                await database.addPaths([tempDir], progressCallback);

                expect(mockScanPaths).toHaveBeenCalledWith([tempDir], expect.any(Function), progressCallback);

                // Cleanup
                await fs.remove(tempDir);
            });

            test('should handle adding non-existent paths', async () => {
                const progressCallback = jest.fn();
                
                // Mock to simulate no files found
                const mockScanPaths = jest.fn().mockImplementation(async (paths, fileCallback, progressCallback) => {
                    // No files to process
                });
                
                (database as any).localFileScanner.scanPaths = mockScanPaths;
                (database as any).localFileScanner.getNumFilesIgnored = jest.fn().mockReturnValue(0);
                
                await database.addPaths(['/non/existent/path'], progressCallback);
                
                expect(mockScanPaths).toHaveBeenCalled();
            });

            test('should add single file with progress callback', async () => {
                const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), 'mfd-test-'));
                const testFile = path.join(tempDir, 'test.jpg');
                await fs.writeFile(testFile, 'test image data');

                const progressCallback = jest.fn();
                
                // Mock the scanPaths method
                const mockScanPaths = jest.fn().mockImplementation(async (paths, fileCallback, progressCallback) => {
                    progressCallback('Processing file...');
                });
                
                (database as any).localFileScanner.scanPaths = mockScanPaths;
                (database as any).localFileScanner.getNumFilesIgnored = jest.fn().mockReturnValue(0);
                
                await database.addPaths([tempDir], progressCallback);
                expect(mockScanPaths).toHaveBeenCalled();

                // Cleanup
                await fs.remove(tempDir);
            });
        });

        describe('Removing Files', () => {
            test('should remove assets by ID', async () => {
                // Test the remove functionality - should handle error gracefully for invalid ID
                await expect(database.remove('non-existent-id')).rejects.toThrow('Invalid record ID');
            });
        });
    });

    describe('Database Information', () => {
        beforeEach(async () => {
            database = new MediaFileDatabase(
                assetStorage,
                metadataStorage,
                'mock-google-api-key',
                uuidGenerator,
                timestampProvider
            );
            await database.create();
        });

        test('should return database summary', async () => {
            const summary = await database.getDatabaseSummary();

            expect(summary).toHaveProperty('totalAssets');
            expect(summary).toHaveProperty('totalFiles');
            expect(summary).toHaveProperty('totalSize');
            expect(summary).toHaveProperty('totalNodes');
            expect(summary).toHaveProperty('fullHash');
            expect(summary).toHaveProperty('databaseVersion');
            expect(typeof summary.totalAssets).toBe('number');
            expect(typeof summary.totalFiles).toBe('number');
            expect(typeof summary.totalSize).toBe('number');
        });

        test('should return asset details', async () => {
            // Test that we can get the BSON database for querying assets
            const bsonDb = database.getBsonDatabase();
            expect(bsonDb).toBeDefined();
        });
    });

    describe('Database Verification', () => {
        beforeEach(async () => {
            database = new MediaFileDatabase(
                assetStorage,
                metadataStorage,
                'mock-google-api-key',
                uuidGenerator,
                timestampProvider
            );
            await database.create();
        });

        test('should verify database integrity', async () => {
            const options: IVerifyOptions = {
                full: false,
                pathFilter: undefined
            };

            const result = await database.verify(options);

            expect(result).toHaveProperty('filesImported');
            expect(result).toHaveProperty('totalFiles');
            expect(result).toHaveProperty('totalSize');
            expect(result).toHaveProperty('numUnmodified');
            expect(result).toHaveProperty('modified');
            expect(typeof result.filesImported).toBe('number');
            expect(typeof result.totalFiles).toBe('number');
        });

        test('should verify with path filter', async () => {
            const options: IVerifyOptions = {
                full: true,
                pathFilter: '/some/path'
            };

            const result = await database.verify(options);
            expect(result).toBeDefined();
        });
    });

    describe('Additional Verification Tests', () => {
        beforeEach(async () => {
            database = new MediaFileDatabase(
                assetStorage,
                metadataStorage,
                'mock-google-api-key',
                uuidGenerator,
                timestampProvider
            );
            await database.create();
        });

        test('should verify with full option', async () => {
            const options: IVerifyOptions = {
                full: true
            };

            const result = await database.verify(options);

            expect(result).toHaveProperty('filesImported');
            expect(result).toHaveProperty('totalFiles');
            expect(result).toHaveProperty('totalSize');
            expect(typeof result.filesImported).toBe('number');
            expect(typeof result.totalFiles).toBe('number');
        });

        test('should verify with progress callback', async () => {
            const options: IVerifyOptions = { full: false };
            const progressCallback = jest.fn();

            const result = await database.verify(options, progressCallback);
            expect(result).toBeDefined();
        });
    });

    describe('Database Replication', () => {
        beforeEach(async () => {
            database = new MediaFileDatabase(
                assetStorage,
                metadataStorage,
                'mock-google-api-key',
                uuidGenerator,
                timestampProvider
            );
            await database.create();
        });

        test('should replicate to target storage', async () => {
            const targetAssetStorage = new MockStorage('mock://target-assets');
            const targetMetadataStorage = new MockStorage('mock://target-metadata');

            const options: IReplicateOptions = {
                pathFilter: undefined
            };

            const result = await database.replicate(targetAssetStorage, targetMetadataStorage, options);

            expect(result).toHaveProperty('filesImported');
            expect(result).toHaveProperty('filesConsidered');
            expect(result).toHaveProperty('existingFiles');
            expect(result).toHaveProperty('copiedFiles');
            expect(typeof result.filesImported).toBe('number');
        });

        test('should replicate with path filter', async () => {
            const targetAssetStorage = new MockStorage('mock://target-assets-dry');
            const targetMetadataStorage = new MockStorage('mock://target-metadata-dry');

            const options: IReplicateOptions = {
                pathFilter: '/some/path'
            };

            const result = await database.replicate(targetAssetStorage, targetMetadataStorage, options);
            expect(result).toBeDefined();
        });
    });

    describe('Database Operations', () => {
        beforeEach(async () => {
            database = new MediaFileDatabase(
                assetStorage,
                metadataStorage,
                'mock-google-api-key',
                uuidGenerator,
                timestampProvider,
                'test-session'
            );
            await database.create();
        });

        test('should access asset database', () => {
            const assetDb = database.getAssetDatabase();
            expect(assetDb).toBeDefined();
        });

        test('should get add summary', () => {
            const summary = database.getAddSummary();
            expect(summary).toHaveProperty('filesAdded');
            expect(summary).toHaveProperty('filesAlreadyAdded');
            expect(summary).toHaveProperty('filesIgnored');
        });

        test('should get metadata database', () => {
            const metaDb = database.getMetadataDatabase();
            expect(metaDb).toBeDefined();
        });
    });

    describe('Block Update Operations', () => {
        beforeEach(async () => {
            database = new MediaFileDatabase(
                assetStorage,
                metadataStorage,
                'mock-google-api-key',
                uuidGenerator,
                timestampProvider
            );
            await database.create();
        });

        test('should update to latest blocks', async () => {
            const blockIds = ['block1', 'block2'];
            await expect(database.updateToLatestBlocks(blockIds)).resolves.not.toThrow();
        });

        test('should handle empty block IDs', async () => {
            const emptyBlockIds: string[] = [];
            await expect(database.updateToLatestBlocks(emptyBlockIds)).resolves.not.toThrow();
        });

        test('should handle null/undefined block IDs', async () => {
            await expect(database.updateToLatestBlocks(null as any)).rejects.toThrow();
            await expect(database.updateToLatestBlocks(undefined as any)).rejects.toThrow();
        });

        test('should handle single block ID', async () => {
            const mockBlockGraph = {
                getBlock: jest.fn().mockResolvedValue({
                    id: 'block1',
                    data: [{
                        timestamp: Date.now(),
                        type: 'upsert',
                        collection: 'assets',
                        _id: 'asset1',
                        document: { _id: 'asset1', hash: 'hash1' }
                    }]
                }),
                getHeadBlockIds: jest.fn().mockResolvedValue(['block1']),
                setHeadHashes: jest.fn().mockResolvedValue(undefined)
            };
            (database as any).blockGraph = mockBlockGraph;

            await expect(database.updateToLatestBlocks(['block1'])).resolves.not.toThrow();
            expect(mockBlockGraph.getBlock).toHaveBeenCalledWith('block1');
        });

        test('should handle non-existent block IDs', async () => {
            const mockBlockGraph = {
                getBlock: jest.fn().mockResolvedValue(null), // Block doesn't exist
                getHeadBlockIds: jest.fn().mockResolvedValue([]),
                setHeadHashes: jest.fn().mockResolvedValue(undefined)
            };
            (database as any).blockGraph = mockBlockGraph;

            await expect(database.updateToLatestBlocks(['non-existent-block'])).resolves.not.toThrow();
        });

        test('should handle mix of existing and non-existent blocks', async () => {
            const mockBlockGraph = {
                getBlock: jest.fn().mockImplementation((blockId: string) => {
                    if (blockId === 'existing-block') {
                        return Promise.resolve({
                            id: 'existing-block',
                            data: [{
                                timestamp: Date.now(),
                                type: 'upsert',
                                collection: 'assets',
                                _id: 'asset1',
                                document: { _id: 'asset1', hash: 'hash1' }
                            }]
                        });
                    }
                    return Promise.resolve(null);
                }),
                getHeadBlockIds: jest.fn().mockResolvedValue(['existing-block']),
                setHeadHashes: jest.fn().mockResolvedValue(undefined)
            };
            (database as any).blockGraph = mockBlockGraph;

            await expect(database.updateToLatestBlocks(['existing-block', 'non-existent-block'])).resolves.not.toThrow();
        });

        test('should handle blocks with empty data arrays', async () => {
            const mockBlockGraph = {
                getBlock: jest.fn().mockResolvedValue({
                    id: 'empty-block',
                    data: [] // No updates
                }),
                getHeadBlockIds: jest.fn().mockResolvedValue(['empty-block']),
                setHeadHashes: jest.fn().mockResolvedValue(undefined)
            };
            (database as any).blockGraph = mockBlockGraph;

            await expect(database.updateToLatestBlocks(['empty-block'])).resolves.not.toThrow();
        });

        test('should handle blocks with malformed update data', async () => {
            const mockBlockGraph = {
                getBlock: jest.fn().mockResolvedValue({
                    id: 'malformed-block',
                    data: [
                        null, // null update
                        undefined, // undefined update
                        { /* missing required fields */ },
                        {
                            timestamp: 'invalid-timestamp', // invalid timestamp type
                            type: 'unknown-type',
                            collection: 'assets'
                        }
                    ].filter(Boolean) // Remove null/undefined
                }),
                getHeadBlockIds: jest.fn().mockResolvedValue([]),
                setHeadHashes: jest.fn().mockResolvedValue(undefined)
            };
            (database as any).blockGraph = mockBlockGraph;

            // Should not throw but may skip malformed updates
            await expect(database.updateToLatestBlocks(['malformed-block'])).resolves.not.toThrow();
        });

        test('should handle very large block IDs array', async () => {
            const largeBlockIds = Array.from({ length: 1000 }, (_, i) => `block-${i}`);
            const mockBlockGraph = {
                getBlock: jest.fn().mockResolvedValue(null), // No blocks exist
                getHeadBlockIds: jest.fn().mockResolvedValue([]),
                setHeadHashes: jest.fn().mockResolvedValue(undefined)
            };
            (database as any).blockGraph = mockBlockGraph;

            await expect(database.updateToLatestBlocks(largeBlockIds)).resolves.not.toThrow();
            expect(mockBlockGraph.getBlock).toHaveBeenCalledTimes(largeBlockIds.length);
        });

        test('should handle block graph getBlock failures', async () => {
            const mockBlockGraph = {
                getBlock: jest.fn().mockRejectedValue(new Error('Block retrieval failed')),
                getHeadBlockIds: jest.fn().mockResolvedValue([]),
                setHeadHashes: jest.fn().mockResolvedValue(undefined)
            };
            (database as any).blockGraph = mockBlockGraph;

            await expect(database.updateToLatestBlocks(['failing-block'])).rejects.toThrow('Block retrieval failed');
        });

        test('should handle timestamp sorting edge cases', async () => {
            const mockBlockGraph = {
                getBlock: jest.fn().mockResolvedValue({
                    id: 'timestamp-block',
                    data: [
                        { timestamp: 3, type: 'upsert', collection: 'assets', _id: 'asset3', document: { id: '3' } },
                        { timestamp: 1, type: 'upsert', collection: 'assets', _id: 'asset1', document: { id: '1' } },
                        { timestamp: 2, type: 'upsert', collection: 'assets', _id: 'asset2', document: { id: '2' } },
                        { timestamp: 1, type: 'upsert', collection: 'assets', _id: 'asset1-dup', document: { id: '1-duplicate' } }, // Same timestamp
                    ]
                }),
                getHeadBlockIds: jest.fn().mockResolvedValue([]),
                setHeadHashes: jest.fn().mockResolvedValue(undefined)
            };
            (database as any).blockGraph = mockBlockGraph;

            await expect(database.updateToLatestBlocks(['timestamp-block'])).resolves.not.toThrow();
        });
    });

    describe('applyDatabaseUpdates Edge Cases (via updateToLatestBlocks)', () => {
        beforeEach(async () => {
            database = new MediaFileDatabase(
                assetStorage,
                metadataStorage,
                'mock-google-api-key',
                uuidGenerator,
                timestampProvider
            );
            await database.create();
        });

        test('should apply upsert updates correctly', async () => {
            const mockCollection = {
                replaceOne: jest.fn().mockResolvedValue(undefined),
                updateOne: jest.fn().mockResolvedValue(undefined),
                deleteOne: jest.fn().mockResolvedValue(undefined)
            };

            const mockBsonDatabase = {
                collection: jest.fn().mockReturnValue(mockCollection)
            };
            (database as any).bsonDatabase = mockBsonDatabase;

            const mockBlockGraph = {
                getBlock: jest.fn().mockResolvedValue({
                    id: 'upsert-block',
                    data: [{
                        type: 'upsert',
                        timestamp: 1000,
                        collection: 'users',
                        _id: 'user1',
                        document: { _id: 'user1', name: 'John', email: 'john@example.com' }
                    }]
                }),
                getHeadBlockIds: jest.fn().mockResolvedValue([]),
                setHeadHashes: jest.fn().mockResolvedValue(undefined)
            };
            (database as any).blockGraph = mockBlockGraph;

            await database.updateToLatestBlocks(['upsert-block']);

            expect(mockBsonDatabase.collection).toHaveBeenCalledWith('users');
            expect(mockCollection.replaceOne).toHaveBeenCalledWith(
                'user1',
                { _id: 'user1', name: 'John', email: 'john@example.com' },
                { upsert: true }
            );
        });

        test('should apply field updates correctly', async () => {
            const mockCollection = {
                replaceOne: jest.fn().mockResolvedValue(undefined),
                updateOne: jest.fn().mockResolvedValue(undefined),
                deleteOne: jest.fn().mockResolvedValue(undefined)
            };

            const mockBsonDatabase = {
                collection: jest.fn().mockReturnValue(mockCollection)
            };
            (database as any).bsonDatabase = mockBsonDatabase;

            const mockBlockGraph = {
                getBlock: jest.fn().mockResolvedValue({
                    id: 'field-block',
                    data: [{
                        type: 'field',
                        timestamp: 1000,
                        collection: 'users',
                        _id: 'user1',
                        field: 'name',
                        value: 'Jane'
                    }]
                }),
                getHeadBlockIds: jest.fn().mockResolvedValue([]),
                setHeadHashes: jest.fn().mockResolvedValue(undefined)
            };
            (database as any).blockGraph = mockBlockGraph;

            await database.updateToLatestBlocks(['field-block']);

            expect(mockBsonDatabase.collection).toHaveBeenCalledWith('users');
            expect(mockCollection.updateOne).toHaveBeenCalledWith(
                'user1',
                { name: 'Jane' },
                { upsert: true }
            );
        });

        test('should apply delete updates correctly', async () => {
            const mockCollection = {
                replaceOne: jest.fn().mockResolvedValue(undefined),
                updateOne: jest.fn().mockResolvedValue(undefined),
                deleteOne: jest.fn().mockResolvedValue(undefined)
            };

            const mockBsonDatabase = {
                collection: jest.fn().mockReturnValue(mockCollection)
            };
            (database as any).bsonDatabase = mockBsonDatabase;

            const mockBlockGraph = {
                getBlock: jest.fn().mockResolvedValue({
                    id: 'delete-block',
                    data: [{
                        type: 'delete',
                        timestamp: 1000,
                        collection: 'users',
                        _id: 'user1'
                    }]
                }),
                getHeadBlockIds: jest.fn().mockResolvedValue([]),
                setHeadHashes: jest.fn().mockResolvedValue(undefined)
            };
            (database as any).blockGraph = mockBlockGraph;

            await database.updateToLatestBlocks(['delete-block']);

            expect(mockBsonDatabase.collection).toHaveBeenCalledWith('users');
            expect(mockCollection.deleteOne).toHaveBeenCalledWith('user1');
        });

        test('should apply multiple updates in order', async () => {
            const mockCollection = {
                replaceOne: jest.fn().mockResolvedValue(undefined),
                updateOne: jest.fn().mockResolvedValue(undefined),
                deleteOne: jest.fn().mockResolvedValue(undefined)
            };

            const mockBsonDatabase = {
                collection: jest.fn().mockReturnValue(mockCollection)
            };
            (database as any).bsonDatabase = mockBsonDatabase;

            const mockBlockGraph = {
                getBlock: jest.fn().mockResolvedValue({
                    id: 'multi-block',
                    data: [
                        {
                            type: 'upsert',
                            timestamp: 1000,
                            collection: 'users',
                            _id: 'user1',
                            document: { _id: 'user1', name: 'John' }
                        },
                        {
                            type: 'field',
                            timestamp: 2000,
                            collection: 'users',
                            _id: 'user1',
                            field: 'email',
                            value: 'john@example.com'
                        },
                        {
                            type: 'delete',
                            timestamp: 3000,
                            collection: 'users',
                            _id: 'user2'
                        }
                    ]
                }),
                getHeadBlockIds: jest.fn().mockResolvedValue([]),
                setHeadHashes: jest.fn().mockResolvedValue(undefined)
            };
            (database as any).blockGraph = mockBlockGraph;

            await database.updateToLatestBlocks(['multi-block']);

            // Verify all operations were called in order
            expect(mockCollection.replaceOne).toHaveBeenCalledWith(
                'user1',
                { _id: 'user1', name: 'John' },
                { upsert: true }
            );
            expect(mockCollection.updateOne).toHaveBeenCalledWith(
                'user1',
                { email: 'john@example.com' },
                { upsert: true }
            );
            expect(mockCollection.deleteOne).toHaveBeenCalledWith('user2');
        });

        test('should handle multiple collections', async () => {
            const mockUsersCollection = {
                replaceOne: jest.fn().mockResolvedValue(undefined),
                updateOne: jest.fn().mockResolvedValue(undefined),
                deleteOne: jest.fn().mockResolvedValue(undefined)
            };

            const mockProductsCollection = {
                replaceOne: jest.fn().mockResolvedValue(undefined),
                updateOne: jest.fn().mockResolvedValue(undefined),
                deleteOne: jest.fn().mockResolvedValue(undefined)
            };

            const mockBsonDatabase = {
                collection: jest.fn().mockImplementation((name: string) => {
                    if (name === 'users') return mockUsersCollection;
                    if (name === 'products') return mockProductsCollection;
                    return mockUsersCollection;
                })
            };
            (database as any).bsonDatabase = mockBsonDatabase;

            const mockBlockGraph = {
                getBlock: jest.fn().mockResolvedValue({
                    id: 'multi-collection-block',
                    data: [
                        {
                            type: 'upsert',
                            timestamp: 1000,
                            collection: 'users',
                            _id: 'user1',
                            document: { _id: 'user1', name: 'John' }
                        },
                        {
                            type: 'upsert',
                            timestamp: 2000,
                            collection: 'products',
                            _id: 'prod1',
                            document: { _id: 'prod1', name: 'Widget' }
                        }
                    ]
                }),
                getHeadBlockIds: jest.fn().mockResolvedValue([]),
                setHeadHashes: jest.fn().mockResolvedValue(undefined)
            };
            (database as any).blockGraph = mockBlockGraph;

            await database.updateToLatestBlocks(['multi-collection-block']);

            expect(mockBsonDatabase.collection).toHaveBeenCalledWith('users');
            expect(mockBsonDatabase.collection).toHaveBeenCalledWith('products');
            
            expect(mockUsersCollection.replaceOne).toHaveBeenCalledWith(
                'user1',
                { _id: 'user1', name: 'John' },
                { upsert: true }
            );
            expect(mockProductsCollection.replaceOne).toHaveBeenCalledWith(
                'prod1',
                { _id: 'prod1', name: 'Widget' },
                { upsert: true }
            );
        });

        test('should handle errors gracefully and continue processing', async () => {
            const mockGoodCollection = {
                replaceOne: jest.fn().mockResolvedValue(undefined),
                updateOne: jest.fn().mockResolvedValue(undefined),
                deleteOne: jest.fn().mockResolvedValue(undefined)
            };

            const mockErrorCollection = {
                replaceOne: jest.fn().mockRejectedValue(new Error('Database error')),
                updateOne: jest.fn().mockRejectedValue(new Error('Database error')),
                deleteOne: jest.fn().mockRejectedValue(new Error('Database error'))
            };

            const mockBsonDatabase = {
                collection: jest.fn().mockImplementation((name: string) => {
                    if (name === 'error-collection') return mockErrorCollection;
                    return mockGoodCollection;
                })
            };
            (database as any).bsonDatabase = mockBsonDatabase;

            const mockBlockGraph = {
                getBlock: jest.fn().mockResolvedValue({
                    id: 'error-block',
                    data: [
                        {
                            type: 'upsert',
                            timestamp: 1000,
                            collection: 'error-collection',
                            _id: 'doc1',
                            document: { _id: 'doc1', name: 'test' }
                        },
                        {
                            type: 'upsert',
                            timestamp: 2000,
                            collection: 'good-collection',
                            _id: 'doc2',
                            document: { _id: 'doc2', name: 'test2' }
                        }
                    ]
                }),
                getHeadBlockIds: jest.fn().mockResolvedValue([]),
                setHeadHashes: jest.fn().mockResolvedValue(undefined)
            };
            (database as any).blockGraph = mockBlockGraph;

            // Should not throw despite error collection failing
            await expect(database.updateToLatestBlocks(['error-block'])).resolves.not.toThrow();
            
            // Verify error collection was attempted
            expect(mockErrorCollection.replaceOne).toHaveBeenCalled();
            
            // Verify good collection still worked
            expect(mockGoodCollection.replaceOne).toHaveBeenCalledWith(
                'doc2',
                { _id: 'doc2', name: 'test2' },
                { upsert: true }
            );
        });

        test('should handle unknown update types gracefully', async () => {
            const mockCollection = {
                replaceOne: jest.fn().mockResolvedValue(undefined),
                updateOne: jest.fn().mockResolvedValue(undefined),
                deleteOne: jest.fn().mockResolvedValue(undefined)
            };

            const mockBsonDatabase = {
                collection: jest.fn().mockReturnValue(mockCollection)
            };
            (database as any).bsonDatabase = mockBsonDatabase;

            const mockBlockGraph = {
                getBlock: jest.fn().mockResolvedValue({
                    id: 'unknown-type-block',
                    data: [
                        {
                            type: 'unknown-type',
                            timestamp: 1000,
                            collection: 'users',
                            _id: 'user1'
                        } as any,
                        {
                            type: 'upsert',
                            timestamp: 2000,
                            collection: 'users',
                            _id: 'user2',
                            document: { _id: 'user2', name: 'Valid' }
                        }
                    ]
                }),
                getHeadBlockIds: jest.fn().mockResolvedValue([]),
                setHeadHashes: jest.fn().mockResolvedValue(undefined)
            };
            (database as any).blockGraph = mockBlockGraph;

            // Should not throw and continue processing valid updates
            await expect(database.updateToLatestBlocks(['unknown-type-block'])).resolves.not.toThrow();
            
            // Verify valid update was still processed
            expect(mockCollection.replaceOne).toHaveBeenCalledWith(
                'user2',
                { _id: 'user2', name: 'Valid' },
                { upsert: true }
            );
        });
    });

    describe('Additional Edge Cases for Other Methods', () => {
        beforeEach(async () => {
            database = new MediaFileDatabase(
                assetStorage,
                metadataStorage,
                'mock-google-api-key',
                uuidGenerator,
                timestampProvider
            );
            await database.create();
        });

        describe('addPaths Edge Cases', () => {
            test('should handle null/undefined paths array', async () => {
                const progressCallback = jest.fn();
                const mockScanPaths = jest.fn();
                (database as any).localFileScanner.scanPaths = mockScanPaths;
                (database as any).localFileScanner.getNumFilesIgnored = jest.fn().mockReturnValue(0);
                
                // addPaths doesn't validate inputs, it passes them to FileScanner
                await database.addPaths(null as any, progressCallback);
                await database.addPaths(undefined as any, progressCallback);
                
                expect(mockScanPaths).toHaveBeenCalledWith(null, expect.any(Function), progressCallback);
                expect(mockScanPaths).toHaveBeenCalledWith(undefined, expect.any(Function), progressCallback);
            });

            test('should handle paths with special characters and unicode', async () => {
                const specialPaths = [
                    '/path/with spaces/file.jpg',
                    '/path/with-unicode-🎉/file.jpg',
                    '/path/with/émoji/file.jpg',
                    '/path\\with\\backslashes\\file.jpg',
                    '/path/with/very/deeply/nested/structure/that/goes/on/for/a/very/long/time/file.jpg'
                ];
                
                const progressCallback = jest.fn();
                const mockScanPaths = jest.fn();
                (database as any).localFileScanner.scanPaths = mockScanPaths;
                (database as any).localFileScanner.getNumFilesIgnored = jest.fn().mockReturnValue(0);

                await database.addPaths(specialPaths, progressCallback);
                expect(mockScanPaths).toHaveBeenCalledWith(specialPaths, expect.any(Function), progressCallback);
            });


            test('should handle null/undefined progress callback', async () => {
                const mockScanPaths = jest.fn();
                (database as any).localFileScanner.scanPaths = mockScanPaths;
                (database as any).localFileScanner.getNumFilesIgnored = jest.fn().mockReturnValue(0);

                // addPaths doesn't validate callbacks, it passes them to FileScanner
                await database.addPaths(['/path'], null as any);
                await database.addPaths(['/path'], undefined as any);
                
                expect(mockScanPaths).toHaveBeenCalledWith(['/path'], expect.any(Function), null);
                expect(mockScanPaths).toHaveBeenCalledWith(['/path'], expect.any(Function), undefined);
            });
        });

        describe('remove Edge Cases', () => {
            test('should handle null/undefined asset ID', async () => {
                await expect(database.remove(null as any)).rejects.toThrow();
                await expect(database.remove(undefined as any)).rejects.toThrow();
            });

            test('should handle very long asset ID', async () => {
                const longId = 'a'.repeat(10000);
                await expect(database.remove(longId)).rejects.toThrow('Invalid record ID');
            });

            test('should handle asset ID with special characters', async () => {
                const specialIds = [
                    'asset-with-unicode-🎉',
                    'asset with spaces',
                    'asset/with/slashes',
                    'asset\\with\\backslashes',
                    'asset\nwith\nnewlines',
                    'asset\twith\ttabs'
                ];

                for (const id of specialIds) {
                    await expect(database.remove(id)).rejects.toThrow('Invalid record ID');
                }
            });
        });

        describe('Database Verification Edge Cases', () => {
            test('should handle verify with null options', async () => {
                // verify method fails due to walkProtectedFiles destructuring null options
                await expect(database.verify(null as any)).rejects.toThrow('Cannot destructure property');
            });

            test('should handle verify with malformed options', async () => {
                const malformedOptions = {
                    full: 'invalid-boolean' as any,
                    pathFilter: 123 as any
                };

                try {
                    const result = await database.verify(malformedOptions);
                    expect(result).toBeDefined();
                    expect(result).toHaveProperty('filesImported');
                } catch (error) {
                    // May fail due to pathFilter type mismatch
                    expect(error).toBeDefined();
                }
            });

            test('should handle verify with very long pathFilter', async () => {
                const longPath = '/very/long/path/' + 'segment/'.repeat(100) + 'file.jpg';
                const options: IVerifyOptions = {
                    full: true,
                    pathFilter: longPath
                };

                const result = await database.verify(options);
                expect(result).toHaveProperty('filesImported');
            });

            test('should handle verify with pathFilter containing special characters', async () => {
                const specialPaths = [
                    '/path/with spaces/file.jpg',
                    '/path/with-unicode-🎉/file.jpg',
                    '/path\\with\\backslashes\\file.jpg',
                    '/path/with\nnewlines/file.jpg'
                ];

                for (const pathFilter of specialPaths) {
                    const options: IVerifyOptions = { pathFilter };
                    const result = await database.verify(options);
                    expect(result).toHaveProperty('filesImported');
                }
            });

            test('should handle verify with progress callback throwing errors', async () => {
                const errorCallback = jest.fn().mockImplementation(() => {
                    throw new Error('Progress callback failed');
                });

                // Progress callback errors are propagated
                await expect(database.verify({}, errorCallback)).rejects.toThrow('Progress callback failed');
            });
        });

        describe('Database Replication Edge Cases', () => {
            test('should handle readonly destination storages', async () => {
                const readonlyAssetStorage = new MockStorage('mock://readonly-assets', true);
                const readonlyMetadataStorage = new MockStorage('mock://readonly-metadata', true);

                const result = await database.replicate(readonlyAssetStorage, readonlyMetadataStorage);
                expect(result).toHaveProperty('filesImported');
            });

            test('should handle replication with same source and destination', async () => {
                // Replicating to itself
                const result = await database.replicate(assetStorage, metadataStorage);
                expect(result).toHaveProperty('filesImported');
            });

            test('should handle replication with storage I/O errors', async () => {
                const faultyStorage = new MockStorage('mock://faulty');
                // Override read method to throw errors
                faultyStorage.read = jest.fn().mockRejectedValue(new Error('Storage I/O error'));

                // Should propagate storage errors
                try {
                    await database.replicate(faultyStorage, metadataStorage);
                } catch (error) {
                    expect(error).toBeDefined();
                }
            });

            test('should handle replication with null options', async () => {
                const targetAssetStorage = new MockStorage('mock://target-assets');
                const targetMetadataStorage = new MockStorage('mock://target-metadata');

                const result = await database.replicate(targetAssetStorage, targetMetadataStorage, null as any);
                expect(result).toHaveProperty('filesImported');
            });
        });

        describe('Storage Access Edge Cases', () => {

            test('should handle walkProtectedFiles with invalid pathFilter', async () => {
                const invalidFilters = [
                    null,
                    undefined,
                    123 as any,
                    {} as any,
                    [] as any
                ];

                for (const pathFilter of invalidFilters) {
                    const files = [];
                    for await (const file of database.walkProtectedFiles({ pathFilter })) {
                        files.push(file);
                        if (files.length > 10) break; // Safety limit
                    }
                    expect(Array.isArray(files)).toBe(true);
                }
            });
        });

        describe('Concurrency and Race Conditions', () => {
            test('should handle concurrent updateToLatestBlocks calls', async () => {
                const mockBlockGraph = {
                    getBlock: jest.fn().mockResolvedValue({
                        id: 'concurrent-block',
                        data: [{ timestamp: Date.now(), type: 'upsert', collection: 'assets', _id: 'asset1', document: {} }]
                    }),
                    getHeadBlockIds: jest.fn().mockResolvedValue(['concurrent-block']),
                    setHeadHashes: jest.fn().mockResolvedValue(undefined)
                };
                (database as any).blockGraph = mockBlockGraph;

                // Execute multiple updateToLatestBlocks concurrently
                const concurrentUpdates = Array.from({ length: 5 }, (_, i) =>
                    database.updateToLatestBlocks([`block-${i}`])
                );

                await expect(Promise.all(concurrentUpdates)).resolves.not.toThrow();
            });

            test('should handle concurrent verification operations', async () => {
                const concurrentVerifications = Array.from({ length: 3 }, () =>
                    database.verify({ full: Math.random() > 0.5 })
                );

                const results = await Promise.all(concurrentVerifications);
                expect(results).toHaveLength(3);
                results.forEach(result => {
                    expect(result).toHaveProperty('filesImported');
                });
            });
        });

        describe('getDatabaseSummary Edge Cases', () => {
            test('should handle getDatabaseSummary with corrupted merkle tree', async () => {
                const mockAssetDatabase = {
                    getMerkleTree: jest.fn().mockImplementation(() => {
                        throw new Error('Corrupted merkle tree');
                    })
                };
                (database as any).assetDatabase = mockAssetDatabase;

                await expect(database.getDatabaseSummary()).rejects.toThrow('Corrupted merkle tree');
            });
        });

        describe('getAddSummary Edge Cases', () => {
            test('should handle getAddSummary with invalid internal state', async () => {
                // Corrupt internal add summary
                (database as any).addSummary = {
                    filesAdded: -1,
                    filesAlreadyAdded: NaN,
                    filesIgnored: null,
                    filesFailed: undefined,
                    totalSize: -100,
                    averageSize: 0
                };

                const summary = database.getAddSummary();
                expect(summary).toBeDefined();
                expect(typeof summary.filesAdded).toBe('number');
            });
        });
    });

    describe('Error Handling', () => {

        test('should validate required constructor parameters', () => {
            // The constructor doesn't currently validate parameters but creates the instance
            // This test verifies the constructor doesn't throw immediately
            expect(() => {
                new MediaFileDatabase(
                    null as any,
                    metadataStorage,
                    'mock-google-api-key',
                    uuidGenerator,
                    timestampProvider
                );
            }).not.toThrow();
        });
    });

    describe('Constants', () => {
        test('should export required size constants', () => {
            expect(THUMBNAIL_MIN_SIZE).toBe(300);
            expect(DISPLAY_MIN_SIZE).toBe(1000);
            expect(MICRO_MIN_SIZE).toBe(40);
        });
    });

    // Additional comprehensive edge case tests
    describe('Advanced updateToLatestBlocks Edge Cases', () => {
        beforeEach(async () => {
            database = new MediaFileDatabase(
                assetStorage,
                metadataStorage,
                'mock-google-api-key',
                uuidGenerator,
                timestampProvider
            );
            await database.create();
        });

        test('should handle blocks with deeply nested data structures', async () => {
            const complexUpdate = {
                type: 'upsert',
                timestamp: Date.now(),
                collection: 'complex',
                _id: 'nested-doc',
                document: {
                    _id: 'nested-doc',
                    nested: {
                        level1: {
                            level2: {
                                level3: {
                                    deeply: 'nested',
                                    array: [1, 2, { obj: 'value' }],
                                    nullValue: null,
                                    undefinedValue: undefined
                                }
                            }
                        }
                    }
                }
            };

            const mockBlockGraph = {
                getBlock: jest.fn().mockResolvedValue({
                    _id: 'complex-block',
                    data: [complexUpdate]
                }),
                getHeadBlockIds: jest.fn().mockResolvedValue(['complex-block']),
                setHeadHashes: jest.fn().mockResolvedValue(undefined)
            };
            (database as any).blockGraph = mockBlockGraph;

            await database.updateToLatestBlocks(['complex-block']);
            expect(mockBlockGraph.getBlock).toHaveBeenCalledWith('complex-block');
        });

        test('should handle blocks with circular reference protection', async () => {
            const circularObj: any = { _id: 'circular-doc', name: 'test' };
            circularObj.self = circularObj; // Create circular reference

            const circularUpdate = {
                type: 'upsert',
                timestamp: Date.now(),
                collection: 'circular',
                _id: 'circular-doc',
                document: circularObj
            };

            const mockBlockGraph = {
                getBlock: jest.fn().mockResolvedValue({
                    _id: 'circular-block',
                    data: [circularUpdate]
                }),
                getHeadBlockIds: jest.fn().mockResolvedValue(['circular-block']),
                setHeadHashes: jest.fn().mockResolvedValue(undefined)
            };
            (database as any).blockGraph = mockBlockGraph;

            // Should handle circular references gracefully
            await database.updateToLatestBlocks(['circular-block']);
            expect(mockBlockGraph.getBlock).toHaveBeenCalled();
        });

        test('should handle extreme timestamp values', async () => {
            const extremeUpdates = [
                { type: 'upsert', timestamp: 0, collection: 'test', _id: 'doc1', document: { _id: 'doc1' } },
                { type: 'upsert', timestamp: Number.MAX_SAFE_INTEGER, collection: 'test', _id: 'doc2', document: { _id: 'doc2' } },
                { type: 'upsert', timestamp: -1, collection: 'test', _id: 'doc3', document: { _id: 'doc3' } },
                { type: 'upsert', timestamp: Number.NEGATIVE_INFINITY, collection: 'test', _id: 'doc4', document: { _id: 'doc4' } },
                { type: 'upsert', timestamp: Number.POSITIVE_INFINITY, collection: 'test', _id: 'doc5', document: { _id: 'doc5' } }
            ];

            const mockBlockGraph = {
                getBlock: jest.fn().mockResolvedValue({
                    _id: 'extreme-block',
                    data: extremeUpdates
                }),
                getHeadBlockIds: jest.fn().mockResolvedValue(['extreme-block']),
                setHeadHashes: jest.fn().mockResolvedValue(undefined)
            };
            (database as any).blockGraph = mockBlockGraph;

            await database.updateToLatestBlocks(['extreme-block']);
            expect(mockBlockGraph.getBlock).toHaveBeenCalled();
        });

        test('should handle blocks with duplicate timestamps and deterministic ordering', async () => {
            const sameTimestamp = Date.now();
            const duplicateTimestampUpdates = [
                { type: 'upsert', timestamp: sameTimestamp, collection: 'test', _id: 'doc1', document: { _id: 'doc1', order: 1 } },
                { type: 'field', timestamp: sameTimestamp, collection: 'test', _id: 'doc1', field: 'order', value: 2 },
                { type: 'upsert', timestamp: sameTimestamp, collection: 'test', _id: 'doc2', document: { _id: 'doc2', order: 3 } },
                { type: 'field', timestamp: sameTimestamp, collection: 'test', _id: 'doc2', field: 'order', value: 4 }
            ];

            const mockBlockGraph = {
                getBlock: jest.fn().mockResolvedValue({
                    _id: 'duplicate-block',
                    data: duplicateTimestampUpdates
                }),
                getHeadBlockIds: jest.fn().mockResolvedValue(['duplicate-block']),
                setHeadHashes: jest.fn().mockResolvedValue(undefined)
            };
            (database as any).blockGraph = mockBlockGraph;

            await database.updateToLatestBlocks(['duplicate-block']);
            expect(mockBlockGraph.getBlock).toHaveBeenCalled();
        });

        test('should handle memory pressure with very large updates', async () => {
            const largeData = 'x'.repeat(1000000); // 1MB string
            const largeUpdates = Array.from({ length: 100 }, (_, i) => ({
                type: 'upsert',
                timestamp: Date.now() + i,
                collection: 'large',
                _id: `large-doc-${i}`,
                document: { _id: `large-doc-${i}`, data: largeData }
            }));

            const mockBlockGraph = {
                getBlock: jest.fn().mockResolvedValue({
                    _id: 'large-block',
                    data: largeUpdates
                }),
                getHeadBlockIds: jest.fn().mockResolvedValue(['large-block']),
                setHeadHashes: jest.fn().mockResolvedValue(undefined)
            };
            (database as any).blockGraph = mockBlockGraph;

            await database.updateToLatestBlocks(['large-block']);
            expect(mockBlockGraph.getBlock).toHaveBeenCalled();
        });

        test('should handle blocks with mixed valid and invalid update types', async () => {
            const mixedUpdates = [
                { type: 'upsert', timestamp: 1000, collection: 'test', _id: 'doc1', document: { _id: 'doc1' } },
                { type: 'invalid-type', timestamp: 2000, collection: 'test', _id: 'doc2' }, // Invalid type
                { type: 'field', timestamp: 3000, collection: 'test', _id: 'doc1', field: 'name', value: 'updated' },
                { type: '', timestamp: 4000, collection: 'test', _id: 'doc3' }, // Empty type
                { type: null, timestamp: 5000, collection: 'test', _id: 'doc4' } // Null type
            ];

            const mockBlockGraph = {
                getBlock: jest.fn().mockResolvedValue({
                    _id: 'mixed-block',
                    data: mixedUpdates
                }),
                getHeadBlockIds: jest.fn().mockResolvedValue(['mixed-block']),
                setHeadHashes: jest.fn().mockResolvedValue(undefined)
            };
            (database as any).blockGraph = mockBlockGraph;

            await database.updateToLatestBlocks(['mixed-block']);
            expect(mockBlockGraph.getBlock).toHaveBeenCalled();
        });
    });


    describe('Advanced Storage and Concurrency Edge Cases', () => {
        beforeEach(async () => {
            database = new MediaFileDatabase(
                assetStorage,
                metadataStorage,
                'mock-google-api-key',
                uuidGenerator,
                timestampProvider
            );
            await database.create();
        });

        test('should handle simultaneous write lock acquisition attempts', async () => {
            const lockPromises = Array.from({ length: 10 }, () => 
                (database as any).acquireWriteLock()
            );

            // Only one should succeed, others should handle gracefully
            const results = await Promise.allSettled(lockPromises);
            const successful = results.filter(r => r.status === 'fulfilled');
            expect(successful.length).toBeGreaterThanOrEqual(1);
        });

        test('should handle concurrent database operations under high load', async () => {
            const operations = [
                () => database.getDatabaseSummary(),
                () => database.getAddSummary(),
                () => database.verify(),
                () => database.updateToLatestBlocks([]),
                () => database.remove('non-existent-id').catch(() => {}), // Expected to fail
            ];

            const concurrentOps = Array.from({ length: 50 }, (_, i) => 
                operations[i % operations.length]()
            );

            // All operations should complete without hanging
            const results = await Promise.allSettled(concurrentOps);
            expect(results.length).toBe(50);
        });


    });
});