import * as fsSync from "fs";
import * as path from "path";
import type { ITaskContext, IQueueBackend, ITaskResult, TaskMessageCallback, UnsubscribeFn, WorkerTaskCompletionCallback } from "task-queue";
import { setQueueBackend, TaskStatus } from "task-queue";
import { addItem, createTree } from "merkle-tree";
import { createTestTempDir } from "node-utils";

jest.mock("../../lib/resolve-storage-credentials", () => ({
    resolveStorageCredentials: jest.fn().mockResolvedValue({
        s3Config: undefined,
        encryptionKeyPems: [],
        googleApiKey: undefined,
    }),
}));

jest.mock("storage", () => ({
    createStorage: jest.fn().mockReturnValue({ storage: {}, rawStorage: {} }),
    loadEncryptionKeysFromPem: jest.fn().mockResolvedValue({ options: {} }),
}));

jest.mock("../../lib/tree", () => ({
    loadMerkleTree: jest.fn().mockResolvedValue(undefined),
}));

jest.mock("api", () => ({
    ...jest.requireActual("api"),
    loadDatabaseState: jest.fn().mockResolvedValue(undefined),
    updateDatabaseStateLocked: jest.fn().mockResolvedValue(undefined),
}));

import { loadDatabaseState, updateDatabaseStateLocked, IAutoImportSettings, IDatabaseDescriptor } from "api";
import { loadMerkleTree } from "../../lib/tree";
import { autoImportHandler, IAutoImportData, IAutoImportProgressMessage, IAutoImportItemMessage } from "../../lib/auto-import.worker";

const mockLoadDatabaseState = loadDatabaseState as jest.MockedFunction<typeof loadDatabaseState>;
const mockUpdateDatabaseStateLocked = updateDatabaseStateLocked as jest.MockedFunction<typeof updateDatabaseStateLocked>;
const mockLoadMerkleTree = loadMerkleTree as jest.MockedFunction<typeof loadMerkleTree>;

//
// How a fake import task behaves for one path handed to it.
//
type ImportOutcome = "success" | "skipped" | "failed";

//
// A queue backend that stands in for the worker pool, running a fake "import-assets" task that
// reports whatever outcome the test asked for.
//
class MockBackend implements IQueueBackend {
    // Every task that was added, so a test can see what the auto-import task asked for.
    addedTasks: { type: string, data: any, taskId: string }[] = [];

    // The outcome the fake import reports for each path, by file name. Anything not named succeeds.
    outcomesByFileName = new Map<string, ImportOutcome>();

    // When true the whole import task fails, rather than reporting per-file outcomes.
    failWholeImportTask = false;

    // The content hash the fake import reports for each imported path, by file name.
    hashesByFileName = new Map<string, string>();

    private taskAddedCallbacks = new Map<string, ((taskId: string) => void)[]>();
    private completionCallbacks: WorkerTaskCompletionCallback[] = [];
    private anyMessageCallbacks: TaskMessageCallback[] = [];
    private nextTaskNumber = 0;

    addTask(type: string, data: any, source: string, taskId?: string): string {
        const id = taskId ?? `${type}-${this.nextTaskNumber++}`;
        this.addedTasks.push({ type, data, taskId: id });

        for (const callback of this.taskAddedCallbacks.get(source) ?? []) {
            callback(id);
        }

        if (type === "import-assets") {
            Promise.resolve().then(async () => {
                await this.runFakeImport(id, data);
            });
        }

        return id;
    }

    //
    // Reports the outcome for each path in the task's result, exactly as the real import task does.
    // The result is how an orchestrator task learns what happened: a worker sees a child task's
    // completion but not its messages.
    //
    private async runFakeImport(taskId: string, data: any): Promise<void> {
        if (this.failWholeImportTask) {
            await this.fireCompletion({
                taskId,
                type: "import-assets",
                status: TaskStatus.Failed,
                errorMessage: "The database is unavailable.",
                inputs: data,
                outputs: undefined,
            });
            return;
        }

        const outputs = { imported: [] as any[], skipped: [] as any[], failedCount: 0 };

        for (const filePath of data.paths as string[]) {
            const fileName = path.basename(filePath);
            const outcome = this.outcomesByFileName.get(fileName) ?? "success";

            if (outcome === "success") {
                outputs.imported.push({
                    assetId: `asset-${fileName}`,
                    logicalPath: filePath,
                    asset: {
                        _id: `asset-${fileName}`,
                        hash: this.hashesByFileName.get(fileName) ?? `hash-${fileName}`,
                    },
                });
            }
            else if (outcome === "skipped") {
                outputs.skipped.push({
                    logicalPath: filePath,
                    contentHash: this.hashesByFileName.get(fileName) ?? `hash-${fileName}`,
                });
            }
            else {
                outputs.failedCount += 1;
            }
        }

        await this.fireCompletion({
            taskId,
            type: "import-assets",
            status: TaskStatus.Succeeded,
            inputs: data,
            outputs,
        });
    }

    private async fireCompletion(result: ITaskResult): Promise<void> {
        for (const callback of [...this.completionCallbacks]) {
            await callback(result);
        }
    }

    onTaskAdded(source: string, callback: (taskId: string) => void): UnsubscribeFn {
        const existing = this.taskAddedCallbacks.get(source) ?? [];
        existing.push(callback);
        this.taskAddedCallbacks.set(source, existing);
        return () => {};
    }

    onTaskComplete(callback: WorkerTaskCompletionCallback): UnsubscribeFn {
        this.completionCallbacks.push(callback);
        return () => {
            const index = this.completionCallbacks.indexOf(callback);
            if (index !== -1) {
                this.completionCallbacks.splice(index, 1);
            }
        };
    }

    onTaskMessage(messageType: string, callback: TaskMessageCallback): UnsubscribeFn {
        return () => {};
    }

    onAnyTaskMessage(callback: TaskMessageCallback): UnsubscribeFn {
        this.anyMessageCallbacks.push(callback);
        return () => {
            const index = this.anyMessageCallbacks.indexOf(callback);
            if (index !== -1) {
                this.anyMessageCallbacks.splice(index, 1);
            }
        };
    }

    cancelTasks(source: string): void {
    }

    onTasksCancelled(source: string, callback: () => void): UnsubscribeFn {
        return () => {};
    }

    shutdown(): void {
    }
}

//
// The messages the task sent, so a test can assert on what the user interface would have seen.
//
interface ISentMessages {
    // Every progress message, in order.
    progress: IAutoImportProgressMessage[];

    // Every per-item message, in order.
    items: IAutoImportItemMessage[];
}

describe("autoImportHandler", () => {

    let tempDir: string;
    let photosDir: string;
    let backend: MockBackend;
    let cancelled: boolean;
    let sentMessages: ISentMessages;

    const storageDescriptor: IDatabaseDescriptor = { databasePath: "/test/db" } as IDatabaseDescriptor;

    beforeEach(() => {
        tempDir = createTestTempDir("auto-import-worker");
        photosDir = path.join(tempDir, "photos");
        fsSync.mkdirSync(photosDir, { recursive: true });
        process.env.PHOTOSPHERE_TMP_DIR = tempDir;

        backend = new MockBackend();
        setQueueBackend(backend);

        cancelled = false;
        sentMessages = { progress: [], items: [] };

        mockLoadDatabaseState.mockResolvedValue(undefined);
        mockUpdateDatabaseStateLocked.mockResolvedValue(undefined);
        mockLoadMerkleTree.mockResolvedValue(undefined);
    });

    //
    // Writes a photo that was already in the folder before the task started, so it belongs to the
    // backfill. The age is set explicitly rather than left at "now", because a file written in the
    // same millisecond the task starts counts as an arrival and would take the other lane.
    //
    function writePhoto(fileName: string, contents: string): string {
        const filePath = path.join(photosDir, fileName);
        fsSync.writeFileSync(filePath, contents);
        const anHourAgo = new Date(Date.now() - 3600000);
        fsSync.utimesSync(filePath, anHourAgo, anHourAgo);
        return filePath;
    }

    //
    // Writes a photo that has just been taken, so it belongs to the fast lane.
    //
    function writeNewPhoto(fileName: string, contents: string): string {
        const filePath = path.join(photosDir, fileName);
        fsSync.writeFileSync(filePath, contents);
        const inAMoment = new Date(Date.now() + 1000);
        fsSync.utimesSync(filePath, inAMoment, inAMoment);
        return filePath;
    }

    //
    // A task context that records messages and reports cancellation on demand.
    //
    function makeContext(): ITaskContext {
        let uuidCounter = 0;
        return {
            uuidGenerator: { generate: () => `test-uuid-${uuidCounter++}` },
            timestampProvider: { now: () => Date.now(), dateNow: () => new Date() },
            sessionId: "session-1",
            taskId: "auto-import-task",
            sendMessage: (message: any) => {
                if (message.type === "auto-import-progress") {
                    sentMessages.progress.push(message);
                }
                else if (message.type === "auto-import-item") {
                    sentMessages.items.push(message);
                }
            },
            isCancelled: () => cancelled,
        } as ITaskContext;
    }

    //
    // The settings for a single watched folder.
    //
    function settingsFor(cleanupEnabled: boolean): IAutoImportSettings {
        return {
            enabled: true,
            sources: [{ type: "folder", path: photosDir, recurse: true }],
            cleanupEnabled,
            backfillItemsPerMinute: 60,
            pollIntervalMs: 50,
        };
    }

    //
    // The task data for a single pass over the watched folder.
    //
    function singlePassData(cleanupEnabled: boolean): IAutoImportData {
        return {
            storageDescriptor,
            settings: settingsFor(cleanupEnabled),
            sessionId: "session-1",
            once: true,
        };
    }

    //
    // The paths handed to every import task that was queued.
    //
    function importedPaths(): string[] {
        return backend.addedTasks
            .filter(task => task.type === "import-assets")
            .flatMap(task => task.data.paths as string[]);
    }

    test("refuses to run with no sources configured", async () => {
        const data: IAutoImportData = {
            storageDescriptor,
            settings: { ...settingsFor(false), sources: [] },
            sessionId: "session-1",
            once: true,
        };

        await expect(autoImportHandler(data, makeContext())).rejects.toThrow(/no sources configured/i);
    });

    test("imports the files already in the watched folder", async () => {
        writePhoto("a.jpg", "one");
        writePhoto("b.jpg", "two");

        const result = await autoImportHandler(singlePassData(false), makeContext());

        expect(importedPaths().map(filePath => path.basename(filePath)).sort()).toEqual(["a.jpg", "b.jpg"]);
        expect(result.imported).toBe(2);
        expect(result.seen).toBe(2);
        expect(result.failed).toBe(0);
        expect(result.backfillComplete).toBe(true);
    });

    test("queues the import against the right database", async () => {
        writePhoto("a.jpg", "one");

        await autoImportHandler(singlePassData(false), makeContext());

        const importTask = backend.addedTasks.find(task => task.type === "import-assets");
        expect(importTask!.data.storageDescriptor).toBe(storageDescriptor);
        expect(importTask!.data.sessionId).toBe("session-1");
        expect(importTask!.data.dryRun).toBe(false);
    });

    test("counts an item the import recognised as already present", async () => {
        writePhoto("a.jpg", "one");
        writePhoto("b.jpg", "two");
        backend.outcomesByFileName.set("b.jpg", "skipped");

        const result = await autoImportHandler(singlePassData(false), makeContext());

        expect(result.imported).toBe(1);
        expect(result.skipped).toBe(1);
    });

    test("carries on after one item fails to import", async () => {
        writePhoto("a.jpg", "one");
        writePhoto("b.jpg", "two");
        writePhoto("c.jpg", "three");
        backend.outcomesByFileName.set("b.jpg", "failed");

        const result = await autoImportHandler(singlePassData(false), makeContext());

        expect(result.imported).toBe(2);
        expect(result.failed).toBe(1);
        expect(importedPaths()).toHaveLength(3);
    });

    test("a whole import batch that fails counts every item in it as failed", async () => {
        writePhoto("a.jpg", "one");
        writePhoto("b.jpg", "two");
        backend.failWholeImportTask = true;

        const result = await autoImportHandler(singlePassData(false), makeContext());

        expect(result.imported).toBe(0);
        expect(result.failed).toBe(2);
    });

    test("emits a progress message and an item message per import", async () => {
        writePhoto("a.jpg", "one");
        writePhoto("b.jpg", "two");

        await autoImportHandler(singlePassData(false), makeContext());

        expect(sentMessages.items.map(message => path.basename(message.logicalPath)).sort()).toEqual(["a.jpg", "b.jpg"]);
        expect(sentMessages.items[0].asset).toBeDefined();
        expect(sentMessages.progress.length).toBeGreaterThan(0);

        const finalProgress = sentMessages.progress[sentMessages.progress.length - 1];
        expect(finalProgress.imported).toBe(2);
        expect(finalProgress.currentItem).toBeDefined();
    });

    test("does nothing but finish when the folder is empty", async () => {
        const result = await autoImportHandler(singlePassData(false), makeContext());

        expect(importedPaths()).toEqual([]);
        expect(result.imported).toBe(0);
        expect(result.backfillComplete).toBe(true);
    });

    test("persists the backfill position once the library has been walked", async () => {
        writePhoto("a.jpg", "one");

        await autoImportHandler(singlePassData(false), makeContext());

        expect(mockUpdateDatabaseStateLocked).toHaveBeenCalled();
        const lastCall = mockUpdateDatabaseStateLocked.mock.calls[mockUpdateDatabaseStateLocked.mock.calls.length - 1];
        expect(lastCall[2]).toEqual({
            autoImportBackfillCursor: undefined,
            autoImportBackfillCompleted: true,
        });
    });

    test("a completed backfill is not walked again", async () => {
        writePhoto("a.jpg", "one");
        mockLoadDatabaseState.mockResolvedValue({ autoImportBackfillCompleted: true });

        const result = await autoImportHandler(singlePassData(false), makeContext());

        // The library is already done, so the only thing left is the arrival walk, which treats
        // everything unseen as new now that the backfill has finished.
        expect(result.backfillComplete).toBe(true);
        expect(importedPaths().map(filePath => path.basename(filePath))).toEqual(["a.jpg"]);
    });

    test("stops when the task is cancelled", async () => {
        for (const name of ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]) {
            writePhoto(name, name);
        }

        // Paced at one item per second and never finished, so the run only ends by being cancelled.
        const data: IAutoImportData = {
            storageDescriptor,
            settings: settingsFor(false),
            sessionId: "session-1",
            once: false,
        };

        setTimeout(() => { cancelled = true; }, 400);
        const result = await autoImportHandler(data, makeContext());

        expect(result.backfillComplete).toBe(false);
        expect(importedPaths().length).toBeLessThan(4);
    });

    test("imports a photo that appears after the task has started", async () => {
        const data: IAutoImportData = {
            storageDescriptor,
            settings: settingsFor(false),
            sessionId: "session-1",
            once: false,
        };

        // The folder starts empty, so the backfill finishes at once and the only thing left is the
        // arrival watch.
        setTimeout(() => { writeNewPhoto("just-taken.jpg", "click"); }, 150);
        setTimeout(() => { cancelled = true; }, 1200);

        const result = await autoImportHandler(data, makeContext());

        expect(importedPaths().map(filePath => path.basename(filePath))).toEqual(["just-taken.jpg"]);
        expect(result.imported).toBe(1);
    });

    test("a new arrival is not imported twice by later polls", async () => {
        const data: IAutoImportData = {
            storageDescriptor,
            settings: settingsFor(false),
            sessionId: "session-1",
            once: false,
        };

        setTimeout(() => { writeNewPhoto("just-taken.jpg", "click"); }, 150);
        setTimeout(() => { cancelled = true; }, 1500);

        const result = await autoImportHandler(data, makeContext());

        expect(importedPaths()).toHaveLength(1);
        expect(result.imported).toBe(1);
    });

    test("resumes the backfill from a persisted cursor", async () => {
        for (const name of ["a.jpg", "b.jpg", "c.jpg"]) {
            writePhoto(name, name);
        }
        // The cursor names where the source listing resumes: the folder source's cursor is the path
        // of the last item of the previous page.
        mockLoadDatabaseState.mockResolvedValue({ autoImportBackfillCursor: path.join(photosDir, "a.jpg") });

        await autoImportHandler(singlePassData(false), makeContext());

        expect(importedPaths().map(filePath => path.basename(filePath))).toEqual(["b.jpg", "c.jpg"]);
    });

    describe("source cleanup", () => {

        //
        // A merkle tree holding originals with the given content hashes, which is what confirms an
        // import for the cleanup.
        //
        function treeHolding(hashesByAssetId: Map<string, string>): any {
            let tree = createTree<any>("test-tree");
            for (const [assetId, hash] of hashesByAssetId) {
                tree = addItem(tree, {
                    name: `asset/${assetId}`,
                    hash: Buffer.from(hash, "hex"),
                    length: 100,
                    lastModified: new Date("2026-01-01T00:00:00.000Z"),
                });
            }
            return tree;
        }

        test("deletes a source file confirmed in the database", async () => {
            const filePath = writePhoto("a.jpg", "one");
            backend.hashesByFileName.set("a.jpg", "aabbcc");
            mockLoadMerkleTree.mockResolvedValue(treeHolding(new Map([["asset-a", "aabbcc"]])));

            const result = await autoImportHandler(singlePassData(true), makeContext());

            expect(result.deletedFromSource).toBe(1);
            expect(fsSync.existsSync(filePath)).toBe(false);
        });

        test("leaves a source file alone when its hash is not in the database", async () => {
            const filePath = writePhoto("a.jpg", "one");
            backend.hashesByFileName.set("a.jpg", "aabbcc");
            mockLoadMerkleTree.mockResolvedValue(treeHolding(new Map([["asset-other", "ddeeff"]])));

            const result = await autoImportHandler(singlePassData(true), makeContext());

            expect(result.deletedFromSource).toBe(0);
            expect(fsSync.existsSync(filePath)).toBe(true);
        });

        test("leaves a source file alone when the import failed", async () => {
            const filePath = writePhoto("a.jpg", "one");
            backend.outcomesByFileName.set("a.jpg", "failed");
            mockLoadMerkleTree.mockResolvedValue(treeHolding(new Map([["asset-a", "aabbcc"]])));

            const result = await autoImportHandler(singlePassData(true), makeContext());

            expect(result.deletedFromSource).toBe(0);
            expect(fsSync.existsSync(filePath)).toBe(true);
        });

        test("deletes a source file the database already held", async () => {
            const filePath = writePhoto("a.jpg", "one");
            backend.outcomesByFileName.set("a.jpg", "skipped");
            backend.hashesByFileName.set("a.jpg", "aabbcc");
            mockLoadMerkleTree.mockResolvedValue(treeHolding(new Map([["asset-a", "aabbcc"]])));

            const result = await autoImportHandler(singlePassData(true), makeContext());

            expect(result.skipped).toBe(1);
            expect(result.deletedFromSource).toBe(1);
            expect(fsSync.existsSync(filePath)).toBe(false);
        });

        test("deletes nothing when cleanup is switched off", async () => {
            const filePath = writePhoto("a.jpg", "one");
            backend.hashesByFileName.set("a.jpg", "aabbcc");
            mockLoadMerkleTree.mockResolvedValue(treeHolding(new Map([["asset-a", "aabbcc"]])));

            const result = await autoImportHandler(singlePassData(false), makeContext());

            expect(result.deletedFromSource).toBe(0);
            expect(fsSync.existsSync(filePath)).toBe(true);
        });
    });
});
