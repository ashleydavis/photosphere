import { AutoImportQueue, IBackfillCursor, createBackfillCursor } from "../../lib/auto-import-queue";
import { IAutoImportLoopDeps, IAutoImportProgressMessage, runAutoImportLoop } from "../../lib/auto-import-loop";
import { IImportAssetsResult } from "../../lib/import-assets.types";
import {
    IMediaItem,
    IMediaSource,
    IMediaSourceChangedCallback,
    IMediaSourceListPage,
    IMediaSourceUnsubscribe,
    MediaSourceDeleteError,
} from "../../lib/media-source";

//
// A media source that answers from a script, so the loop can be tested with no filesystem and no
// photo library.
//
class FakeMediaSource implements IMediaSource {
    // The pages to hand out, keyed by the cursor they answer.
    private readonly pagesByCursor: Map<string, IMediaSourceListPage>;

    // The item ids that were exported.
    readonly exportedIds: string[] = [];

    // The item ids that were released.
    readonly releasedIds: string[] = [];

    // The batches deleteItems was called with.
    readonly deletedBatches: string[][] = [];

    // Ids the source refuses to delete, reported through MediaSourceDeleteError.
    undeletableIds: string[] = [];

    // Whether watch() was unsubscribed, so a test can prove the loop lets go of the source.
    unsubscribed = false;

    constructor(pagesByCursor: Map<string, IMediaSourceListPage>) {
        this.pagesByCursor = pagesByCursor;
    }

    async listPage(cursor: string | undefined, _pageSize: number): Promise<IMediaSourceListPage> {
        const page = this.pagesByCursor.get(cursor ?? "");
        return page ?? { items: [], nextCursor: undefined };
    }

    watch(_onChanged: IMediaSourceChangedCallback): IMediaSourceUnsubscribe {
        return () => {
            this.unsubscribed = true;
        };
    }

    async openItem(item: IMediaItem): Promise<string> {
        this.exportedIds.push(item.sourceId);
        return `/exported/${item.sourceId}`;
    }

    async closeItem(item: IMediaItem): Promise<void> {
        this.releasedIds.push(item.sourceId);
    }

    async deleteItems(sourceIds: string[]): Promise<void> {
        this.deletedBatches.push(sourceIds);
        const refused = sourceIds.filter(sourceId => this.undeletableIds.includes(sourceId));
        if (refused.length > 0) {
            throw new MediaSourceDeleteError(`Refused ${refused.length}.`, refused);
        }
    }
}

//
// One item the source offers.
//
function makeItem(sourceId: string, createdAtMs: number): IMediaItem {
    return {
        sourceId,
        filePath: "",
        displayName: `${sourceId}.jpg`,
        contentType: "image/jpeg",
        size: 1024,
        createdAt: new Date(createdAtMs),
    };
}

//
// An import result that took everything in, with a content hash derived from the path so a test can
// line the hashes up with the items.
//
function importedEverything(paths: string[]): IImportAssetsResult {
    return {
        imported: paths.map((logicalPath, index) => ({
            assetId: `asset-${index}`,
            logicalPath,
            asset: { _id: `asset-${index}`, hash: `hash-${logicalPath}` } as any,
        })),
        skipped: [],
        failedCount: 0,
    };
}

//
// The moment every test's clock starts at.
//
const TEST_START_MS = 1700000000000;

//
// A clock that reads one minute later each time it is asked.
//
function makeAdvancingClock(): () => number {
    let readings = 0;
    return () => {
        const now = TEST_START_MS + readings * 60000;
        readings += 1;
        return now;
    };
}

//
// The deps a test starts from: a single pass over the given source, counting nothing and recording
// everything, with each hook overridable.
//
function makeDeps(source: IMediaSource, overrides: Partial<IAutoImportLoopDeps>): IAutoImportLoopDeps {
    const cursor: IBackfillCursor = createBackfillCursor();
    return {
        source,
        queue: new AutoImportQueue(1000000, cursor),
        databasePath: "test-database",
        cleanupEnabled: false,
        once: true,
        isCancelled: () => false,
        // A clock that walks forward a minute per reading. The backfill earns its budget from
        // elapsed time, so a clock that stands still would release nothing and the loop would spin.
        nowMs: makeAdvancingClock(),
        sleep: async () => { /* a single pass never waits. */ },
        importBatch: async paths => importedEverything(paths),
        loadDatabaseHashes: async () => new Set<string>(),
        persistCursor: async () => { /* nothing to record in these tests. */ },
        onProgress: () => { /* nothing listening. */ },
        onItem: () => { /* nothing listening. */ },
        logInfo: () => { /* quiet. */ },
        logError: () => { /* quiet. */ },
        ...overrides,
    };
}

describe("runAutoImportLoop", () => {

    test("a single pass imports the whole library and reports what it did", async () => {
        const source = new FakeMediaSource(new Map([
            ["", { items: [makeItem("one", 1), makeItem("two", 2)], nextCursor: "10" }],
            ["10", { items: [makeItem("three", 3)], nextCursor: undefined }],
        ]));

        const result = await runAutoImportLoop(makeDeps(source, {}));

        expect(result.seen).toBe(3);
        expect(result.imported).toBe(3);
        expect(result.failed).toBe(0);
        expect(result.backfillComplete).toBe(true);
        expect(source.exportedIds).toEqual(["one", "two", "three"]);
    });

    test("every exported item is released, whatever the import made of it", async () => {
        const source = new FakeMediaSource(new Map([
            ["", { items: [makeItem("one", 1)], nextCursor: undefined }],
        ]));

        await runAutoImportLoop(makeDeps(source, {
            importBatch: async () => ({ imported: [], skipped: [], failedCount: 1 }),
        }));

        expect(source.releasedIds).toEqual(["one"]);
    });

    test("an import that failed outright counts every file in the batch as failed", async () => {
        const source = new FakeMediaSource(new Map([
            ["", { items: [makeItem("one", 1), makeItem("two", 2)], nextCursor: undefined }],
        ]));

        const result = await runAutoImportLoop(makeDeps(source, {
            importBatch: async paths => ({ imported: [], skipped: [], failedCount: paths.length }),
        }));

        expect(result.imported).toBe(0);
        expect(result.failed).toBe(2);
    });

    test("an import that could not be started at all records nothing for that batch", async () => {
        const source = new FakeMediaSource(new Map([
            ["", { items: [makeItem("one", 1)], nextCursor: undefined }],
        ]));

        const result = await runAutoImportLoop(makeDeps(source, {
            importBatch: async () => undefined,
        }));

        expect(result.imported).toBe(0);
        expect(result.failed).toBe(0);
        // Not released either: the batch was never handed over, so there is nothing to let go of.
        expect(source.releasedIds).toEqual([]);
    });

    test("cleanup deletes only the items the database confirms it holds", async () => {
        const source = new FakeMediaSource(new Map([
            ["", { items: [makeItem("one", 1), makeItem("two", 2)], nextCursor: undefined }],
        ]));

        const result = await runAutoImportLoop(makeDeps(source, {
            cleanupEnabled: true,
            // The database holds the first item's content and not the second's.
            loadDatabaseHashes: async () => new Set(["hash-/exported/one"]),
        }));

        expect(source.deletedBatches).toEqual([["one"]]);
        expect(result.deletedFromSource).toBe(1);
    });

    test("cleanup deletes nothing when cleanup is switched off", async () => {
        const source = new FakeMediaSource(new Map([
            ["", { items: [makeItem("one", 1)], nextCursor: undefined }],
        ]));

        await runAutoImportLoop(makeDeps(source, {
            cleanupEnabled: false,
            loadDatabaseHashes: async () => new Set(["hash-/exported/one"]),
        }));

        expect(source.deletedBatches).toEqual([]);
    });

    test("a file the import recognised as already present is a cleanup candidate too", async () => {
        const source = new FakeMediaSource(new Map([
            ["", { items: [makeItem("one", 1)], nextCursor: undefined }],
        ]));

        const result = await runAutoImportLoop(makeDeps(source, {
            cleanupEnabled: true,
            importBatch: async paths => ({
                imported: [],
                skipped: paths.map(logicalPath => ({ logicalPath, contentHash: `hash-${logicalPath}` })),
                failedCount: 0,
            }),
            loadDatabaseHashes: async () => new Set(["hash-/exported/one"]),
        }));

        expect(result.skipped).toBe(1);
        expect(source.deletedBatches).toEqual([["one"]]);
        expect(result.deletedFromSource).toBe(1);
    });

    test("a source file the platform refused to delete is not counted as deleted", async () => {
        const source = new FakeMediaSource(new Map([
            ["", { items: [makeItem("one", 1)], nextCursor: undefined }],
        ]));
        source.undeletableIds = ["one"];

        const errors: string[] = [];
        const result = await runAutoImportLoop(makeDeps(source, {
            cleanupEnabled: true,
            loadDatabaseHashes: async () => new Set(["hash-/exported/one"]),
            logError: message => errors.push(message),
        }));

        expect(result.deletedFromSource).toBe(0);
        expect(errors.join(" ")).toContain("one");
    });

    test("the backfill cursor is recorded as the walk advances", async () => {
        const source = new FakeMediaSource(new Map([
            ["", { items: [makeItem("one", 1)], nextCursor: "10" }],
            ["10", { items: [makeItem("two", 2)], nextCursor: undefined }],
        ]));

        const recorded: IBackfillCursor[] = [];
        await runAutoImportLoop(makeDeps(source, {
            persistCursor: async cursor => {
                recorded.push({ pageCursor: cursor.pageCursor, completed: cursor.completed });
            },
        }));

        expect(recorded[recorded.length - 1].completed).toBe(true);
        expect(recorded.some(cursor => cursor.pageCursor === "10")).toBe(true);
    });

    test("a run resumed from a recorded cursor starts at that page rather than the beginning", async () => {
        const source = new FakeMediaSource(new Map([
            ["", { items: [makeItem("one", 1)], nextCursor: "10" }],
            ["10", { items: [makeItem("two", 2)], nextCursor: undefined }],
        ]));

        const result = await runAutoImportLoop(makeDeps(source, {
            queue: new AutoImportQueue(1000000, { pageCursor: "10", completed: false }),
        }));

        // "one" is only reached by the arrival walk, which passes over it because it predates the
        // run. The backfill starts where it left off.
        expect(source.exportedIds).toEqual(["two"]);
        expect(result.imported).toBe(1);
    });

    test("an item created since the run started is imported straight away, ahead of the backfill", async () => {
        const source = new FakeMediaSource(new Map([
            ["", { items: [makeItem("fresh", TEST_START_MS + 1000)], nextCursor: undefined }],
        ]));

        const result = await runAutoImportLoop(makeDeps(source, {
            nowMs: () => TEST_START_MS,
            // No backfill budget at all, so anything imported came through the fast lane.
            queue: new AutoImportQueue(0, createBackfillCursor()),
            once: false,
            isCancelled: (() => {
                let calls = 0;
                return () => {
                    calls += 1;
                    // Long enough for the arrival walk and one batch, then stop.
                    return calls > 4;
                };
            })(),
        }));

        expect(source.exportedIds).toEqual(["fresh"]);
        expect(result.imported).toBe(1);
    });

    test("progress is reported before and after each batch", async () => {
        const source = new FakeMediaSource(new Map([
            ["", { items: [makeItem("one", 1)], nextCursor: undefined }],
        ]));

        const progress: IAutoImportProgressMessage[] = [];
        await runAutoImportLoop(makeDeps(source, {
            onProgress: message => progress.push(message),
        }));

        expect(progress.length).toBeGreaterThanOrEqual(2);
        expect(progress[0].seen).toBe(1);
        expect(progress[0].imported).toBe(0);
        expect(progress[progress.length - 1].imported).toBe(1);
        expect(progress[progress.length - 1].currentItem).toBe("one.jpg");
    });

    test("one message is reported per asset the import added", async () => {
        const source = new FakeMediaSource(new Map([
            ["", { items: [makeItem("one", 1), makeItem("two", 2)], nextCursor: undefined }],
        ]));

        const assetIds: string[] = [];
        await runAutoImportLoop(makeDeps(source, {
            onItem: message => assetIds.push(message.assetId),
        }));

        expect(assetIds).toEqual(["asset-0", "asset-1"]);
    });

    test("every arrival names the database it landed in", async () => {
        const source = new FakeMediaSource(new Map([
            ["", { items: [makeItem("one", 1)], nextCursor: undefined }],
        ]));

        const databasePaths: string[] = [];
        await runAutoImportLoop(makeDeps(source, {
            databasePath: "photosphere-default",
            onItem: message => databasePaths.push(message.databasePath),
        }));

        // Without this the gallery cannot tell an arrival in the database it is showing from one in
        // another, so it shows both, and shows its own twice.
        expect(databasePaths).toEqual(["photosphere-default"]);
    });

    test("the source watcher is let go of however the loop ends", async () => {
        const source = new FakeMediaSource(new Map([
            ["", { items: [], nextCursor: undefined }],
        ]));

        await runAutoImportLoop(makeDeps(source, {}));

        expect(source.unsubscribed).toBe(true);
    });

    test("the source watcher is let go of when the loop throws", async () => {
        const source = new FakeMediaSource(new Map([
            ["", { items: [makeItem("one", 1)], nextCursor: undefined }],
        ]));

        await expect(runAutoImportLoop(makeDeps(source, {
            importBatch: async () => { throw new Error("the import blew up"); },
        }))).rejects.toThrow("the import blew up");

        expect(source.unsubscribed).toBe(true);
    });

    test("a run that is cancelled before it starts imports nothing", async () => {
        const source = new FakeMediaSource(new Map([
            ["", { items: [makeItem("one", 1)], nextCursor: undefined }],
        ]));

        const result = await runAutoImportLoop(makeDeps(source, {
            isCancelled: () => true,
        }));

        expect(result.imported).toBe(0);
        expect(source.exportedIds).toEqual([]);
    });

    test("a source whose cursor never advances fails loudly rather than walking forever", async () => {
        // Every cursor answers with a page pointing at itself, which is what a broken cursor looks
        // like. Without the page limit the arrival walk would never return.
        const stuck: IMediaSource = {
            listPage: async () => ({ items: [], nextCursor: "same" }),
            watch: () => () => { /* nothing to unsubscribe. */ },
            openItem: async () => "",
            closeItem: async () => { /* nothing exported. */ },
            deleteItems: async () => { /* nothing to delete. */ },
        };

        await expect(runAutoImportLoop(makeDeps(stuck, {}))).rejects.toThrow("cursor is not advancing");
    });
});
