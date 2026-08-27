import type { ITaskContext } from 'task-queue';
import type { IDatabaseDescriptor } from 'api';
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
        maxConcurrentChildTasks: 10,
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
    const storageDescriptor: IDatabaseDescriptor = {
        databasePath: '/test/db',
    };
    return {
        filePath: '/test/photos/img.jpg',
        fileStat: { length: 1000, lastModified: new Date('2024-01-01') },
        contentType: 'image/jpeg',
        storageDescriptor,
        hashCacheDir: '/tmp/photosphere',
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

    test('does not ask the database whether the hash is already there', async () => {
        // That question is answered by the orchestrator now, from a map it builds once when the run
        // starts. Asked here it was answered by an index query per file, against a database object
        // built per file, so the collection's sort index cache never survived to be used twice: 69%
        // of an import on a Pixel 6, growing from 373 milliseconds a file to 4.3 seconds as the
        // database filled.
        const context = makeContext();
        const data = makeData();
        const hash = { hash: Buffer.from('aabbcc', 'hex'), length: 1000, lastModified: new Date('2024-01-01') };

        mockGetHashFromCache.mockResolvedValue(hash as any);
        setupStorageMock();

        const mockMetadataCollection = makeMockMetadataCollection([{ _id: 'existing-asset' }]);
        mockCreateMediaFileDatabase.mockReturnValue({
            metadataCollection: mockMetadataCollection as any,
        } as any);

        await hashFileHandler(data, context);

        expect(mockMetadataCollection.sortIndex).not.toHaveBeenCalled();
        expect(mockCreateMediaFileDatabase).not.toHaveBeenCalled();
    });

    test('throws when validateAndHash returns undefined', async () => {
        const context = makeContext();
        const data = makeData();

        mockGetHashFromCache.mockResolvedValue(undefined);
        mockValidateAndHash.mockResolvedValue(undefined);
        setupStorageMock();

        await expect(hashFileHandler(data, context)).rejects.toThrow('Failed to validate and hash file');
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
        expect(resultDryRun.hashFromCache).toEqual(resultNoDryRun.hashFromCache);
    });

    test('looks a photo library item up by the identity it was given, not by its temporary path', async () => {
        // The temporary copy the item was exported to has a path and a modified time that were both
        // minted by the copy, so looking it up by those would miss every time.
        const context = makeContext();
        const cacheIdentity = { key: '1000000042', length: 4096, lastModified: 1700000000000 };
        const data = makeData({ cacheIdentity });

        mockGetHashFromCache.mockResolvedValue(undefined);
        mockValidateAndHash.mockResolvedValue({ hash: Buffer.from('ddeeff', 'hex'), length: 1000, lastModified: new Date('2024-01-01') } as any);
        setupStorageMock();
        mockCreateMediaFileDatabase.mockReturnValue({ metadataCollection: makeMockMetadataCollection([]) as any } as any);

        await hashFileHandler(data, context);

        expect(mockGetHashFromCache).toHaveBeenCalledWith(data.filePath, data.fileStat, expect.anything(), cacheIdentity);
    });

    test('looks an ordinary file up by nothing but its own path, which is what keeps the desktop unchanged', async () => {
        const context = makeContext();
        const data = makeData();

        mockGetHashFromCache.mockResolvedValue(undefined);
        mockValidateAndHash.mockResolvedValue({ hash: Buffer.from('ddeeff', 'hex'), length: 1000, lastModified: new Date('2024-01-01') } as any);
        setupStorageMock();
        mockCreateMediaFileDatabase.mockReturnValue({ metadataCollection: makeMockMetadataCollection([]) as any } as any);

        await hashFileHandler(data, context);

        expect(mockGetHashFromCache).toHaveBeenCalledWith(data.filePath, data.fileStat, expect.anything(), undefined);
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
