import type { ITaskContext } from 'task-queue';
import type { IStorageDescriptor } from 'storage';
import type { IUploadAssetData } from '../../lib/upload-asset.worker';

// ── module mocks ────────────────────────────────────────────────────────────

jest.mock('../../lib/hash', () => ({
    validateAndHash: jest.fn(),
    getHashFromCache: jest.fn(),
    computeAssetHash: jest.fn(),
}));

jest.mock('../../lib/hash-cache', () => ({
    HashCache: jest.fn().mockImplementation(() => ({
        load: jest.fn().mockResolvedValue(undefined),
    })),
}));

jest.mock('storage', () => ({
    createStorage: jest.fn(),
    loadEncryptionKeys: jest.fn().mockResolvedValue({ options: {} }),
}));

jest.mock('../../lib/media-file-database', () => ({
    createMediaFileDatabase: jest.fn(),
}));

jest.mock('../../lib/write-lock', () => ({
    acquireWriteLock: jest.fn().mockResolvedValue(true),
    releaseWriteLock: jest.fn().mockResolvedValue(undefined),
}));

jest.mock('../../lib/tree', () => ({
    loadMerkleTree: jest.fn(),
    saveMerkleTree: jest.fn().mockResolvedValue(undefined),
}));

jest.mock('merkle-tree', () => ({
    addItem: jest.fn((tree: any, _item: any) => tree),
}));

jest.mock('bdb', () => ({
    BsonDatabase: jest.fn(),
}));

jest.mock('../../lib/database-config', () => ({
    updateDatabaseConfig: jest.fn().mockResolvedValue(undefined),
}));

jest.mock('../../lib/image', () => ({
    getImageDetails: jest.fn(),
}));

jest.mock('../../lib/video', () => ({
    getVideoDetails: jest.fn(),
}));

jest.mock('node-utils', () => ({
    ensureDir: jest.fn().mockResolvedValue(undefined),
    remove: jest.fn().mockResolvedValue(undefined),
}));

jest.mock('utils', () => ({
    log: { verbose: jest.fn(), error: jest.fn(), exception: jest.fn(), info: jest.fn() },
    retry: jest.fn((fn: () => any) => fn()),
    swallowError: jest.fn((fn: () => any) => fn()),
    reverseGeocode: jest.fn(),
    ILocation: {},
}));

// ── imports after mocks ─────────────────────────────────────────────────────

import { uploadAssetHandler } from '../../lib/upload-asset.worker';
import { validateAndHash, getHashFromCache } from '../../lib/hash';
import { createStorage, loadEncryptionKeys } from 'storage';
import { createMediaFileDatabase } from '../../lib/media-file-database';
import { acquireWriteLock, releaseWriteLock } from '../../lib/write-lock';
import { loadMerkleTree, saveMerkleTree } from '../../lib/tree';
import { BsonDatabase } from 'bdb';

const mockValidateAndHash = validateAndHash as jest.MockedFunction<typeof validateAndHash>;
const mockGetHashFromCache = getHashFromCache as jest.MockedFunction<typeof getHashFromCache>;
const mockCreateStorage = createStorage as jest.MockedFunction<typeof createStorage>;
const mockCreateMediaFileDatabase = createMediaFileDatabase as jest.MockedFunction<typeof createMediaFileDatabase>;
const mockAcquireWriteLock = acquireWriteLock as jest.MockedFunction<typeof acquireWriteLock>;
const mockReleaseWriteLock = releaseWriteLock as jest.MockedFunction<typeof releaseWriteLock>;
const mockLoadMerkleTree = loadMerkleTree as jest.MockedFunction<typeof loadMerkleTree>;
const mockSaveMerkleTree = saveMerkleTree as jest.MockedFunction<typeof saveMerkleTree>;
const MockBsonDatabase = BsonDatabase as jest.MockedClass<typeof BsonDatabase>;

// ── helpers ─────────────────────────────────────────────────────────────────

//
// Builds a minimal ITaskContext for testing.
//
function makeContext(overrides: Partial<ITaskContext> = {}): ITaskContext {
    return {
        uuidGenerator: { generate: jest.fn().mockReturnValue('test-uuid') },
        timestampProvider: { now: jest.fn().mockReturnValue(Date.now()), dateNow: jest.fn().mockReturnValue(new Date('2024-01-01')) },
        sessionId: 'session-1',
        sendMessage: jest.fn(),
        queueTask: jest.fn(),
        isCancelled: jest.fn().mockReturnValue(false),
        ...overrides,
    };
}

//
// Builds a minimal storage descriptor for testing.
//
function makeStorageDescriptor(): IStorageDescriptor {
    return {
        dbDir: '/test/db',
        encryptionKeyPaths: [],
    };
}

//
// Builds a minimal IUploadAssetData for testing.
//
function makeHashFileData(overrides: Partial<IUploadAssetData> = {}): IUploadAssetData {
    return {
        filePath: '/test/photos/img.jpg',
        fileStat: { length: 1000, lastModified: new Date('2024-01-01') },
        contentType: 'image/jpeg',
        storageDescriptor: makeStorageDescriptor(),
        hashCacheDir: '/tmp/photosphere',
        s3Config: undefined,
        logicalPath: '/test/photos/img.jpg',
        assetId: 'asset-1',
        labels: ['photos'],
        googleApiKey: undefined,
        sessionId: 'session-1',
        dryRun: false,
        ...overrides,
    };
}

//
// A valid hash buffer returned from validateAndHash / getHashFromCache.
//
function makeHashedFile(hexHash = 'aabbcc') {
    const hash = Buffer.from(hexHash, 'hex');
    return { hash, length: 1000, lastModified: new Date('2024-01-01') };
}

//
// Minimal mock for the metadata collection returned by createMediaFileDatabase.
//
function makeMockMetadataCollection(records: any[] = []) {
    const sortIndex = jest.fn().mockReturnValue({
        findByValue: jest.fn().mockResolvedValue(records),
    });
    return { sortIndex };
}

//
// Sets up the createStorage mock to return a minimal storage object.
//
function setupStorageMock() {
    const mockStorage = {
        writeStream: jest.fn().mockResolvedValue(undefined),
        info: jest.fn().mockResolvedValue({ length: 1000, lastModified: new Date() }),
        readStream: jest.fn().mockResolvedValue({}),
        deleteFile: jest.fn().mockResolvedValue(undefined),
    };
    const mockRawStorage = {};
    mockCreateStorage.mockReturnValue({
        storage: mockStorage as any,
        rawStorage: mockRawStorage as any,
        normalizedPath: '/test/db',
        type: 'fs',
    });
    return { mockStorage, mockRawStorage };
}

// ── uploadAssetHandler tests ──────────────────────────────────────────────────

describe('uploadAssetHandler', () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test('sends import-skipped message when file is already in database', async () => {
        const context = makeContext();
        const data = makeHashFileData();
        const hashedFile = makeHashedFile();

        mockGetHashFromCache.mockResolvedValue(null as any);
        mockValidateAndHash.mockResolvedValue(hashedFile as any);
        setupStorageMock();

        const mockMetadataCollection = makeMockMetadataCollection([{ _id: 'existing-asset' }]);
        mockCreateMediaFileDatabase.mockReturnValue({
            metadataCollection: mockMetadataCollection as any,
        } as any);

        await uploadAssetHandler(data, context);

        expect(context.sendMessage).toHaveBeenCalledWith({ type: 'import-pending', assetId: 'asset-1', logicalPath: '/test/photos/img.jpg' });
        expect(context.sendMessage).toHaveBeenCalledWith({ type: 'import-skipped', assetId: 'asset-1', logicalPath: '/test/photos/img.jpg' });
        expect(mockAcquireWriteLock).not.toHaveBeenCalled();
    });

    test('returns early when cancelled', async () => {
        const context = makeContext({ isCancelled: jest.fn().mockReturnValue(true) });
        const data = makeHashFileData();

        await uploadAssetHandler(data, context);

        expect(mockValidateAndHash).not.toHaveBeenCalled();
        expect(mockAcquireWriteLock).not.toHaveBeenCalled();
    });

    test('uses hash from cache when available', async () => {
        const context = makeContext();
        const data = makeHashFileData();
        const cachedHash = makeHashedFile('aabbcc');

        mockGetHashFromCache.mockResolvedValue(cachedHash as any);
        setupStorageMock();

        const mockMetadataCollection = makeMockMetadataCollection([]);
        mockCreateMediaFileDatabase.mockReturnValue({
            metadataCollection: mockMetadataCollection as any,
        } as any);

        const mockMerkleTree = { nodes: [], databaseMetadata: {} };
        mockLoadMerkleTree.mockResolvedValue(mockMerkleTree as any);

        const mockBsonDbInstance = {
            collection: jest.fn().mockReturnValue({
                insertOne: jest.fn().mockResolvedValue(undefined),
                sortIndex: jest.fn().mockReturnValue({
                    findByValue: jest.fn().mockResolvedValue([]),
                }),
            }),
            commit: jest.fn().mockResolvedValue(undefined),
        };
        MockBsonDatabase.mockImplementation(() => mockBsonDbInstance as any);

        const { computeAssetHash } = require('../../lib/hash');
        computeAssetHash.mockResolvedValue({ hash: Buffer.from('aabbcc', 'hex'), length: 1000, lastModified: new Date() });

        await uploadAssetHandler(data, context);

        expect(mockValidateAndHash).not.toHaveBeenCalled();
        expect(context.sendMessage).toHaveBeenCalledWith(expect.objectContaining({ type: 'import-success', assetId: 'asset-1' }));
    });

    test('acquires write lock and writes to database after uploads succeed', async () => {
        const context = makeContext();
        const data = makeHashFileData({ dryRun: false });
        const { mockStorage } = setupStorageMock();

        const hashBuffer = Buffer.from('aabbcc', 'hex');
        const mockComputeHash = { hash: hashBuffer, length: 1000, lastModified: new Date() };
        mockStorage.info.mockResolvedValue({ length: 1000, lastModified: new Date() });

        // Early duplicate check returns no records (file is new)
        mockGetHashFromCache.mockResolvedValue(null as any);
        mockValidateAndHash.mockResolvedValue(makeHashedFile() as any);
        const mockMetadataCollection = makeMockMetadataCollection([]);
        mockCreateMediaFileDatabase.mockReturnValue({
            metadataCollection: mockMetadataCollection as any,
        } as any);

        const mockMerkleTree = { nodes: [], databaseMetadata: {} };
        mockLoadMerkleTree.mockResolvedValue(mockMerkleTree as any);

        const mockBsonDbInstance = {
            collection: jest.fn().mockReturnValue({
                insertOne: jest.fn().mockResolvedValue(undefined),
                sortIndex: jest.fn().mockReturnValue({
                    findByValue: jest.fn().mockResolvedValue([]),
                }),
            }),
            commit: jest.fn().mockResolvedValue(undefined),
        };
        MockBsonDatabase.mockImplementation(() => mockBsonDbInstance as any);

        mockStorage.writeStream.mockResolvedValue(undefined);
        mockStorage.readStream.mockResolvedValue({ pipe: jest.fn() });

        const { computeAssetHash } = require('../../lib/hash');
        computeAssetHash.mockResolvedValue(mockComputeHash);

        await uploadAssetHandler(data, context);

        expect(mockAcquireWriteLock).toHaveBeenCalledWith(expect.anything(), 'session-1', 3);
        expect(mockLoadMerkleTree).toHaveBeenCalled();
        expect(mockSaveMerkleTree).toHaveBeenCalled();
        expect(mockBsonDbInstance.commit).toHaveBeenCalled();
        expect(mockReleaseWriteLock).toHaveBeenCalled();
        expect(context.sendMessage).toHaveBeenCalledWith(expect.objectContaining({
            type: 'import-success',
            assetId: 'asset-1',
        }));
    });

    test('sends import-success message in dry-run mode without writing to database', async () => {
        const context = makeContext();
        const data = makeHashFileData({ dryRun: true });
        setupStorageMock();

        mockGetHashFromCache.mockResolvedValue(null as any);
        mockValidateAndHash.mockResolvedValue(makeHashedFile() as any);
        const mockMetadataCollection = makeMockMetadataCollection([]);
        mockCreateMediaFileDatabase.mockReturnValue({
            metadataCollection: mockMetadataCollection as any,
        } as any);

        const mockMerkleTree = { nodes: [], databaseMetadata: {} };
        mockLoadMerkleTree.mockResolvedValue(mockMerkleTree as any);

        const mockBsonDbInstance = {
            collection: jest.fn(),
            commit: jest.fn(),
        };
        MockBsonDatabase.mockImplementation(() => mockBsonDbInstance as any);

        await uploadAssetHandler(data, context);

        expect(mockAcquireWriteLock).toHaveBeenCalled();
        expect(mockBsonDbInstance.commit).not.toHaveBeenCalled();
        expect(context.sendMessage).toHaveBeenCalledWith(expect.objectContaining({
            type: 'import-success',
            assetId: 'asset-1',
        }));
    });

    test('releases write lock even when db write fails', async () => {
        const context = makeContext();
        const data = makeHashFileData({ dryRun: false });
        setupStorageMock();

        mockGetHashFromCache.mockResolvedValue(null as any);
        mockValidateAndHash.mockResolvedValue(makeHashedFile() as any);
        const mockMetadataCollection = makeMockMetadataCollection([]);
        mockCreateMediaFileDatabase.mockReturnValue({
            metadataCollection: mockMetadataCollection as any,
        } as any);

        mockLoadMerkleTree.mockResolvedValue({ nodes: [], databaseMetadata: {} } as any);
        mockSaveMerkleTree.mockRejectedValue(new Error('Disk full'));

        const mockBsonDbInstance = {
            collection: jest.fn().mockReturnValue({
                insertOne: jest.fn().mockResolvedValue(undefined),
                sortIndex: jest.fn().mockReturnValue({
                    findByValue: jest.fn().mockResolvedValue([]),
                }),
            }),
            commit: jest.fn().mockResolvedValue(undefined),
        };
        MockBsonDatabase.mockImplementation(() => mockBsonDbInstance as any);

        await expect(uploadAssetHandler(data, context)).rejects.toThrow('Disk full');

        expect(mockReleaseWriteLock).toHaveBeenCalled();
    });
});
