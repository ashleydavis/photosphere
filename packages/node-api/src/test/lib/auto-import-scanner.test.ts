import * as fsSync from "fs";
import * as path from "path";
import { AutoImportQueue } from "api/src/lib/auto-import-queue";
import {
    IMediaItem,
    IMediaSource,
    IMediaSourceListPage,
} from "api/src/lib/media-source";
import { createTestTempDir } from "node-utils";
import { RandomUuidGenerator } from "utils";
import { AutoImportScanner, IAutoImportScannerDeps } from "../../lib/auto-import-scanner";
import { IScannedImportFile } from "../../lib/import-scanner";

//
// These are the old auto-import loop's tests, moved onto the scanner that replaced it. The loop
// decided what to import and handed batches to a separate import task; the scanner decides the same
// things and pushes files at the one import task that now feeds on it.
//

//
// A media source that answers from a script, so the scanner can be tested with no photo library.
//
// The files it "exports" are real, because the scanner puts every item through the same file scan a
// manual import uses, and that reads the file.
//
class FakeMediaSource implements IMediaSource {
    // The item ids that were exported.
    readonly exportedIds: string[] = [];

    // The item ids that were released.
    readonly releasedIds: string[] = [];

    // The pages the source answers with, replaceable so a test can make a photo appear part way
    // through a run.
    private pages: Map<string, IMediaSourceListPage>;

    // Where the exported copies are written.
    private readonly exportDir: string;

    constructor(pagesByCursor: Map<string, IMediaSourceListPage>, exportDir: string) {
        this.pages = pagesByCursor;
        this.exportDir = exportDir;
    }

    async listPage(cursor: string | undefined, _pageSize: number): Promise<IMediaSourceListPage> {
        const page = this.pages.get(cursor ?? "");
        return page ?? { items: [], nextCursor: undefined };
    }

    //
    // Replaces what the source answers with, standing in for a photo landing in the library.
    //
    setPages(pagesByCursor: Map<string, IMediaSourceListPage>): void {
        this.pages = pagesByCursor;
    }

    //
    // Tells the scanner the listing changed, exactly as a real source's poll would.
    //
    async openItem(item: IMediaItem): Promise<string> {
        this.exportedIds.push(item.sourceId);
        const exportedPath = path.join(this.exportDir, `${item.sourceId}.jpg`);
        fsSync.writeFileSync(exportedPath, `contents of ${item.sourceId}`);
        return exportedPath;
    }

    async closeItem(item: IMediaItem): Promise<void> {
        this.releasedIds.push(item.sourceId);
    }

    async deleteItems(_sourceIds: string[]): Promise<void> {
        throw new Error("The scanner has nothing to do with deleting.");
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
// The moment every test's clock starts at.
//
const TEST_START_MS = 1700000000000;

describe("AutoImportScanner", () => {

    let tempDir: string;

    beforeEach(() => {
        tempDir = createTestTempDir("auto-import-scanner");
        fsSync.mkdirSync(tempDir, { recursive: true });
    });

    //
    // The deps a test starts from: a single pass over the given source, recognising nothing as
    // already imported, with each hook overridable.
    //
    function makeDeps(source: IMediaSource, overrides: Partial<IAutoImportScannerDeps>): IAutoImportScannerDeps {
        const queue = new AutoImportQueue();

        const deps: IAutoImportScannerDeps = {
            source,
            queue,
            isCancelled: () => false,
            sleep: async () => { /* nothing to wait for once the library has been walked. */ },
            sessionTempDir: tempDir,
            uuidGenerator: new RandomUuidGenerator(),
            alreadyImportedContentHash: async () => undefined,
            onLibraryWalked: async () => { /* nothing recorded in these tests. */ },
            onProgress: () => { /* nothing listening. */ },
            logInfo: () => { /* quiet. */ },
            ...overrides,
        };

        // Nothing here cancels a scan. The scanner ends its own run once it has read the source to
        // the end, and a test that hangs is a test proving it no longer does.

        return deps;
    }

    //
    // Runs a scan to completion and returns the files it pushed.
    //
    async function runScan(scanner: AutoImportScanner): Promise<IScannedImportFile[]> {
        const pushed: IScannedImportFile[] = [];
        await scanner.scan(
            async result => {
                pushed.push(result);
            },
            () => { /* nothing watching progress here. */ }
        );
        return pushed;
    }

    //
    // A source offering the given items on one page.
    //
    function sourceWith(items: IMediaItem[]): FakeMediaSource {
        return new FakeMediaSource(new Map([["", { items, nextCursor: undefined }]]), tempDir);
    }

    test("a single pass pushes the whole library and returns", async () => {
        const source = new FakeMediaSource(new Map([
            ["", { items: [makeItem("one", 1), makeItem("two", 2)], nextCursor: "10" }],
            ["10", { items: [makeItem("three", 3)], nextCursor: undefined }],
        ]), tempDir);

        const pushed = await runScan(new AutoImportScanner(makeDeps(source, {})));

        expect(source.exportedIds).toEqual(["one", "two", "three"]);
        expect(pushed).toHaveLength(3);
    });

    test("tells the import what each pushed file really is", async () => {
        // The exported copy has a path and a modified time that were both minted by the copy, so the
        // identity is what the import files the hash under.
        const source = sourceWith([makeItem("one", 1)]);

        const pushed = await runScan(new AutoImportScanner(makeDeps(source, {})));

        expect(pushed[0].cacheIdentity).toEqual({ key: "one", length: 1024, lastModified: 1 });
    });

    test("an item already in the database is never opened and never pushed", async () => {
        // The whole point of asking before opening: on a phone, opening an item copies the entire
        // photo out of the library, and hashing it reads that copy back.
        const source = sourceWith([makeItem("already-in", 1), makeItem("new-one", 2)]);

        const pushed = await runScan(new AutoImportScanner(makeDeps(source, {
            alreadyImportedContentHash: async item => item.sourceId === "already-in" ? "hash-of-already-in" : undefined,
        })));

        expect(source.exportedIds).toEqual(["new-one"]);
        expect(pushed.map(file => path.basename(file.filePath))).toEqual(["new-one.jpg"]);
    });

    test("nothing is opened at all when the whole library is already in the database", async () => {
        const source = sourceWith([makeItem("one", 1), makeItem("two", 2)]);

        const pushed = await runScan(new AutoImportScanner(makeDeps(source, {
            alreadyImportedContentHash: async () => "some-hash",
        })));

        expect(source.exportedIds).toEqual([]);
        expect(pushed).toEqual([]);
    });

    test("counts what it recognised as already imported, so the progress can say so", async () => {
        const source = sourceWith([makeItem("one", 1), makeItem("two", 2)]);
        const progressReports: number[] = [];

        await runScan(new AutoImportScanner(makeDeps(source, {
            alreadyImportedContentHash: async () => "some-hash",
            onProgress: progress => progressReports.push(progress.skippedAsAlreadyImported),
        })));

        expect(progressReports[progressReports.length - 1]).toBe(2);
    });

    test("releasing a pushed file releases the copy the source made for it", async () => {
        const source = sourceWith([makeItem("one", 1)]);
        const scanner = new AutoImportScanner(makeDeps(source, {}));

        const pushed = await runScan(scanner);
        await scanner.release(pushed[0].filePath);

        expect(source.releasedIds).toEqual(["one"]);
    });

    test("releasing the same file twice releases the source item once", async () => {
        const source = sourceWith([makeItem("one", 1)]);
        const scanner = new AutoImportScanner(makeDeps(source, {}));

        const pushed = await runScan(scanner);
        await scanner.release(pushed[0].filePath);
        await scanner.release(pushed[0].filePath);

        expect(source.releasedIds).toEqual(["one"]);
    });

    test("releasing something it never pushed does nothing", async () => {
        const source = sourceWith([makeItem("one", 1)]);
        const scanner = new AutoImportScanner(makeDeps(source, {}));

        await scanner.release("/somewhere/else.jpg");

        expect(source.releasedIds).toEqual([]);
    });

    test("reports the whole library once the run has read all of it", async () => {
        const source = new FakeMediaSource(new Map([
            ["", { items: [makeItem("one", 1), makeItem("two", 2)], nextCursor: "10" }],
            ["10", { items: [makeItem("three", 3)], nextCursor: undefined }],
        ]), tempDir);
        const walkedLibraries: Set<string>[] = [];

        await runScan(new AutoImportScanner(makeDeps(source, {
            queue: new AutoImportQueue(),
            onLibraryWalked: async liveSourceIds => {
                walkedLibraries.push(new Set(liveSourceIds));
            },
        })));

        expect(walkedLibraries).toHaveLength(1);
        expect([...walkedLibraries[0]].sort()).toEqual(["one", "three", "two"]);
    });

    test("a scan returns once the library has run dry, rather than waiting for more", async () => {
        const source = sourceWith([makeItem("one", 1)]);
        let ticks = 0;

        // Nothing cancels this scan. If it did not end by itself the test would hang here, which is
        // the point: the app is what starts the next run, a short while after this one ends.
        await runScan(new AutoImportScanner(makeDeps(source, {
            sleep: async () => {
                ticks += 1;
            },
        })));

        expect(source.exportedIds).toEqual(["one"]);
    });

    test("a photo that arrives after the run has ended is taken in by the next run", async () => {
        const source = sourceWith([makeItem("existing", 1)]);
        const queue = new AutoImportQueue();

        await runScan(new AutoImportScanner(makeDeps(source, { queue })));
        expect(source.exportedIds).toEqual(["existing"]);

        // A photo is taken after that run finished. Nothing is watching for it: the next run is what
        // finds it, reading the listing from the beginning again.
        source.setPages(new Map([
            ["", { items: [makeItem("existing", 1), makeItem("just-taken", TEST_START_MS + 3600000)], nextCursor: undefined }],
        ]));

        const nextRun = new AutoImportQueue();
        await runScan(new AutoImportScanner(makeDeps(source, { queue: nextRun })));

        expect(source.exportedIds).toContain("just-taken");
    });
});
