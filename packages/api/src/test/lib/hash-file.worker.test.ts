import type { ITaskContext } from 'task-queue';
import type { IStorageDescriptor } from 'storage';
import type { IHashFileData } from '../../lib/hash-file.worker';

// ── module mocks ─────────────────────────────────────────────────────────────

jest.mock('../../lib/hash', () => ({
    validateAndHash: jest.fn(),
    getHashFromCache: jest.fn(),
}));

jest.mock('../../lib/hash-cache', () => ({
    HashCache: jest.fn().mockImplementation(() => ({
        load: jest.fn().mockResolvedValue(undefined),
    })),
}));

jest.mock('storage', () => ({
    createStorage: jest.fn(),
    loadEncryptionKeysFromPem: jest.fn().mockResolvedValue({ options: {} }),
}));

jest.mock('../../lib/media-file-database', () => ({
    createMediaFileDatabase: jest.fn(),
}));

// ── imports after mocks ───────────────────────────────────────────────────────

import { hashFileHandler } from '../../lib/hash-file.worker';
import { validateAndHash, getHashFromCache } from '../../lib/hash';
import { createStorage, loadEncryptionKeysFromPem } from 'storage';
import { createMediaFileDatabase } from '../../lib/media-file-database';

const mockValidateAndHash = validateAndHash as jest.MockedFunction<typeof validateAndHash>;
const mockGetHashFromCache = getHashFromCache as jest.MockedFunction<typeof getHashFromCache>;
const mockCreateStorage = createStorage as jest.MockedFunction<typeof createStorage>;
const mockCreateMediaFileDatabase = createMediaFileDatabase as jest.MockedFunction<typeof createMediaFileDatabase>;

// ── helpers ───────────────────────────────────────────────────────────────────

//
// Builds a minimal ITaskContext for testing.
//
function makeContext(overrides: Partial<ITaskContext> = {}): ITaskContext {
    return {
        uuidGenerator: { generate: jest.fn().mockReturnValue('test-uuid') },
        timestampProvider: { now: jest.fn().mockReturnValue(Date.now()), dateNow: jest.fn().mockReturnValue(new Date()) },
        sessionId: 'session-1',
        sendMessage: jest.fn(),
        isCancelled: jest.fn().mockReturnValue(false),
        taskId: 'task-1',
        ...overrides,
    };
}

//
// Builds a minimal IHashFileData for testing.
//
function makeData(overrides: Partial<IHashFileData> = {}): IHashFileData {
    const storageDescriptor: IStorageDescriptor = {
        dbDir: '/test/db',
    };
    return {
        filePath: '/test/photos/img.jpg',
        fileStat: { length: 1000, lastModified: new Date('2024-01-01') },
        contentType: 'image/jpeg',
        storageDescriptor,
        hashCacheDir: '/tmp/photosphere',
        s3Config: undefined,
        logicalPath: '/test/photos/img.jpg',
        labels: ['photos'],
        googleApiKey: undefined,
        sessionId: 'session-1',
        dryRun: false,
        assetId: 'asset-1',
        ...overrides,
    };
}

//
// Creates a mock metadata collection that returns the given records for findByValue.
//
function makeMockMetadataCollection(records: any[] = []) {
    return {
        sortIndex: jest.fn().mockReturnValue({
            findByValue: jest.fn().mockResolvedValue(records),
        }),
    };
}

//
// Sets up createStorage to return a minimal storage mock.
//
function setupStorageMock() {
    const mockStorage = {};
    const mockRawStorage = {};
    mockCreateStorage.mockReturnValue({
        storage: mockStorage as any,
        rawStorage: mockRawStorage as any,
        normalizedPath: '/test/db',
        type: 'fs',
    });
    return { mockStorage, mockRawStorage };
}

// ── tests ────────────────────────────────────────────────────────────────────

describe('hashFileHandler', () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test('returns hash from cache when cache hit', async () => {
        const context = makeContext();
        const data = makeData();
        const cachedHash = { hash: Buffer.from('aabbcc', 'hex'), length: 1000, lastModified: new Date('2024-01-01') };

        mockGetHashFromCache.mockResolvedValue(cachedHash as any);
        setupStorageMock();

        const mockMetadataCollection = makeMockMetadataCollection([]);
        mockCreateMediaFileDatabase.mockReturnValue({
            metadataCollection: mockMetadataCollection as any,
        } as any);

        const result = await hashFileHandler(data, context);

        expect(mockValidateAndHash).not.toHaveBeenCalled();
        expect(result.hashFromCache).toBe(true);
        expect(result.hash).toEqual(new Uint8Array(Buffer.from('aabbcc', 'hex')));
        expect(result.filesAlreadyAdded).toBe(false);
    });

    test('computes hash via validateAndHash when not in cache', async () => {
        const context = makeContext();
        const data = makeData();
        const computedHash = { hash: Buffer.from('ddeeff', 'hex'), length: 1000, lastModified: new Date('2024-01-01') };

        mockGetHashFromCache.mockResolvedValue(undefined);
        mockValidateAndHash.mockResolvedValue(computedHash as any);
        setupStorageMock();

        const mockMetadataCollection = makeMockMetadataCollection([]);
        mockCreateMediaFileDatabase.mockReturnValue({
            metadataCollection: mockMetadataCollection as any,
        } as any);

        const result = await hashFileHandler(data, context);

        expect(mockValidateAndHash).toHaveBeenCalledWith(
            data.filePath,
            data.fileStat,
            data.contentType,
            data.logicalPath
        );
        expect(result.hashFromCache).toBe(false);
        expect(result.hash).toEqual(new Uint8Array(Buffer.from('ddeeff', 'hex')));
    });

    test('returns filesAlreadyAdded true when hash exists in database', async () => {
        const context = makeContext();
        const data = makeData();
        const hash = { hash: Buffer.from('aabbcc', 'hex'), length: 1000, lastModified: new Date('2024-01-01') };

        mockGetHashFromCache.mockResolvedValue(hash as any);
        setupStorageMock();

        const mockMetadataCollection = makeMockMetadataCollection([{ _id: 'existing-asset' }]);
        mockCreateMediaFileDatabase.mockReturnValue({
            metadataCollection: mockMetadataCollection as any,
        } as any);

        const result = await hashFileHandler(data, context);

        expect(result.filesAlreadyAdded).toBe(true);
    });

    test('throws when validateAndHash returns undefined', async () => {
        const context = makeContext();
        const data = makeData();

        mockGetHashFromCache.mockResolvedValue(undefined);
        mockValidateAndHash.mockResolvedValue(undefined);
        setupStorageMock();

        await expect(hashFileHandler(data, context)).rejects.toThrow('Failed to validate and hash file');
    });

    test('when s3Config is provided, storage is created with the S3 credentials', async () => {
        const context = makeContext();
        const s3Config = { endpoint: 'https://s3.example.com', bucket: 'my-bucket', accessKeyId: 'key', secretAccessKey: 'secret', region: 'us-east-1' };
        const data = makeData({ s3Config });
        const hash = { hash: Buffer.from('aabbcc', 'hex'), length: 1000, lastModified: new Date() };

        mockGetHashFromCache.mockResolvedValue(hash as any);
        setupStorageMock();

        const mockMetadataCollection = makeMockMetadataCollection([]);
        mockCreateMediaFileDatabase.mockReturnValue({
            metadataCollection: mockMetadataCollection as any,
        } as any);

        await hashFileHandler(data, context);

        expect(mockCreateStorage).toHaveBeenCalledWith(
            expect.any(String),
            s3Config,
            expect.anything()
        );
    });

    test('dryRun true does not change the return value (hash-file is read-only regardless)', async () => {
        const context = makeContext();
        const hash = { hash: Buffer.from('aabbcc', 'hex'), length: 1000, lastModified: new Date() };

        mockGetHashFromCache.mockResolvedValue(hash as any);
        setupStorageMock();

        const mockMetadataCollection = makeMockMetadataCollection([]);
        mockCreateMediaFileDatabase.mockReturnValue({
            metadataCollection: mockMetadataCollection as any,
        } as any);

        const resultNoDryRun = await hashFileHandler(makeData({ dryRun: false }), context);
        const resultDryRun = await hashFileHandler(makeData({ dryRun: true }), context);

        expect(resultDryRun.hash).toEqual(resultNoDryRun.hash);
        expect(resultDryRun.filesAlreadyAdded).toEqual(resultNoDryRun.filesAlreadyAdded);
        expect(resultDryRun.hashFromCache).toEqual(resultNoDryRun.hashFromCache);
    });

    test('does not send any messages', async () => {
        const context = makeContext();
        const data = makeData();
        const hash = { hash: Buffer.from('aabbcc', 'hex'), length: 1000, lastModified: new Date('2024-01-01') };

        mockGetHashFromCache.mockResolvedValue(hash as any);
        setupStorageMock();

        const mockMetadataCollection = makeMockMetadataCollection([]);
        mockCreateMediaFileDatabase.mockReturnValue({
            metadataCollection: mockMetadataCollection as any,
        } as any);

        await hashFileHandler(data, context);

        expect(context.sendMessage).not.toHaveBeenCalled();
    });
});
