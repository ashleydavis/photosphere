import { addPathsHandler } from '../../lib/add-paths.worker';
import type { IAddPathsData } from '../../lib/add-paths.worker';
import type { ITaskContext } from 'task-queue';
import type { IStorageDescriptor } from 'storage';

jest.mock('../../lib/file-scanner', () => ({
    scanPaths: jest.fn(),
}));

jest.mock('node-utils', () => ({
    ensureDir: jest.fn().mockResolvedValue(undefined),
    remove: jest.fn().mockResolvedValue(undefined),
}));

import { scanPaths } from '../../lib/file-scanner';

const mockScanPaths = scanPaths as jest.MockedFunction<typeof scanPaths>;

//
// Builds a minimal ITaskContext for testing.
//
function makeContext(overrides: Partial<ITaskContext> = {}): ITaskContext {
    return {
        uuidGenerator: { generate: jest.fn().mockReturnValue('test-uuid') },
        timestampProvider: { now: jest.fn().mockReturnValue(Date.now()), dateNow: jest.fn().mockReturnValue(new Date()) },
        sessionId: 'session-1',
        sendMessage: jest.fn(),
        queueTask: jest.fn(),
        isCancelled: jest.fn().mockReturnValue(false),
        ...overrides,
    };
}

//
// Builds a minimal IAddPathsData for testing.
//
function makeData(overrides: Partial<IAddPathsData> = {}): IAddPathsData {
    const storageDescriptor: IStorageDescriptor = {
        dbDir: '/test/db',
        encryptionKeyPaths: [],
    };
    return {
        paths: ['/test/photos'],
        storageDescriptor,
        googleApiKey: undefined,
        sessionId: 'session-1',
        dryRun: false,
        s3Config: undefined,
        ...overrides,
    };
}

describe('addPathsHandler', () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test('queues a hash-file task for each file found by scanPaths', async () => {
        const context = makeContext();
        const data = makeData();

        mockScanPaths.mockImplementation(async (paths, visitFile, progressCallback, options, sessionTempDir, uuidGenerator) => {
            await visitFile({
                filePath: '/test/photos/img1.jpg',
                fileStat: { length: 1000, lastModified: new Date('2024-01-01') },
                contentType: 'image/jpeg',
                labels: ['photos'],
                logicalPath: '/test/photos/img1.jpg',
            });
            await visitFile({
                filePath: '/test/photos/img2.jpg',
                fileStat: { length: 2000, lastModified: new Date('2024-01-02') },
                contentType: 'image/jpeg',
                labels: ['photos'],
                logicalPath: '/test/photos/img2.jpg',
            });
        });

        await addPathsHandler(data, context);

        expect(context.queueTask).toHaveBeenCalledTimes(2);
        expect(context.queueTask).toHaveBeenCalledWith(
            'import-file',
            expect.objectContaining({
                filePath: '/test/photos/img1.jpg',
                contentType: 'image/jpeg',
                storageDescriptor: data.storageDescriptor,
                sessionId: 'session-1',
                dryRun: false,
            }),
            '/test/db'
        );
        expect(context.queueTask).toHaveBeenCalledWith(
            'import-file',
            expect.objectContaining({
                filePath: '/test/photos/img2.jpg',
            }),
            '/test/db'
        );
    });

    test('sends scan-progress messages during scanning', async () => {
        const context = makeContext();
        const data = makeData();

        mockScanPaths.mockImplementation(async (paths, visitFile, progressCallback) => {
            progressCallback!('/test/photos', { currentlyScanning: '/test/photos', numFilesIgnored: 0, numFilesFailed: 0, tempDir: '' });
        });

        await addPathsHandler(data, context);

        expect(context.sendMessage).toHaveBeenCalledWith({
            type: 'scan-progress',
            currentPath: '/test/photos',
        });
    });

    test('sends file-ignored messages when files are ignored', async () => {
        const context = makeContext();
        const data = makeData();

        mockScanPaths.mockImplementation(async (paths, visitFile, progressCallback) => {
            // Report 2 newly ignored files
            progressCallback!(undefined, { currentlyScanning: undefined, numFilesIgnored: 2, numFilesFailed: 0, tempDir: '' });
        });

        await addPathsHandler(data, context);

        const ignoredMessages = (context.sendMessage as jest.Mock).mock.calls.filter(
            (call) => call[0].type === 'file-ignored'
        );
        expect(ignoredMessages).toHaveLength(2);
    });

    test('stops queuing tasks when cancelled', async () => {
        const context = makeContext({
            isCancelled: jest.fn().mockReturnValue(true),
        });
        const data = makeData();

        mockScanPaths.mockImplementation(async (paths, visitFile) => {
            await visitFile({
                filePath: '/test/photos/img1.jpg',
                fileStat: { length: 1000, lastModified: new Date() },
                contentType: 'image/jpeg',
                labels: [],
                logicalPath: '/test/photos/img1.jpg',
            });
        });

        await addPathsHandler(data, context);

        expect(context.queueTask).not.toHaveBeenCalled();
    });
});
