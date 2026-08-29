import { importAssetsHandler, IMPORT_RECORD_FLUSH_SIZE, DATABASE_BATCH_SIZE } from '../../lib/import-assets.worker';
import type { IImportAssetsData } from '../../lib/import-assets.worker';
import type { ITaskContext, IQueueBackend, ITaskResult, WorkerTaskCompletionCallback, UnsubscribeFn } from 'task-queue';
import { TaskStatus, setQueueBackend } from 'task-queue';
import type { IDatabaseDescriptor } from 'api';
import type { IHashFileData, IHashFileResult } from '../../lib/hash-file.worker';
import type { IUploadAssetData, IUploadAssetResult, IAssetDatabaseData } from '../../lib/upload-asset.worker';

// ── module mocks ─────────────────────────────────────────────────────────────

jest.mock('../../lib/file-scanner', () => ({
    scanPaths: jest.fn(),
}));

jest.mock('node-utils', () => ({
    ensureDir: jest.fn().mockResolvedValue(undefined),
    remove: jest.fn().mockResolvedValue(undefined),
    getProcessTmpDir: jest.fn().mockReturnValue('/tmp'),
}));

jest.mock('storage', () => ({
    createStorage: jest.fn().mockReturnValue({
        // read and write are here because the import writes what it took in to the database's import
        // record on the way out. This mock swallowError is a pass-through rather than a swallow, so a
        // storage that cannot be written surfaces here rather than being quietly ignored as it is in
        // production.
        storage: {
            read: jest.fn().mockResolvedValue(undefined),
            write: jest.fn().mockResolvedValue(undefined),
        },
        rawStorage: {},
        normalizedPath: '/test/db',
        type: 'fs',
    }),
    loadEncryptionKeysFromPem: jest.fn().mockResolvedValue({ options: {} }),
}));

// Records the mocked database already holds, which the import loads once at the start of a run to
// answer whether a hash is already there. A test that wants a photo to look already imported puts
// its hash in here.
const mockExistingDatabaseRecords: Array<{ _id: string; hash: string }> = [];

// What the database's state file says, which is how the import tells its own writes apart from
// another writer's. A test that wants the database to look changed by somebody else puts a
// different stamp in here between batches.
let mockDatabaseState: { lastModifiedAt?: string } | undefined = undefined;

// Makes each stamp different from the last, the way a real timestamp is.
let stampCounter = 0;

jest.mock("bdb", () => ({
    BsonDatabase: jest.fn().mockImplementation(() => ({
        collection: jest.fn().mockReturnValue({
            insertOne: jest.fn().mockResolvedValue(undefined),
            getAll: jest.fn().mockImplementation(async () => ({ records: mockExistingDatabaseRecords, next: undefined })),
            sortIndex: jest.fn().mockReturnValue({
                findByValue: jest.fn().mockResolvedValue([]),
            }),
        }),
        flush: jest.fn().mockResolvedValue(undefined),
        commit: jest.fn().mockResolvedValue(undefined),
    })),
}));

jest.mock('../../lib/create-auto-import-scanner', () => ({
    createAutoImportScanner: jest.fn(),
}));

jest.mock('../../lib/import-record-storage', () => ({
    recordImports: jest.fn().mockResolvedValue(undefined),
}));

jest.mock('../../lib/hash-cache', () => ({
    getHashCacheDir: jest.fn().mockReturnValue('/test/hash-cache'),
    HashCache: jest.fn().mockImplementation(() => ({
        load: jest.fn().mockResolvedValue(undefined),
        save: jest.fn().mockResolvedValue(undefined),
        addHash: jest.fn(),
        addSourceHash: jest.fn(),
        setAssetId: jest.fn(),
    })),
}));

jest.mock("api", () => ({
    ...jest.requireActual("api"),
    acquireWriteLock: jest.fn().mockResolvedValue(true),
    releaseWriteLock: jest.fn().mockResolvedValue(undefined),
    updateDatabaseConfig: jest.fn().mockResolvedValue(undefined),
    loadDatabaseState: jest.fn().mockImplementation(async () => mockDatabaseState),
}));

jest.mock('../../lib/tree', () => ({
    loadMerkleTree: jest.fn().mockResolvedValue({ nodes: [], databaseMetadata: { filesImported: 0 } }),
    saveMerkleTree: jest.fn().mockResolvedValue(undefined),
    // Behaves like the real stamp: it writes a new modified time into the database state, which is
    // what tells the next batch that the last writer was this run.
    stampDatabaseModified: jest.fn().mockImplementation(async () => {
        mockDatabaseState = { lastModifiedAt: `stamp-${stampCounter += 1}` };
    }),
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

jest.mock('../../lib/resolve-storage-credentials', () => ({
    resolveStorageCredentials: jest.fn().mockResolvedValue({
        s3Config: undefined,
        encryptionKeyPems: [],
        googleApiKey: undefined,
    }),
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

import { createAutoImportScanner } from '../../lib/create-auto-import-scanner';

const mockCreateAutoImportScanner = createAutoImportScanner as jest.MockedFunction<typeof createAutoImportScanner>;

import { recordImports } from '../../lib/import-record-storage';

const mockRecordImports = recordImports as jest.MockedFunction<typeof recordImports>;

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

    // The ids of the tasks that have been added and not yet completed, and the most there have ever
    // been at once. This is what the concurrency limit is measured against.
    private inFlightTaskIds: Set<string> = new Set();
    peakTasksInFlight = 0;

    // When true a task completes on a timer rather than on the next microtask, which lets the scan
    // run ahead of the completions. Without it the scan's own await lets each task finish before the
    // next file is offered, so only one is ever in flight and a concurrency test proves nothing.
    completeAfterTimeout = false;

    setTaskResult(type: string, factory: (data: any, taskId: string) => ITaskResult): void {
        this.resultFactories.set(type, factory);
    }

    addTask(type: string, data: any, source: string, taskId?: string): string {
        const id = taskId ?? `${type}-${this.addedTasks.length}`;
        this.addedTasks.push({ type, data, source, taskId: id });
        this.inFlightTaskIds.add(id);
        this.peakTasksInFlight = Math.max(this.peakTasksInFlight, this.inFlightTaskIds.size);
        const cbs = this.taskAddedCallbacks.get(source);
        if (cbs) {
            for (const cb of cbs) {
                cb(id);
            }
        }
        const factory = this.resultFactories.get(type);
        if (factory) {
            const result = factory(data, id);
            if (this.completeAfterTimeout) {
                setTimeout(() => { void this.fireCompletion({ ...result, taskId: id }); }, 0);
            }
            else {
                Promise.resolve().then(() => this.fireCompletion({ ...result, taskId: id }));
            }
        }
        return id;
    }

    async fireCompletion(result: ITaskResult): Promise<void> {
        this.inFlightTaskIds.delete(result.taskId);
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
        maxConcurrentChildTasks: 10,
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
    const storageDescriptor: IDatabaseDescriptor = {
        databasePath: '/test/db',
    };
    return {
        paths: ['/test/photos'],
        storageDescriptor,
        googleApiKey: undefined,
        sessionId: 'session-1',
        dryRun: false,
        ...overrides,
    };
}

// ── tests ────────────────────────────────────────────────────────────────────

describe('importAssetsHandler', () => {
    let mockBackend: MockBackend;

    beforeEach(() => {
        jest.clearAllMocks();
        // The default hash-file result below reports a zero hash, and the default expectation is that
        // it is already in the database so no upload is queued and the run can finish. That used to
        // be said by the task result; the import reads it from the database now, so it is said here.
        mockDatabaseState = undefined;
        stampCounter = 0;
        mockExistingDatabaseRecords.length = 0;
        mockExistingDatabaseRecords.push({ _id: "default-existing", hash: Buffer.from(new Uint8Array(3)).toString("hex") });
        mockBackend = new MockBackend();
        // Auto-complete hash-file tasks as "already added" by default so awaitAllTasks resolves.
        mockBackend.setTaskResult('hash-file', (data, taskId) => ({
            taskId,
            type: 'hash-file',
            inputs: data,
            status: TaskStatus.Succeeded,
            outputs: { hash: new Uint8Array(3), hashFromCache: false } as IHashFileResult,
        }));
        setQueueBackend(mockBackend);
    });

    test('no more child tasks than the configured limit are in flight at once, and every file is still hashed', async () => {
        const fileCount = 20;
        const limit = 3;
        mockBackend.completeAfterTimeout = true;

        // Every file is new, so each one needs an upload after its hash: both kinds of child task
        // count against the same limit, because both hold a worker.
        mockBackend.setTaskResult('hash-file', (hashData: IHashFileData, taskId) => ({
            taskId,
            type: 'hash-file',
            inputs: hashData,
            status: TaskStatus.Succeeded,
            outputs: {
                hash: new Uint8Array(Buffer.from(hashData.logicalPath.padEnd(6, '0').slice(0, 6), 'utf8')),
                hashFromCache: false,
            } as IHashFileResult,
        }));
        mockBackend.setTaskResult('upload-asset', (uploadData: IUploadAssetData, taskId) => ({
            taskId,
            type: 'upload-asset',
            inputs: uploadData,
            status: TaskStatus.Succeeded,
            outputs: {
                assetData: {
                    assetId: uploadData.assetId,
                    assetPath: `asset/${uploadData.assetId}`,
                    assetHash: 'aabbcc',
                    assetLength: 1000,
                    assetLastModified: new Date(),
                    assetRecord: { _id: uploadData.assetId } as any,
                } as IAssetDatabaseData,
                totalSize: 1000,
            } as IUploadAssetResult,
        }));

        mockScanPaths.mockImplementation(async (_paths, visitFile) => {
            for (let fileNumber = 0; fileNumber < fileCount; fileNumber += 1) {
                await visitFile({
                    filePath: `/test/photos/img${fileNumber}.jpg`,
                    fileStat: { length: 1000, lastModified: new Date() },
                    contentType: 'image/jpeg',
                    labels: [],
                    logicalPath: `/test/photos/img${fileNumber}.jpg`,
                });
            }
        });

        await importAssetsHandler(makeData(), makeContext({ maxConcurrentChildTasks: limit }));

        expect(mockBackend.peakTasksInFlight).toBeLessThanOrEqual(limit);
        expect(mockBackend.addedTasks.filter(task => task.type === 'hash-file')).toHaveLength(fileCount);
    });

    test('the limit is read from the task data, so a different caller gets a different limit', async () => {
        const fileCount = 20;
        mockBackend.completeAfterTimeout = true;

        mockScanPaths.mockImplementation(async (_paths, visitFile) => {
            for (let fileNumber = 0; fileNumber < fileCount; fileNumber += 1) {
                await visitFile({
                    filePath: `/test/photos/img${fileNumber}.jpg`,
                    fileStat: { length: 1000, lastModified: new Date() },
                    contentType: 'image/jpeg',
                    labels: [],
                    logicalPath: `/test/photos/img${fileNumber}.jpg`,
                });
            }
        });

        await importAssetsHandler(makeData(), makeContext({ maxConcurrentChildTasks: 2 }));
        expect(mockBackend.peakTasksInFlight).toBeLessThanOrEqual(2);

        const secondBackend = new MockBackend();
        secondBackend.completeAfterTimeout = true;
        secondBackend.setTaskResult('hash-file', (hashData, taskId) => ({
            taskId,
            type: 'hash-file',
            inputs: hashData,
            status: TaskStatus.Succeeded,
            outputs: { hash: new Uint8Array(3), hashFromCache: false } as IHashFileResult,
        }));
        setQueueBackend(secondBackend);

        await importAssetsHandler(makeData(), makeContext({ maxConcurrentChildTasks: 8 }));
        expect(secondBackend.peakTasksInFlight).toBeGreaterThan(2);
        expect(secondBackend.peakTasksInFlight).toBeLessThanOrEqual(8);
    });

    test('a missing or nonsensical concurrency limit fails loudly rather than importing unbounded', async () => {
        mockScanPaths.mockImplementation(async () => { /* never reached. */ });

        await expect(importAssetsHandler(makeData(), makeContext({ maxConcurrentChildTasks: 0 })))
            .rejects.toThrow('maxConcurrentChildTasks');
        await expect(importAssetsHandler(makeData(), makeContext({ maxConcurrentChildTasks: undefined as any })))
            .rejects.toThrow('maxConcurrentChildTasks');
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
        const { acquireWriteLock } = require('api');
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
            outputs: { hash: hashBuffer, hashFromCache: false } as IHashFileResult,
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
            addSourceHash: jest.fn(),
            setAssetId: jest.fn(),
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
            collection: jest.fn().mockReturnValue({
                insertOne: mockInsertOne,
                getAll: jest.fn().mockImplementation(async () => ({ records: mockExistingDatabaseRecords, next: undefined })),
                sortIndex: jest.fn().mockReturnValue({ findByValue: jest.fn().mockResolvedValue([]) }),
            }),
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
            outputs: { hash: hashBuffer, hashFromCache: false } as IHashFileResult,
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
            outputs: { hash: hashBuffer, hashFromCache: false } as IHashFileResult,
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
            hashMs: 0,
            cacheLookupMs: 0,
            taskMs: 0,
            cacheLoadMs: 0,
            bytesHashed: 0,
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

        // The database already holds this hash. The import loads that once at the start of a run,
        // rather than asking per file, so this is where a photo becomes already-imported.
        mockExistingDatabaseRecords.push({ _id: 'existing-asset', hash: Buffer.from('aabbcc', 'hex').toString('hex') });
        mockBackend.setTaskResult('hash-file', (data: IHashFileData, taskId) => ({
            taskId,
            type: 'hash-file',
            inputs: { ...data, assetId },
            status: TaskStatus.Succeeded,
            outputs: {
                hash: new Uint8Array(Buffer.from('aabbcc', 'hex')),
                hashFromCache: false,
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

    //
    // Replaces the HashCache mock with one whose calls can be read back, and returns it.
    //
    function watchHashCache() {
        const { HashCache } = require('../../lib/hash-cache');
        const watched = {
            load: jest.fn().mockResolvedValue(undefined),
            save: jest.fn().mockResolvedValue(undefined),
            addHash: jest.fn(),
            addSourceHash: jest.fn(),
            setAssetId: jest.fn(),
        };
        HashCache.mockImplementation(() => watched);
        return watched;
    }

    //
    // A scan that finds one file at the given path.
    //
    function scanFindsOneFile(filePath: string): void {
        mockScanPaths.mockImplementation(async (_paths, visitFile) => {
            await visitFile({
                filePath,
                fileStat: { length: 1000, lastModified: new Date(5000) },
                contentType: 'image/jpeg',
                labels: [],
                logicalPath: filePath,
            });
        });
    }

    //
    // Makes hash-file report a freshly computed hash for a file that is not in the database.
    //
    function hashFileReportsNewFile(): void {
        mockBackend.setTaskResult('hash-file', (hashData: IHashFileData, taskId) => ({
            taskId,
            type: 'hash-file',
            inputs: hashData,
            status: TaskStatus.Succeeded,
            outputs: {
                hash: new Uint8Array(Buffer.from('aabbcc', 'hex')),
                hashFromCache: false,
            } as IHashFileResult,
        }));
    }

    //
    // Makes upload-asset succeed, reporting the asset id it was given.
    //
    function uploadSucceeds(): void {
        mockBackend.setTaskResult('upload-asset', (uploadData: IUploadAssetData, taskId) => ({
            taskId,
            type: 'upload-asset',
            inputs: uploadData,
            status: TaskStatus.Succeeded,
            outputs: {
                assetData: {
                    assetId: uploadData.assetId,
                    assetPath: `asset/${uploadData.assetId}`,
                    assetHash: 'aabbcc',
                    assetLength: 1000,
                    assetLastModified: new Date(),
                    assetRecord: { _id: uploadData.assetId } as any,
                } as IAssetDatabaseData,
                totalSize: 1000,
            } as IUploadAssetResult,
        }));
    }

    // The identity automatic import supplies for one photo library item, and the temporary path the
    // item was copied out to.
    const EXPORTED_PATH = '/test/exported/copy-1.jpg';
    const SOURCE_IDENTITY = { key: '1000000042', length: 4096, lastModified: 1700000000000 };

    //
    // Makes the import build an automatic scanner that pushes one photo library item, with the
    // identity that item is filed under. This is the path automatic import takes: the identity comes
    // from the scanner as it pushes the file, not from the task data.
    //
    function autoImportScannerPushesOneItem(overrides: { caughtUp?: boolean } = {}): { release: jest.Mock } {
        const release = jest.fn().mockResolvedValue(undefined);
        mockCreateAutoImportScanner.mockImplementation(async (options: any) => ({
            scan: async (visitFile: any) => {
                // Reported exactly as the real scanner reports it, because the counters the panel
                // shows are made by the import out of this plus what it imported itself.
                options.onProgress({ backfillRemaining: 3, backfillComplete: false, currentItem: "a photo", skippedAsAlreadyImported: 1, caughtUp: overrides.caughtUp ?? true });
                await visitFile({
                    filePath: EXPORTED_PATH,
                    fileStat: { length: 1000, lastModified: new Date(5000) },
                    contentType: 'image/jpeg',
                    labels: [],
                    logicalPath: EXPORTED_PATH,
                    cacheIdentity: SOURCE_IDENTITY,
                });
            },
            release,
        }) as any);
        return { release };
    }

    //
    // The task data an automatic import is started with.
    //
    function autoImportData() {
        return makeData({ paths: [], options: { auto: true, sources: [{ type: "folder", path: "/photos", recurse: true }] } as any });
    }

    test('hands each hash-file task the identity supplied for its path', async () => {
        watchHashCache();
        hashFileReportsNewFile();
        uploadSucceeds();
        autoImportScannerPushesOneItem();

        await importAssetsHandler(autoImportData(), makeContext());

        const hashFileTask = mockBackend.addedTasks.find(task => task.type === 'hash-file');
        expect(hashFileTask!.data.cacheIdentity).toEqual(SOURCE_IDENTITY);
    });

    test('hands an ordinary file no identity at all, which is what keeps manual import unchanged', async () => {
        watchHashCache();
        hashFileReportsNewFile();
        uploadSucceeds();
        scanFindsOneFile('/test/photos/img1.jpg');

        await importAssetsHandler(makeData(), makeContext());

        const hashFileTask = mockBackend.addedTasks.find(task => task.type === 'hash-file');
        expect(hashFileTask!.data.cacheIdentity).toBeUndefined();
    });

    test('files a photo library item under its source id, against the size and time the library reported', async () => {
        // Not under the temporary path or the copy's own modified time: the copy is deleted the moment
        // the import finishes, so an entry describing it would never match anything again.
        const hashCache = watchHashCache();
        hashFileReportsNewFile();
        uploadSucceeds();
        autoImportScannerPushesOneItem();

        await importAssetsHandler(autoImportData(), makeContext());

        expect(hashCache.addSourceHash).toHaveBeenCalledWith('1000000042', {
            hash: Buffer.from('aabbcc', 'hex'),
            length: 4096,
            lastModified: new Date(1700000000000),
        });
        expect(hashCache.addHash).not.toHaveBeenCalled();
    });

    test('files an ordinary file under its own path and its own stat', async () => {
        const hashCache = watchHashCache();
        hashFileReportsNewFile();
        uploadSucceeds();
        scanFindsOneFile('/test/photos/img1.jpg');

        await importAssetsHandler(makeData(), makeContext());

        expect(hashCache.addHash).toHaveBeenCalledWith('/test/photos/img1.jpg', {
            hash: Buffer.from('aabbcc', 'hex'),
            length: 1000,
            lastModified: new Date(5000),
        });
        expect(hashCache.addSourceHash).not.toHaveBeenCalled();
    });

    test('records the asset id against the cache entry once the database write has landed', async () => {
        const hashCache = watchHashCache();
        hashFileReportsNewFile();
        uploadSucceeds();
        autoImportScannerPushesOneItem();

        await importAssetsHandler(autoImportData(), makeContext());

        // Under the source id, because that is what the entry is filed under, and with the id the
        // upload reported rather than anything invented here.
        expect(hashCache.setAssetId).toHaveBeenCalledWith('1000000042', expect.any(String));
    });

    test('records the id of an asset the database already held, so it is not looked up again', async () => {
        // The database holds this hash, which is what makes it already-imported. The import reads
        // that from the map it builds when the run starts, not from the task result.
        mockExistingDatabaseRecords.push({ _id: "asset-already-there", hash: Buffer.from("aabbcc", "hex").toString("hex") });
        const hashCache = watchHashCache();
        mockBackend.setTaskResult('hash-file', (hashData: IHashFileData, taskId) => ({
            taskId,
            type: 'hash-file',
            inputs: hashData,
            status: TaskStatus.Succeeded,
            outputs: {
                hash: new Uint8Array(Buffer.from('aabbcc', 'hex')),
                hashFromCache: false,
            } as IHashFileResult,
        }));
        autoImportScannerPushesOneItem();

        await importAssetsHandler(autoImportData(), makeContext());

        expect(hashCache.setAssetId).toHaveBeenCalledWith('1000000042', 'asset-already-there');
    });

    test("writes the import record part way through a long import, not only at the end", async () => {
        // An import of two thousand photos that died at nineteen hundred used to write no record at
        // all, because the record was only written in the finally at the end of the run. Automatic
        // import made that worse: a run that goes on until the app quits never reaches the end.
        const fileCount = IMPORT_RECORD_FLUSH_SIZE + 5;
        watchHashCache();
        mockScanPaths.mockImplementation(async (_paths, visitFile) => {
            for (let fileNumber = 0; fileNumber < fileCount; fileNumber += 1) {
                await visitFile({
                    filePath: `/test/photos/img${fileNumber}.jpg`,
                    fileStat: { length: 1000, lastModified: new Date(5000) },
                    contentType: 'image/jpeg',
                    labels: [],
                    logicalPath: `/test/photos/img${fileNumber}.jpg`,
                });
            }
        });

        await importAssetsHandler(makeData(), makeContext());

        // One flush at the hundred mark, and one at the end for the five that were left.
        expect(mockRecordImports).toHaveBeenCalledTimes(2);
        expect(mockRecordImports.mock.calls[0][1]).toHaveLength(IMPORT_RECORD_FLUSH_SIZE);
        expect(mockRecordImports.mock.calls[1][1]).toHaveLength(5);
    });

    test("writes the import record once at the end of a short import", async () => {
        watchHashCache();
        scanFindsOneFile('/test/photos/img1.jpg');

        await importAssetsHandler(makeData(), makeContext());

        expect(mockRecordImports).toHaveBeenCalledTimes(1);
        expect(mockRecordImports.mock.calls[0][1]).toHaveLength(1);
    });

    test("a dry run records nothing, because it changed nothing", async () => {
        watchHashCache();
        scanFindsOneFile('/test/photos/img1.jpg');

        await importAssetsHandler(makeData({ dryRun: true }), makeContext());

        expect(mockRecordImports).not.toHaveBeenCalled();
    });

    test("releases each file once the import has finished with it", async () => {
        // On a phone this is what deletes the copy that had to be made to read the photo at all.
        // Doing it per file rather than at the end of the run is what keeps a long automatic import
        // from filling the sandbox with copies of every photo it has ever looked at.
        const { release } = autoImportScannerPushesOneItem();
        hashFileReportsNewFile();
        uploadSucceeds();

        await importAssetsHandler(autoImportData(), makeContext());

        expect(release).toHaveBeenCalledWith(EXPORTED_PATH);
    });

    test("releases a file the database already held", async () => {
        // The database holds this hash, which is what makes it already-imported. The import reads
        // that from the map it builds when the run starts, not from the task result.
        mockExistingDatabaseRecords.push({ _id: "existing-asset", hash: Buffer.from("aabbcc", "hex").toString("hex") });
        const { release } = autoImportScannerPushesOneItem();
        mockBackend.setTaskResult('hash-file', (hashData: IHashFileData, taskId) => ({
            taskId,
            type: 'hash-file',
            inputs: hashData,
            status: TaskStatus.Succeeded,
            outputs: {
                hash: new Uint8Array(Buffer.from('aabbcc', 'hex')),
                hashFromCache: false,
            } as IHashFileResult,
        }));

        await importAssetsHandler(autoImportData(), makeContext());

        expect(release).toHaveBeenCalledWith(EXPORTED_PATH);
    });

    test("reports what an automatic import is doing, so the panel has something to show", async () => {
        // The counters used to be produced by a separate loop task. Deleting that task left the panel
        // with no producer at all, so the import itself sends them now.
        autoImportScannerPushesOneItem();
        hashFileReportsNewFile();
        uploadSucceeds();
        const context = makeContext();

        await importAssetsHandler(autoImportData(), context);

        expect(context.sendMessage).toHaveBeenCalledWith(
            expect.objectContaining({ type: 'import-progress' })
        );
    });

    test("reports what a manual import is doing, through the very same message", async () => {
        watchHashCache();
        hashFileReportsNewFile();
        uploadSucceeds();
        scanFindsOneFile('/test/photos/img1.jpg');
        const context = makeContext();

        await importAssetsHandler(makeData(), context);

        // One kind of progress message, sent by both kinds of import. The panel shows either without
        // knowing which it is watching.
        expect(context.sendMessage).toHaveBeenCalledWith(
            expect.objectContaining({ type: 'import-progress' })
        );
        // It does not badge what the user imported by hand as something that arrived on its own.
        expect(context.sendMessage).not.toHaveBeenCalledWith(
            expect.objectContaining({ type: 'import-success', source: 'automatic' })
        );
    });

    test("names the database an automatic arrival landed in, which the gallery needs", async () => {
        // Automatic import writes to the default database, which is not necessarily the one on
        // screen. An arrival in another database is not that gallery's to show.
        autoImportScannerPushesOneItem();
        hashFileReportsNewFile();
        uploadSucceeds();
        const context = makeContext();

        await importAssetsHandler(autoImportData(), context);

        expect(context.sendMessage).toHaveBeenCalledWith(
            expect.objectContaining({ type: 'import-success', databasePath: '/test/db', source: 'automatic' })
        );
    });

    test("saves the hash cache as soon as the scanner has nothing left to import", async () => {
        // An import that never ends has no end at which to save. Automatic import brings in a
        // handful of photos and then waits, so without this the next run hashes and copies the same
        // photos again, and a cleanup that reads the cache from another process sees nothing.
        const hashCache = watchHashCache();
        hashFileReportsNewFile();
        uploadSucceeds();
        autoImportScannerPushesOneItem();

        await importAssetsHandler(autoImportData(), makeContext());

        expect(hashCache.save).toHaveBeenCalled();
    });

    test("writes fewer assets than a batch holds rather than stranding them", async () => {
        // Assets are held back until a batch is worth committing, because every batch pays for a
        // full database commit whatever its size. What that must never do is strand the last few:
        // a run that took in fewer than a batch's worth has to write them anyway, and a phone
        // taking in one photo is exactly that run.
        //
        // What this covers is the run ending with a part-filled batch. It does NOT cover the other
        // way a part-filled batch goes out, which is a long-lived automatic import going idle with
        // a few assets in hand: that needs a run that stays alive while the scanner reports itself
        // caught up, which this harness has no way to hold open.
        hashFileReportsNewFile();
        uploadSucceeds();
        autoImportScannerPushesOneItem();

        const result = await importAssetsHandler(autoImportData(), makeContext());

        expect(result.imported).toHaveLength(1);
        expect(result.timings.databaseBatches).toBe(1);
    });



    test("does not give every photo its own database commit once the scanner is caught up", async () => {
        // The scanner says it is caught up the moment it has read the library to the end, which on a
        // backfill happens while the photos it already handed over are still being hashed and
        // uploaded. Writing then, because "what is waiting is all there is", gave each of those
        // remaining photos a full database commit to itself, and a commit rewrites every shard it
        // touches, so it costs more the bigger the database is.
        // A hash per file rather than one for all of them, so all five are new files rather than
        // four duplicates of the first.
        mockBackend.setTaskResult("hash-file", (hashData: IHashFileData, taskId) => ({
            taskId,
            type: "hash-file",
            inputs: hashData,
            status: TaskStatus.Succeeded,
            outputs: {
                hash: new Uint8Array(Buffer.from("aabbc" + hashData.filePath.slice(-1), "hex")),
                hashFromCache: false,
            } as IHashFileResult,
        }));
        uploadSucceeds();

        const release = jest.fn().mockResolvedValue(undefined);
        mockCreateAutoImportScanner.mockImplementation(async (options: any) => ({
            scan: async (visitFile: any) => {
                options.onProgress({ backfillRemaining: 0, backfillComplete: true, currentItem: "a photo", skippedAsAlreadyImported: 0, caughtUp: true });
                for (let photoNumber = 0; photoNumber < 5; photoNumber += 1) {
                    await visitFile({
                        filePath: `${EXPORTED_PATH}-${photoNumber}`,
                        fileStat: { length: 1000, lastModified: new Date(5000) },
                        contentType: 'image/jpeg',
                        labels: [],
                        logicalPath: `${EXPORTED_PATH}-${photoNumber}`,
                        cacheIdentity: { key: `100000004${photoNumber}`, length: 4096, lastModified: 1700000000000 },
                    });
                }
            },
            release,
        }) as any);

        const result = await importAssetsHandler(autoImportData(), makeContext());

        expect(result.imported).toHaveLength(5);
        expect(result.timings.databaseBatches).toBe(1);
    });
    test("does not save the hash cache while the scanner still has work to hand over", async () => {
        const hashCache = watchHashCache();
        hashFileReportsNewFile();
        uploadSucceeds();
        autoImportScannerPushesOneItem({ caughtUp: false });

        await importAssetsHandler(autoImportData(), makeContext());

        // Only the save at the end of the run, which every import does.
        expect(hashCache.save).toHaveBeenCalledTimes(1);
    });

    //
    // Dropping the database's cached shards and index pages before a batch is written.
    //
    // Dropping them makes the batch read back what it already had: about one and three quarter reads
    // per record against none when they are kept, and those reads grow with the database because an
    // index page holds every record in it. They are dropped only when the database's own modified
    // stamp differs from the one this run last wrote, which is what says somebody else has written.
    //
    function importOneBatchOfNewFiles(): { flush: jest.Mock; commit: jest.Mock } {
        const { BsonDatabase } = require("bdb");
        const databaseFlush = jest.fn().mockResolvedValue(undefined);
        const databaseCommit = jest.fn().mockResolvedValue(undefined);
        BsonDatabase.mockImplementation(() => ({
            collection: jest.fn().mockReturnValue({
                insertOne: jest.fn().mockResolvedValue(undefined),
                getAll: jest.fn().mockImplementation(async () => ({ records: mockExistingDatabaseRecords, next: undefined })),
                sortIndex: jest.fn().mockReturnValue({ findByValue: jest.fn().mockResolvedValue([]) }),
            }),
            flush: databaseFlush,
            commit: databaseCommit,
        }));

        hashFileReportsNewFile();
        uploadSucceeds();
        scanFindsOneFile('/test/photos/img1.jpg');

        return { flush: databaseFlush, commit: databaseCommit };
    }

    test("drops the database's cached pages when the database was last written by something else", async () => {
        watchHashCache();
        const database = importOneBatchOfNewFiles();
        mockDatabaseState = { lastModifiedAt: 'written-by-an-earlier-run' };

        await importAssetsHandler(makeData(), makeContext());

        expect(database.commit).toHaveBeenCalledTimes(1);
        expect(database.flush).toHaveBeenCalled();
    });

    test("keeps the database's cached pages when nothing has written to it", async () => {
        watchHashCache();
        const database = importOneBatchOfNewFiles();
        mockDatabaseState = undefined;

        await importAssetsHandler(makeData(), makeContext());

        expect(database.commit).toHaveBeenCalledTimes(1);
        expect(database.flush).not.toHaveBeenCalled();
    });
});
