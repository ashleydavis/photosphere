import { importAssetsHandler } from '../../lib/import-assets.worker';
import type { IImportAssetsData } from '../../lib/import-assets.worker';
import type { ITaskContext, IQueueBackend, ITaskResult, WorkerTaskCompletionCallback, UnsubscribeFn } from 'task-queue';
import { TaskStatus, setQueueBackend } from 'task-queue';
import type { IStorageDescriptor } from 'storage';
import type { IHashFileData, IHashFileResult } from '../../lib/hash-file.worker';
import type { IUploadAssetData, IUploadAssetResult, IAssetDatabaseData } from '../../lib/upload-asset.worker';

// ── module mocks ─────────────────────────────────────────────────────────────

jest.mock('../../lib/file-scanner', () => ({
    scanPaths: jest.fn(),
}));

jest.mock('node-utils', () => ({
    ensureDir: jest.fn().mockResolvedValue(undefined),
    remove: jest.fn().mockResolvedValue(undefined),
}));

jest.mock('storage', () => ({
    createStorage: jest.fn().mockReturnValue({
        storage: {},
        rawStorage: {},
        normalizedPath: '/test/db',
        type: 'fs',
    }),
    loadEncryptionKeys: jest.fn().mockResolvedValue({ options: {} }),
}));

jest.mock('bdb', () => ({
    BsonDatabase: jest.fn().mockImplementation(() => ({
        collection: jest.fn().mockReturnValue({
            insertOne: jest.fn().mockResolvedValue(undefined),
            sortIndex: jest.fn().mockReturnValue({
                findByValue: jest.fn().mockResolvedValue([]),
            }),
        }),
        flush: jest.fn().mockResolvedValue(undefined),
        commit: jest.fn().mockResolvedValue(undefined),
    })),
}));

jest.mock('../../lib/hash-cache', () => ({
    HashCache: jest.fn().mockImplementation(() => ({
        load: jest.fn().mockResolvedValue(undefined),
        save: jest.fn().mockResolvedValue(undefined),
        addHash: jest.fn(),
    })),
}));

jest.mock('../../lib/write-lock', () => ({
    acquireWriteLock: jest.fn().mockResolvedValue(true),
    releaseWriteLock: jest.fn().mockResolvedValue(undefined),
}));

jest.mock('../../lib/tree', () => ({
    loadMerkleTree: jest.fn().mockResolvedValue({ nodes: [], databaseMetadata: { filesImported: 0 } }),
    saveMerkleTree: jest.fn().mockResolvedValue(undefined),
}));

jest.mock('merkle-tree', () => ({
    addItem: jest.fn((tree: any, _item: any) => tree),
    BufferSet: jest.fn().mockImplementation(() => {
        const seen = new Set<string>();
        return {
            has: jest.fn((buf: Buffer) => seen.has(buf.toString('hex'))),
            add: jest.fn((buf: Buffer) => seen.add(buf.toString('hex'))),
            delete: jest.fn((buf: Buffer) => seen.delete(buf.toString('hex'))),
        };
    }),
}));

jest.mock('../../lib/database-config', () => ({
    updateDatabaseConfig: jest.fn().mockResolvedValue(undefined),
}));

jest.mock('utils', () => ({
    log: { verbose: jest.fn(), error: jest.fn(), exception: jest.fn(), info: jest.fn() },
    retry: jest.fn((fn: () => any) => fn()),
    retryOrLog: jest.fn((fn: () => any) => fn()),
    sleep: jest.fn().mockResolvedValue(undefined),
    swallowError: jest.fn((fn: () => any) => fn()),
}));

import { scanPaths } from '../../lib/file-scanner';

const mockScanPaths = scanPaths as jest.MockedFunction<typeof scanPaths>;

// ── helpers ──────────────────────────────────────────────────────────────────

//
// Minimal mock IQueueBackend that records addTask calls, fires onTaskAdded callbacks,
// and auto-completes tasks via optional result factories.
//
class MockBackend implements IQueueBackend {
    addedTasks: { type: string; data: any; source: string; taskId: string }[] = [];
    private taskAddedCallbacks: Map<string, ((taskId: string) => void)[]> = new Map();
    completionCallbacks: WorkerTaskCompletionCallback[] = [];
    private resultFactories: Map<string, (data: any, taskId: string) => ITaskResult> = new Map();

    setTaskResult(type: string, factory: (data: any, taskId: string) => ITaskResult): void {
        this.resultFactories.set(type, factory);
    }

    addTask(type: string, data: any, source: string, taskId?: string): string {
        const id = taskId ?? `${type}-${this.addedTasks.length}`;
        this.addedTasks.push({ type, data, source, taskId: id });
        const cbs = this.taskAddedCallbacks.get(source);
        if (cbs) {
            for (const cb of cbs) {
                cb(id);
            }
        }
        const factory = this.resultFactories.get(type);
        if (factory) {
            const result = factory(data, id);
            Promise.resolve().then(() => this.fireCompletion({ ...result, taskId: id }));
        }
        return id;
    }

    async fireCompletion(result: ITaskResult): Promise<void> {
        for (const cb of [...this.completionCallbacks]) {
            await cb(result);
        }
    }

    onTaskAdded(source: string, cb: (taskId: string) => void): UnsubscribeFn {
        const existing = this.taskAddedCallbacks.get(source) ?? [];
        existing.push(cb);
        this.taskAddedCallbacks.set(source, existing);
        return () => {};
    }

    onTaskComplete(cb: WorkerTaskCompletionCallback): UnsubscribeFn {
        this.completionCallbacks.push(cb);
        return () => {
            const idx = this.completionCallbacks.indexOf(cb);
            if (idx !== -1) {
                this.completionCallbacks.splice(idx, 1);
            }
        };
    }

    onTaskMessage(_type: string, _cb: any): UnsubscribeFn { return () => {}; }
    onAnyTaskMessage(_cb: any): UnsubscribeFn { return () => {}; }
    cancelTasks(_source: string): void {}
    onTasksCancelled(_source: string, _cb: () => void): UnsubscribeFn { return () => {}; }
    shutdown(): void {}
}

//
// Builds a minimal ITaskContext for testing.
//
function makeContext(overrides: Partial<ITaskContext> = {}): ITaskContext {
    return {
        uuidGenerator: { generate: jest.fn().mockImplementation((() => { let n = 0; return () => `test-uuid-${n++}`; })()) },
        timestampProvider: { now: jest.fn().mockReturnValue(Date.now()), dateNow: jest.fn().mockReturnValue(new Date()) },
        sessionId: 'session-1',
        sendMessage: jest.fn(),
        isCancelled: jest.fn().mockReturnValue(false),
        taskId: 'orchestrator-task-id',
        ...overrides,
    };
}

//
// Builds a minimal IImportAssetsData for testing.
//
function makeData(overrides: Partial<IImportAssetsData> = {}): IImportAssetsData {
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

// ── tests ────────────────────────────────────────────────────────────────────

describe('importAssetsHandler', () => {
    let mockBackend: MockBackend;

    beforeEach(() => {
        jest.clearAllMocks();
        mockBackend = new MockBackend();
        // Auto-complete hash-file tasks as "already added" by default so awaitAllTasks resolves.
        mockBackend.setTaskResult('hash-file', (data, taskId) => ({
            taskId,
            type: 'hash-file',
            inputs: data,
            status: TaskStatus.Succeeded,
            outputs: { hash: new Uint8Array(3), hashFromCache: false, filesAlreadyAdded: true } as IHashFileResult,
        }));
        setQueueBackend(mockBackend);
    });

    test('childQueue.shutdown is called in the finally block even when scanPaths throws', async () => {
        const cancelTasksSpy = jest.spyOn(mockBackend, 'cancelTasks');

        const context = makeContext();
        const data = makeData();

        mockScanPaths.mockRejectedValue(new Error('scan failed'));

        await expect(importAssetsHandler(data, context)).rejects.toThrow('scan failed');

        // shutdown() calls backend.cancelTasks(source), confirming the finally block ran.
        expect(cancelTasksSpy).toHaveBeenCalled();
    });

    test('when acquireWriteLock returns false, retries until lock is acquired and sleep is called', async () => {
        const { acquireWriteLock } = require('../../lib/write-lock');
        const { sleep } = require('utils');
        // First call returns false, second returns true.
        acquireWriteLock
            .mockResolvedValueOnce(false)
            .mockResolvedValue(true);

        const assetId = 'lock-retry-uuid';
        const hashBuffer = new Uint8Array(Buffer.from('aabbcc', 'hex'));

        mockBackend.setTaskResult('hash-file', (_data: IHashFileData, taskId) => ({
            taskId,
            type: 'hash-file',
            inputs: { ..._data, assetId },
            status: TaskStatus.Succeeded,
            outputs: { hash: hashBuffer, hashFromCache: false, filesAlreadyAdded: false } as IHashFileResult,
        }));

        const assetData: IAssetDatabaseData = {
            assetId,
            assetPath: `asset/${assetId}`,
            assetHash: 'aabbcc',
            assetLength: 1000,
            assetLastModified: new Date(),
            assetRecord: { _id: assetId } as any,
        };
        mockBackend.setTaskResult('upload-asset', (_data: IUploadAssetData, taskId) => ({
            taskId,
            type: 'upload-asset',
            inputs: { ..._data, assetId },
            status: TaskStatus.Succeeded,
            outputs: { assetData, totalSize: 1000 } as IUploadAssetResult,
        }));

        const context = makeContext();
        const data = makeData({ dryRun: true });

        mockScanPaths.mockImplementation(async (_paths, visitFile) => {
            await visitFile({
                filePath: '/test/photos/img1.jpg',
                fileStat: { length: 1000, lastModified: new Date() },
                contentType: 'image/jpeg',
                labels: [],
                logicalPath: '/test/photos/img1.jpg',
            });
        });

        await importAssetsHandler(data, context);

        expect(sleep).toHaveBeenCalled();
        expect(acquireWriteLock).toHaveBeenCalledTimes(2);
    });

    test('localHashCache.save is called after all tasks complete', async () => {
        const { HashCache } = require('../../lib/hash-cache');
        const mockSave = jest.fn().mockResolvedValue(undefined);
        HashCache.mockImplementation(() => ({
            load: jest.fn().mockResolvedValue(undefined),
            save: mockSave,
            addHash: jest.fn(),
        }));

        const context = makeContext();
        const data = makeData();

        mockScanPaths.mockImplementation(async () => {});

        await importAssetsHandler(data, context);

        expect(mockSave).toHaveBeenCalled();
    });

    test('after a successful upload, merkle-tree.addItem and metadataCollection.insertOne are called', async () => {
        const { addItem } = require('merkle-tree');
        const { BsonDatabase } = require('bdb');
        const mockInsertOne = jest.fn().mockResolvedValue(undefined);
        BsonDatabase.mockImplementation(() => ({
            collection: jest.fn().mockReturnValue({ insertOne: mockInsertOne }),
            flush: jest.fn().mockResolvedValue(undefined),
            commit: jest.fn().mockResolvedValue(undefined),
        }));

        const assetId = 'new-asset-uuid-2';
        const hashBuffer = new Uint8Array(Buffer.from('aabbcc', 'hex'));

        mockBackend.setTaskResult('hash-file', (_data: IHashFileData, taskId) => ({
            taskId,
            type: 'hash-file',
            inputs: { ..._data, assetId },
            status: TaskStatus.Succeeded,
            outputs: { hash: hashBuffer, hashFromCache: false, filesAlreadyAdded: false } as IHashFileResult,
        }));

        const assetRecord = { _id: assetId } as any;
        const assetData: IAssetDatabaseData = {
            assetId,
            assetPath: `asset/${assetId}`,
            assetHash: 'aabbcc',
            assetLength: 1000,
            assetLastModified: new Date('2024-01-01'),
            assetRecord,
        };
        mockBackend.setTaskResult('upload-asset', (_data: IUploadAssetData, taskId) => ({
            taskId,
            type: 'upload-asset',
            inputs: { ..._data, assetId },
            status: TaskStatus.Succeeded,
            outputs: { assetData, totalSize: 1000 } as IUploadAssetResult,
        }));

        const context = makeContext();
        const data = makeData({ dryRun: false });

        mockScanPaths.mockImplementation(async (_paths, visitFile) => {
            await visitFile({
                filePath: '/test/photos/img1.jpg',
                fileStat: { length: 1000, lastModified: new Date() },
                contentType: 'image/jpeg',
                labels: [],
                logicalPath: '/test/photos/img1.jpg',
            });
        });

        await importAssetsHandler(data, context);

        expect(addItem).toHaveBeenCalledWith(
            expect.anything(),
            expect.objectContaining({ name: assetData.assetPath })
        );
        expect(mockInsertOne).toHaveBeenCalledWith(assetRecord);
    });

    test('sends import-success when hash-file reports a new file and upload-asset succeeds', async () => {
        const assetId = 'new-asset-uuid';
        const hashBuffer = new Uint8Array(Buffer.from('aabbcc', 'hex'));

        mockBackend.setTaskResult('hash-file', (_data: IHashFileData, taskId) => ({
            taskId,
            type: 'hash-file',
            inputs: { ..._data, assetId },
            status: TaskStatus.Succeeded,
            outputs: { hash: hashBuffer, hashFromCache: false, filesAlreadyAdded: false } as IHashFileResult,
        }));

        const assetData: IAssetDatabaseData = {
            assetId,
            assetPath: `asset/${assetId}`,
            assetHash: 'aabbcc',
            assetLength: 1000,
            assetLastModified: new Date('2024-01-01'),
            assetRecord: { _id: assetId } as any,
        };
        mockBackend.setTaskResult('upload-asset', (_data: IUploadAssetData, taskId) => ({
            taskId,
            type: 'upload-asset',
            inputs: { ..._data, assetId },
            status: TaskStatus.Succeeded,
            outputs: { assetData, totalSize: 1000 } as IUploadAssetResult,
        }));

        const context = makeContext();
        const data = makeData({ dryRun: true });

        mockScanPaths.mockImplementation(async (_paths, visitFile) => {
            await visitFile({
                filePath: '/test/photos/img1.jpg',
                fileStat: { length: 1000, lastModified: new Date() },
                contentType: 'image/jpeg',
                labels: [],
                logicalPath: '/test/photos/img1.jpg',
            });
        });

        await importAssetsHandler(data, context);

        expect(context.sendMessage).toHaveBeenCalledWith(
            expect.objectContaining({ type: 'import-success', assetId })
        );
    });

    test('queues a hash-file task for each file found by scanPaths', async () => {
        const context = makeContext();
        const data = makeData();

        mockScanPaths.mockImplementation(async (paths, visitFile) => {
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

        await importAssetsHandler(data, context);

        const hashFileTasks = mockBackend.addedTasks.filter(task => task.type === 'hash-file');
        expect(hashFileTasks).toHaveLength(2);
        expect(hashFileTasks[0].data).toMatchObject({
            filePath: '/test/photos/img1.jpg',
            contentType: 'image/jpeg',
            storageDescriptor: data.storageDescriptor,
            sessionId: 'session-1',
            dryRun: false,
        });
        expect(hashFileTasks[1].data).toMatchObject({
            filePath: '/test/photos/img2.jpg',
        });
    });

    test('sends scan-progress messages during scanning', async () => {
        const context = makeContext();
        const data = makeData();

        mockScanPaths.mockImplementation(async (paths, visitFile, progressCallback) => {
            progressCallback!('/test/photos', { currentlyScanning: '/test/photos', numFilesIgnored: 0, numFilesFailed: 0, tempDir: '' });
        });

        await importAssetsHandler(data, context);

        expect(context.sendMessage).toHaveBeenCalledWith({
            type: 'scan-progress',
            currentPath: '/test/photos',
        });
    });

    test('sends file-ignored messages when files are ignored', async () => {
        const context = makeContext();
        const data = makeData();

        mockScanPaths.mockImplementation(async (paths, visitFile, progressCallback) => {
            progressCallback!(undefined, { currentlyScanning: undefined, numFilesIgnored: 2, numFilesFailed: 0, tempDir: '' });
        });

        await importAssetsHandler(data, context);

        const ignoredMessages = (context.sendMessage as jest.Mock).mock.calls.filter(
            (call) => call[0].type === 'file-ignored'
        );
        expect(ignoredMessages).toHaveLength(1);
        expect(ignoredMessages[0][0].count).toBe(2);
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

        await importAssetsHandler(data, context);

        const hashFileTasks = mockBackend.addedTasks.filter(task => task.type === 'hash-file');
        expect(hashFileTasks).toHaveLength(0);
    });

    test('skips duplicate hashes discovered in the same scan', async () => {
        const hashBuffer = Buffer.from('aabbcc', 'hex');
        const hashResult: IHashFileResult = {
            hash: new Uint8Array(hashBuffer),
            hashFromCache: false,
            filesAlreadyAdded: false,
        };

        // Both files return the same hash — second should be skipped.
        mockBackend.setTaskResult('hash-file', (data: IHashFileData, taskId) => ({
            taskId,
            type: 'hash-file',
            inputs: data,
            status: TaskStatus.Succeeded,
            outputs: hashResult,
        }));
        // upload-asset should auto-complete so awaitAllTasks resolves.
        mockBackend.setTaskResult('upload-asset', (data, taskId) => ({
            taskId,
            type: 'upload-asset',
            inputs: data,
            status: TaskStatus.Failed,
            errorMessage: 'test-skip',
        }));

        const context = makeContext();
        const data = makeData();

        mockScanPaths.mockImplementation(async (paths, visitFile) => {
            await visitFile({
                filePath: '/test/photos/img1.jpg',
                fileStat: { length: 1000, lastModified: new Date() },
                contentType: 'image/jpeg',
                labels: [],
                logicalPath: '/test/photos/img1.jpg',
            });
            await visitFile({
                filePath: '/test/photos/img2.jpg',
                fileStat: { length: 1000, lastModified: new Date() },
                contentType: 'image/jpeg',
                labels: [],
                logicalPath: '/test/photos/img2.jpg',
            });
        });

        await importAssetsHandler(data, context);

        // Only one upload-asset task should be queued (duplicate skipped).
        const uploadTasks = mockBackend.addedTasks.filter(task => task.type === 'upload-asset');
        expect(uploadTasks).toHaveLength(1);
    });

    test('sends import-skipped message when hash already in database', async () => {
        const assetId = 'test-asset-uuid';
        mockBackend.setTaskResult('hash-file', (data: IHashFileData, taskId) => ({
            taskId,
            type: 'hash-file',
            inputs: { ...data, assetId },
            status: TaskStatus.Succeeded,
            outputs: {
                hash: new Uint8Array(Buffer.from('aabbcc', 'hex')),
                hashFromCache: false,
                filesAlreadyAdded: true,
            } as IHashFileResult,
        }));

        const context = makeContext();
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

        await importAssetsHandler(data, context);

        expect(context.sendMessage).toHaveBeenCalledWith(
            expect.objectContaining({ type: 'import-skipped' })
        );
    });
});
