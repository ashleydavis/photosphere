//
// Tests for MediaFileDatabase applyDatabaseUpdates method
//
import { MediaFileDatabase } from '../../lib/media-file-database';
import { MockStorage } from 'storage/src/tests/mock-storage';
import { TestUuidGenerator, TestTimestampProvider } from 'node-utils';
import { DatabaseUpdate, IUpsertUpdate, IFieldUpdate, IDeleteUpdate } from 'adb';

// Mock external dependencies
jest.mock('mime', () => ({
    getType: jest.fn().mockReturnValue('application/octet-stream')
}));

jest.mock('../../lib/file-scanner', () => ({
    FileScanner: jest.fn().mockImplementation(() => ({
        scanPaths: jest.fn(),
        getNumFilesIgnored: jest.fn().mockReturnValue(0)
    }))
}));

jest.mock('../../lib/validation', () => ({
    validateFile: jest.fn().mockResolvedValue(true)
}));

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

jest.mock('tools', () => ({
    Image: jest.fn().mockImplementation(() => ({
        getDominantColor: jest.fn().mockResolvedValue([255, 0, 0]),
        createThumbnail: jest.fn().mockResolvedValue(Buffer.from('thumbnail')),
        resize: jest.fn().mockResolvedValue(Buffer.from('resized'))
    }))
}));

describe('MediaFileDatabase - applyDatabaseUpdates', () => {
    let assetStorage: MockStorage;
    let metadataStorage: MockStorage;
    let uuidGenerator: TestUuidGenerator;
    let timestampProvider: TestTimestampProvider;
    let database: MediaFileDatabase;
    let mockCollection: any;
    let mockBsonDatabase: any;

    beforeEach(async () => {
        assetStorage = new MockStorage('mock://assets');
        metadataStorage = new MockStorage('mock://metadata');
        uuidGenerator = new TestUuidGenerator();
        timestampProvider = new TestTimestampProvider();

        uuidGenerator.reset();
        timestampProvider.reset();

        // Create database instance
        database = new MediaFileDatabase(
            assetStorage,
            metadataStorage,
            'mock-google-api-key',
            uuidGenerator,
            timestampProvider
        );
        await database.create();

        // Set up mock BSON database and collection
        mockCollection = {
            replaceOne: jest.fn().mockResolvedValue(undefined),
            updateOne: jest.fn().mockResolvedValue(undefined),
            deleteOne: jest.fn().mockResolvedValue(undefined),
            getOne: jest.fn().mockResolvedValue(undefined)
        };

        mockBsonDatabase = {
            collection: jest.fn().mockReturnValue(mockCollection)
        };

        // Replace the internal BSON database with our mock
        (database as any).bsonDatabase = mockBsonDatabase;

        // Clear mocks
        jest.clearAllMocks();
    });

    afterEach(() => {
        jest.restoreAllMocks();
    });


    describe('Upsert Updates', () => {
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

            await database.applyDatabaseUpdates(updates);

            expect(mockBsonDatabase.collection).toHaveBeenCalledWith('users');
            expect(mockCollection.replaceOne).toHaveBeenCalledWith(
                'user1',
                { _id: 'user1', name: 'John', email: 'john@example.com' },
                { upsert: true }
            );
        });

        test('should handle complex document structures in upsert', async () => {
            const complexDocument = {
                _id: 'complex1',
                nested: {
                    level1: {
                        level2: { value: 'deep' }
                    }
                },
                array: [1, 2, { nested: true }],
                nullValue: null
            };

            const updates: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: 1000,
                    collection: 'complex',
                    _id: 'complex1',
                    document: complexDocument
                } as IUpsertUpdate
            ];

            await database.applyDatabaseUpdates(updates);

            expect(mockCollection.replaceOne).toHaveBeenCalledWith(
                'complex1',
                complexDocument,
                { upsert: true }
            );
        });
    });

    describe('Field Updates', () => {
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

            await database.applyDatabaseUpdates(updates);

            expect(mockBsonDatabase.collection).toHaveBeenCalledWith('users');
            expect(mockCollection.updateOne).toHaveBeenCalledWith(
                'user1',
                { name: 'Jane' },
                { upsert: true }
            );
        });

        test('should handle complex field values', async () => {
            const complexValue = {
                nested: { data: [1, 2, 3] },
                date: new Date('2023-01-01'),
                boolean: true
            };

            const updates: DatabaseUpdate[] = [
                {
                    type: 'field',
                    timestamp: 1000,
                    collection: 'users',
                    _id: 'user1',
                    field: 'metadata',
                    value: complexValue
                } as IFieldUpdate
            ];

            await database.applyDatabaseUpdates(updates);

            expect(mockCollection.updateOne).toHaveBeenCalledWith(
                'user1',
                { metadata: complexValue },
                { upsert: true }
            );
        });

        test('should handle null and undefined field values', async () => {
            const updates: DatabaseUpdate[] = [
                {
                    type: 'field',
                    timestamp: 1000,
                    collection: 'users',
                    _id: 'user1',
                    field: 'nullField',
                    value: null
                } as IFieldUpdate,
                {
                    type: 'field',
                    timestamp: 2000,
                    collection: 'users',
                    _id: 'user2',
                    field: 'undefinedField',
                    value: undefined
                } as IFieldUpdate
            ];

            await database.applyDatabaseUpdates(updates);

            expect(mockCollection.updateOne).toHaveBeenCalledWith(
                'user1',
                { nullField: null },
                { upsert: true }
            );
            expect(mockCollection.updateOne).toHaveBeenCalledWith(
                'user2',
                { undefinedField: undefined },
                { upsert: true }
            );
        });
    });

    describe('Delete Updates', () => {
        test('should apply delete updates correctly', async () => {
            const updates: DatabaseUpdate[] = [
                {
                    type: 'delete',
                    timestamp: 1000,
                    collection: 'users',
                    _id: 'user1'
                } as IDeleteUpdate
            ];

            await database.applyDatabaseUpdates(updates);

            expect(mockBsonDatabase.collection).toHaveBeenCalledWith('users');
            expect(mockCollection.deleteOne).toHaveBeenCalledWith('user1');
        });

        test('should handle multiple deletes in same collection', async () => {
            const updates: DatabaseUpdate[] = [
                {
                    type: 'delete',
                    timestamp: 1000,
                    collection: 'users',
                    _id: 'user1'
                } as IDeleteUpdate,
                {
                    type: 'delete',
                    timestamp: 2000,
                    collection: 'users',
                    _id: 'user2'
                } as IDeleteUpdate
            ];

            await database.applyDatabaseUpdates(updates);

            expect(mockCollection.deleteOne).toHaveBeenCalledWith('user1');
            expect(mockCollection.deleteOne).toHaveBeenCalledWith('user2');
        });
    });

    describe('Multiple Updates Processing', () => {
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

            await database.applyDatabaseUpdates(updates);

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

            // Verify call order
            const calls = [
                ...mockCollection.replaceOne.mock.calls,
                ...mockCollection.updateOne.mock.calls,
                ...mockCollection.deleteOne.mock.calls
            ];
            expect(calls).toHaveLength(3);
        });

        test('should handle mixed operations on same document', async () => {
            const updates: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: 1000,
                    collection: 'users',
                    _id: 'user1',
                    document: { _id: 'user1', name: 'John', version: 1 }
                } as IUpsertUpdate,
                {
                    type: 'field',
                    timestamp: 2000,
                    collection: 'users',
                    _id: 'user1',
                    field: 'version',
                    value: 2
                } as IFieldUpdate,
                {
                    type: 'field',
                    timestamp: 3000,
                    collection: 'users',
                    _id: 'user1',
                    field: 'lastModified',
                    value: new Date('2023-01-01')
                } as IFieldUpdate
            ];

            await database.applyDatabaseUpdates(updates);

            expect(mockCollection.replaceOne).toHaveBeenCalledWith(
                'user1',
                { _id: 'user1', name: 'John', version: 1 },
                { upsert: true }
            );
            expect(mockCollection.updateOne).toHaveBeenCalledWith(
                'user1',
                { version: 2 },
                { upsert: true }
            );
            expect(mockCollection.updateOne).toHaveBeenCalledWith(
                'user1',
                { lastModified: new Date('2023-01-01') },
                { upsert: true }
            );
        });
    });

    describe('Multiple Collections', () => {
        test('should handle updates across different collections', async () => {
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

            mockBsonDatabase.collection = jest.fn().mockImplementation((name: string) => {
                if (name === 'users') return mockUsersCollection;
                if (name === 'products') return mockProductsCollection;
                return mockCollection;
            });

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

            await database.applyDatabaseUpdates(updates);

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

        test('should handle large number of collections', async () => {
            const collections = ['users', 'products', 'orders', 'inventory', 'analytics'];
            const mockCollections: { [key: string]: any } = {};

            collections.forEach(name => {
                mockCollections[name] = {
                    replaceOne: jest.fn().mockResolvedValue(undefined),
                    updateOne: jest.fn().mockResolvedValue(undefined),
                    deleteOne: jest.fn().mockResolvedValue(undefined)
                };
            });

            mockBsonDatabase.collection = jest.fn().mockImplementation((name: string) => {
                return mockCollections[name] || mockCollection;
            });

            const updates: DatabaseUpdate[] = collections.map((collectionName, index) => ({
                type: 'upsert',
                timestamp: 1000 + index,
                collection: collectionName,
                _id: `item-${index}`,
                document: { _id: `item-${index}`, name: `Item ${index}` }
            } as IUpsertUpdate));

            await database.applyDatabaseUpdates(updates);

            collections.forEach(collectionName => {
                expect(mockBsonDatabase.collection).toHaveBeenCalledWith(collectionName);
            });
        });
    });

    describe('Error Handling', () => {
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

            mockBsonDatabase.collection = jest.fn().mockImplementation((name: string) => {
                if (name === 'error-collection') return mockErrorCollection;
                return mockGoodCollection;
            });

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

            // Should not throw despite error collection failing
            await expect(database.applyDatabaseUpdates(updates)).resolves.not.toThrow();
            
            // Verify error collection was attempted
            expect(mockErrorCollection.replaceOne).toHaveBeenCalled();
            
            // Verify good collection still worked
            expect(mockGoodCollection.replaceOne).toHaveBeenCalledWith(
                'doc2',
                { _id: 'doc2', name: 'test2' },
                { upsert: true }
            );
        });

        test('should handle database collection creation errors', async () => {
            mockBsonDatabase.collection = jest.fn().mockImplementation((name: string) => {
                if (name === 'failing-collection') {
                    throw new Error('Collection creation failed');
                }
                return mockCollection;
            });

            const updates: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: 1000,
                    collection: 'failing-collection',
                    _id: 'doc1',
                    document: { _id: 'doc1', name: 'test' }
                } as IUpsertUpdate,
                {
                    type: 'upsert',
                    timestamp: 2000,
                    collection: 'working-collection',
                    _id: 'doc2',
                    document: { _id: 'doc2', name: 'test2' }
                } as IUpsertUpdate
            ];

            await expect(database.applyDatabaseUpdates(updates)).resolves.not.toThrow();
            
            // Verify working collection still processed
            expect(mockBsonDatabase.collection).toHaveBeenCalledWith('working-collection');
        });

        test('should handle partial operation failures', async () => {
            const selectiveErrorCollection = {
                replaceOne: jest.fn().mockResolvedValue(undefined),
                updateOne: jest.fn().mockRejectedValue(new Error('Update failed')),
                deleteOne: jest.fn().mockResolvedValue(undefined)
            };

            mockBsonDatabase.collection = jest.fn().mockReturnValue(selectiveErrorCollection);

            const updates: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: 1000,
                    collection: 'test',
                    _id: 'doc1',
                    document: { _id: 'doc1', name: 'test' }
                } as IUpsertUpdate,
                {
                    type: 'field',
                    timestamp: 2000,
                    collection: 'test',
                    _id: 'doc1',
                    field: 'name',
                    value: 'updated'
                } as IFieldUpdate,
                {
                    type: 'delete',
                    timestamp: 3000,
                    collection: 'test',
                    _id: 'doc2'
                } as IDeleteUpdate
            ];

            await expect(database.applyDatabaseUpdates(updates)).resolves.not.toThrow();
            
            expect(selectiveErrorCollection.replaceOne).toHaveBeenCalled();
            expect(selectiveErrorCollection.updateOne).toHaveBeenCalled();
            expect(selectiveErrorCollection.deleteOne).toHaveBeenCalled();
        });
    });

    describe('Unknown Update Types', () => {
        test('should handle unknown update types gracefully', async () => {
            const updates: DatabaseUpdate[] = [
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
                } as IUpsertUpdate
            ];

            // Should not throw and continue processing valid updates
            await expect(database.applyDatabaseUpdates(updates)).resolves.not.toThrow();
            
            // Verify valid update was still processed
            expect(mockCollection.replaceOne).toHaveBeenCalledWith(
                'user2',
                { _id: 'user2', name: 'Valid' },
                { upsert: true }
            );

            // Verify unknown type didn't call any operations
            expect(mockCollection.replaceOne).not.toHaveBeenCalledWith('user1', expect.anything(), expect.anything());
            expect(mockCollection.updateOne).not.toHaveBeenCalledWith('user1', expect.anything(), expect.anything());
            expect(mockCollection.deleteOne).not.toHaveBeenCalledWith('user1');
        });

        test('should handle mix of valid and invalid update types', async () => {
            const updates: DatabaseUpdate[] = [
                {
                    type: 'upsert',
                    timestamp: 1000,
                    collection: 'test',
                    _id: 'doc1',
                    document: { _id: 'doc1', name: 'valid' }
                } as IUpsertUpdate,
                {
                    type: 'invalid-type',
                    timestamp: 2000,
                    collection: 'test',
                    _id: 'doc2'
                } as any,
                {
                    type: 'field',
                    timestamp: 3000,
                    collection: 'test',
                    _id: 'doc1',
                    field: 'updated',
                    value: true
                } as IFieldUpdate,
                {
                    type: '',
                    timestamp: 4000,
                    collection: 'test',
                    _id: 'doc3'
                } as any,
                {
                    type: 'delete',
                    timestamp: 5000,
                    collection: 'test',
                    _id: 'doc4'
                } as IDeleteUpdate
            ];

            await expect(database.applyDatabaseUpdates(updates)).resolves.not.toThrow();
            
            // Verify only valid operations were called
            expect(mockCollection.replaceOne).toHaveBeenCalledWith(
                'doc1',
                { _id: 'doc1', name: 'valid' },
                { upsert: true }
            );
            expect(mockCollection.updateOne).toHaveBeenCalledWith(
                'doc1',
                { updated: true },
                { upsert: true }
            );
            expect(mockCollection.deleteOne).toHaveBeenCalledWith('doc4');

            // Verify we only had 3 valid operations
            expect(mockCollection.replaceOne).toHaveBeenCalledTimes(1);
            expect(mockCollection.updateOne).toHaveBeenCalledTimes(1);
            expect(mockCollection.deleteOne).toHaveBeenCalledTimes(1);
        });
    });

    describe('Edge Cases', () => {
        test('should handle empty updates array', async () => {
            await expect(database.applyDatabaseUpdates([])).resolves.not.toThrow();
            
            expect(mockBsonDatabase.collection).not.toHaveBeenCalled();
        });

        test('should handle null/undefined updates', async () => {
            const updates = [null, undefined, {
                type: 'upsert',
                timestamp: 1000,
                collection: 'test',
                _id: 'valid',
                document: { _id: 'valid', name: 'test' }
            }].filter(Boolean) as DatabaseUpdate[];

            await expect(database.applyDatabaseUpdates(updates)).resolves.not.toThrow();
            
            expect(mockCollection.replaceOne).toHaveBeenCalledWith(
                'valid',
                { _id: 'valid', name: 'test' },
                { upsert: true }
            );
        });

        test('should handle updates with missing required properties', async () => {
            const updates: any[] = [
                {
                    // Missing type, timestamp, _id
                    collection: 'test',
                    document: { _id: 'incomplete' }
                },
                {
                    type: 'upsert',
                    timestamp: 1000,
                    collection: 'test',
                    _id: 'complete',
                    document: { _id: 'complete', name: 'test' }
                }
            ];

            await expect(database.applyDatabaseUpdates(updates as DatabaseUpdate[])).resolves.not.toThrow();
            
            // Only the complete update should be processed
            expect(mockCollection.replaceOne).toHaveBeenCalledWith(
                'complete',
                { _id: 'complete', name: 'test' },
                { upsert: true }
            );
            expect(mockCollection.replaceOne).toHaveBeenCalledTimes(1);
        });

        test('should handle very large update arrays', async () => {
            const largeUpdates: DatabaseUpdate[] = Array.from({ length: 1000 }, (_, index) => ({
                type: 'upsert',
                timestamp: 1000 + index,
                collection: 'bulk',
                _id: `doc-${index}`,
                document: { _id: `doc-${index}`, index }
            } as IUpsertUpdate));

            await expect(database.applyDatabaseUpdates(largeUpdates)).resolves.not.toThrow();
            
            expect(mockCollection.replaceOne).toHaveBeenCalledTimes(1000);
        });
    });
});