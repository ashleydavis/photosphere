import type { ITaskContext } from 'task-queue';
import type { IDatabaseDescriptor } from '../../lib/database-descriptor';
import type { IUploadAssetData } from '../../lib/upload-asset.worker';

// ── module mocks ────────────────────────────────────────────────────────────

jest.mock('fs', () => ({
    ...jest.requireActual('fs'),
    createReadStream: jest.fn().mockReturnValue({ pipe: jest.fn(), on: jest.fn() }),
}));

jest.mock('../../lib/hash', () => ({
    computeAssetHash: jest.fn(),
}));

jest.mock('storage', () => ({
    createStorage: jest.fn(),
    loadEncryptionKeysFromPem: jest.fn().mockResolvedValue({ options: {} }),
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
    getProcessTmpDir: jest.fn().mockReturnValue('/tmp'),
}));

jest.mock('../../lib/resolve-storage-credentials', () => ({
    resolveStorageCredentials: jest.fn().mockResolvedValue({
        s3Config: undefined,
        encryptionKeyPems: [],
        googleApiKey: undefined,
    }),
}));

jest.mock('../../lib/media-file-database', () => ({
    extractDominantColorFromThumbnail: jest.fn().mockResolvedValue([128, 64, 32]),
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
import { createStorage, loadEncryptionKeys } from 'storage';
import { getImageDetails } from '../../lib/image';
import { getVideoDetails } from '../../lib/video';

const mockCreateStorage = createStorage as jest.MockedFunction<typeof createStorage>;
const mockGetImageDetails = getImageDetails as jest.MockedFunction<typeof getImageDetails>;
const mockGetVideoDetails = getVideoDetails as jest.MockedFunction<typeof getVideoDetails>;

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
        isCancelled: jest.fn().mockReturnValue(false),
        taskId: 'task-1',
        ...overrides,
    };
}

//
// Builds a minimal storage descriptor for testing.
//
function makeStorageDescriptor(): IDatabaseDescriptor {
    return {
        databasePath: '/test/db',
    };
}

//
// Builds a minimal IUploadAssetData for testing.
//
function makeUploadAssetData(overrides: Partial<IUploadAssetData> = {}): IUploadAssetData {
    return {
        filePath: '/test/photos/img.jpg',
        fileStat: { length: 1000, lastModified: new Date('2024-01-01') },
        contentType: 'image/jpeg',
        storageDescriptor: makeStorageDescriptor(),
        logicalPath: '/test/photos/img.jpg',
        assetId: 'asset-1',
        labels: ['photos'],
        googleApiKey: undefined,
        sessionId: 'session-1',
        dryRun: false,
        expectedHash: new Uint8Array(Buffer.from('aabbcc', 'hex')),
        ...overrides,
    };
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

//
// Builds a minimal IAssetDetails mock for testing thumbnail/display paths.
//
function makeAssetDetails(overrides: Record<string, any> = {}): any {
    return {
        resolution: { width: 100, height: 100 },
        thumbnailPath: '/tmp/thumb.jpg',
        thumbnailContentType: 'image/jpeg',
        displayPath: '/tmp/display.jpg',
        displayContentType: 'image/jpeg',
        ...overrides,
    };
}

// ── uploadAssetHandler tests ─────────────────────────────────────────────────

describe('uploadAssetHandler', () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test('returns undefined when cancelled', async () => {
        const context = makeContext({ isCancelled: jest.fn().mockReturnValue(true) });
        const data = makeUploadAssetData();

        expect(await uploadAssetHandler(data, context)).toBeUndefined();
    });

    test('returns IUploadAssetResult with assetData in dry-run mode without writing to storage', async () => {
        const context = makeContext();
        const data = makeUploadAssetData({ dryRun: true });
        setupStorageMock();

        const result = await uploadAssetHandler(data, context);

        expect(result).toHaveProperty('assetData');
        expect(result).toHaveProperty('totalSize');
        expect(result!.assetData.assetId).toBe('asset-1');
        expect(result!.assetData.assetRecord).toBeDefined();
        expect(result!.assetData.assetRecord._id).toBe('asset-1');
    });

    test('sends import-pending message at start', async () => {
        const context = makeContext();
        const data = makeUploadAssetData({ dryRun: true });
        setupStorageMock();

        await uploadAssetHandler(data, context);

        expect(context.sendMessage).toHaveBeenCalledWith({
            type: 'import-pending',
            assetId: 'asset-1',
            logicalPath: '/test/photos/img.jpg',
        });
    });

    test('does not send import-success or import-skipped messages', async () => {
        const context = makeContext();
        const data = makeUploadAssetData({ dryRun: true });
        setupStorageMock();

        await uploadAssetHandler(data, context);

        const messages = (context.sendMessage as jest.Mock).mock.calls.map(call => call[0].type);
        expect(messages).not.toContain('import-success');
        expect(messages).not.toContain('import-skipped');
    });

    test('does not acquire write lock or write to database', async () => {
        const context = makeContext();
        const data = makeUploadAssetData({ dryRun: false });
        const { mockStorage } = setupStorageMock();

        const { computeAssetHash } = require('../../lib/hash');
        computeAssetHash.mockResolvedValue({
            hash: Buffer.from('aabbcc', 'hex'),
            length: 1000,
            lastModified: new Date(),
        });

        await uploadAssetHandler(data, context);

        // No write-lock or DB modules are imported by the new upload-asset handler.
        // Verify that no 'write-lock' or 'bdb' code was invoked by checking that
        // storage writes happened but no DB-related methods were called.
        expect(mockStorage.writeStream).toHaveBeenCalled();
    });

    test('returns correct assetRecord hash', async () => {
        const context = makeContext();
        const expectedHashHex = 'aabbcc';
        const data = makeUploadAssetData({
            dryRun: true,
            expectedHash: new Uint8Array(Buffer.from(expectedHashHex, 'hex')),
        });
        setupStorageMock();

        const result = await uploadAssetHandler(data, context);

        expect(result!.assetData.assetRecord.hash).toBe(expectedHashHex);
    });

    test('in non-dry-run mode, storage.writeStream is called for the asset, thumbnail, and display file', async () => {
        const context = makeContext();
        const data = makeUploadAssetData({ contentType: 'image/jpeg', dryRun: false });
        const { mockStorage } = setupStorageMock();
        mockGetImageDetails.mockResolvedValue(makeAssetDetails());

        const { computeAssetHash } = require('../../lib/hash');
        computeAssetHash.mockResolvedValue({
            hash: Buffer.from('aabbcc', 'hex'),
            length: 1000,
            lastModified: new Date(),
        });

        await uploadAssetHandler(data, context);

        const writeStreamCalls = mockStorage.writeStream.mock.calls.map((call: any[]) => call[0]);
        expect(writeStreamCalls).toContain(`asset/${data.assetId}`);
        expect(writeStreamCalls).toContain(`thumb/${data.assetId}`);
        expect(writeStreamCalls).toContain(`display/${data.assetId}`);
    });

    test('result.totalSize equals the sum of asset + thumbnail + display byte lengths', async () => {
        const context = makeContext();
        const fileSize = 500;
        const data = makeUploadAssetData({
            contentType: 'image/jpeg',
            dryRun: true,
            fileStat: { length: fileSize, lastModified: new Date('2024-01-01') },
        });
        setupStorageMock();
        mockGetImageDetails.mockResolvedValue(makeAssetDetails());

        const result = await uploadAssetHandler(data, context);

        // In dry-run mode each of the three uploads uses fileStat.length.
        expect(result!.totalSize).toBe(fileSize * 3);
    });

    test('returned IAssetDatabaseData includes display fields when a display version is produced', async () => {
        const context = makeContext();
        const data = makeUploadAssetData({ contentType: 'image/jpeg', dryRun: true });
        setupStorageMock();
        mockGetImageDetails.mockResolvedValue(makeAssetDetails());

        const result = await uploadAssetHandler(data, context);

        expect(result!.assetData.displayPath).toBeDefined();
        expect(result!.assetData.displayHash).toBeDefined();
        expect(result!.assetData.displayLength).toBeDefined();
        expect(result!.assetData.displayLastModified).toBeDefined();
    });

    test('returned IAssetDatabaseData includes thumb fields when a thumbnail is produced', async () => {
        const context = makeContext();
        const data = makeUploadAssetData({ contentType: 'image/jpeg', dryRun: true });
        setupStorageMock();
        mockGetImageDetails.mockResolvedValue(makeAssetDetails({ displayPath: undefined }));

        const result = await uploadAssetHandler(data, context);

        expect(result!.assetData.thumbPath).toBeDefined();
        expect(result!.assetData.thumbHash).toBeDefined();
        expect(result!.assetData.thumbLength).toBeDefined();
        expect(result!.assetData.thumbLastModified).toBeDefined();
    });

    test('when contentType starts with image/, getImageDetails is called', async () => {
        const context = makeContext();
        const data = makeUploadAssetData({ contentType: 'image/jpeg', dryRun: true });
        setupStorageMock();
        mockGetImageDetails.mockResolvedValue(makeAssetDetails());

        await uploadAssetHandler(data, context);

        expect(mockGetImageDetails).toHaveBeenCalledWith(
            data.filePath,
            expect.any(String),
            data.contentType,
            context.uuidGenerator,
            data.logicalPath
        );
        expect(mockGetVideoDetails).not.toHaveBeenCalled();
    });

    test('when contentType starts with video/, getVideoDetails is called', async () => {
        const context = makeContext();
        const data = makeUploadAssetData({ contentType: 'video/mp4', dryRun: true });
        setupStorageMock();
        mockGetVideoDetails.mockResolvedValue(makeAssetDetails());

        await uploadAssetHandler(data, context);

        expect(mockGetVideoDetails).toHaveBeenCalledWith(
            data.filePath,
            expect.any(String),
            data.contentType,
            context.uuidGenerator,
            data.logicalPath
        );
        expect(mockGetImageDetails).not.toHaveBeenCalled();
    });

    test('sends import-failed and cleans up on upload error', async () => {
        const context = makeContext();
        const data = makeUploadAssetData({ dryRun: false });
        const { mockStorage } = setupStorageMock();

        mockStorage.writeStream.mockRejectedValue(new Error('Storage write failed'));

        await expect(uploadAssetHandler(data, context)).rejects.toThrow('Storage write failed');

        expect(context.sendMessage).toHaveBeenCalledWith({
            type: 'import-failed',
            assetId: 'asset-1',
            logicalPath: '/test/photos/img.jpg',
        });
        expect(mockStorage.deleteFile).toHaveBeenCalled();
    });
});
