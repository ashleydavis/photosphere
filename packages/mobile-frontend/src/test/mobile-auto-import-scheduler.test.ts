import { DEFAULT_AUTO_IMPORT_SETTINGS, IAutoImportSettings } from "api/src/lib/auto-import-settings";
import { IBackfillCursor } from "api/src/lib/auto-import-queue";
import {
    IDeviceMediaLibrary,
    IDeviceMediaLibraryDeleteResult,
    IDeviceMediaLibraryPage,
} from "../lib/device-media-library";
import { IMobileAutoImportSchedulerDeps, MobileAutoImportScheduler } from "../lib/mobile-auto-import-scheduler";

//
// A photo library holding one page, so a run has something to import and then finishes walking.
//
class OneItemLibrary implements IDeviceMediaLibrary {
    // The item ids that were exported.
    readonly exportedIds: string[] = [];

    async listPage(cursor: string | undefined, _pageSize: number): Promise<IDeviceMediaLibraryPage> {
        if (cursor !== undefined) {
            return { items: [] };
        }
        return {
            items: [{
                id: "one",
                displayName: "one.jpg",
                mimeType: "image/jpeg",
                size: 1024,
                createdAtMs: 1,
                albumId: "camera",
            }],
        };
    }

    async exportItem(itemId: string): Promise<string> {
        this.exportedIds.push(itemId);
        return `/exported/${itemId}`;
    }

    async releaseItem(_itemId: string): Promise<void> {
        // Nothing to let go of in this fake.
    }

    async deleteItems(_itemIds: string[]): Promise<IDeviceMediaLibraryDeleteResult> {
        return { deletedIds: [], failedIds: [] };
    }
}

//
// Settings that watch the whole library, which is what the app runs with before albums are chosen.
//
// The backfill rate is turned right up because the pacing runs on the real clock: at the default of
// sixty items a minute every one of these tests would wait a second for its only photo.
//
function makeSettings(overrides: Partial<IAutoImportSettings>): IAutoImportSettings {
    return {
        ...DEFAULT_AUTO_IMPORT_SETTINGS,
        enabled: true,
        sources: [{ type: "device-album", albumId: "all" }],
        backfillItemsPerMinute: 600000,
        ...overrides,
    };
}

//
// Waits until the condition holds, giving up loudly rather than hanging the suite.
//
// A run never ends by itself, so a test that wants to see what one did has to wait for it to get
// there and then stop it.
//
async function waitFor(description: string, condition: () => boolean): Promise<void> {
    const deadline = Date.now() + 10000;
    while (Date.now() < deadline) {
        if (condition()) {
            return;
        }
        await new Promise<void>(resolve => setTimeout(resolve, 20));
    }
    throw new Error(`Timed out waiting for ${description}.`);
}

//
// The dependencies a test starts from: an import that takes everything and records nothing else.
//
function makeDeps(library: IDeviceMediaLibrary, overrides: Partial<IMobileAutoImportSchedulerDeps>): IMobileAutoImportSchedulerDeps {
    return {
        library,
        databasePath: "test-database",
        importBatch: async paths => ({
            imported: paths.map((logicalPath, index) => ({
                assetId: `asset-${index}`,
                logicalPath,
                asset: { _id: `asset-${index}`, hash: `hash-${logicalPath}` } as any,
            })),
            skipped: [],
            failedCount: 0,
        }),
        loadDatabaseHashes: async () => new Set<string>(),
        persistCursor: async () => { /* nothing recorded in these tests. */ },
        onProgress: () => { /* nothing listening. */ },
        onItem: () => { /* nothing listening. */ },
        logInfo: () => { /* quiet. */ },
        logError: () => { /* quiet. */ },
        ...overrides,
    };
}

//
// A cursor at the beginning of the library.
//
function startOfLibrary(): IBackfillCursor {
    return { pageCursor: undefined, completed: false };
}

describe("MobileAutoImportScheduler", () => {

    test("a run imports what the library offers and reports it as running while it does", async () => {
        const library = new OneItemLibrary();
        const scheduler = new MobileAutoImportScheduler(makeDeps(library, {}));

        expect(scheduler.isRunning()).toBe(false);

        const run = scheduler.start(makeSettings({}), startOfLibrary());
        expect(scheduler.isRunning()).toBe(true);

        await waitFor("the library's only photo to be exported", () => library.exportedIds.length > 0);
        await scheduler.stop();
        await run;

        expect(scheduler.isRunning()).toBe(false);
        expect(library.exportedIds).toEqual(["one"]);
    });

    test("stopping ends the run rather than leaving it going", async () => {
        const library = new OneItemLibrary();
        const scheduler = new MobileAutoImportScheduler(makeDeps(library, {}));

        const run = scheduler.start(makeSettings({}), startOfLibrary());
        await waitFor("the library's only photo to be exported", () => library.exportedIds.length > 0);
        await scheduler.stop();

        const result = await run;
        expect(result.imported).toBe(1);
        expect(result.backfillComplete).toBe(true);
    });

    test("starting a second run over the top is refused rather than importing everything twice", async () => {
        const library = new OneItemLibrary();
        const scheduler = new MobileAutoImportScheduler(makeDeps(library, {}));

        const run = scheduler.start(makeSettings({}), startOfLibrary());

        expect(() => scheduler.start(makeSettings({}), startOfLibrary())).toThrow("already running");

        await scheduler.stop();
        await run;
    });

    test("a run may be started again once the previous one has stopped", async () => {
        const library = new OneItemLibrary();
        const scheduler = new MobileAutoImportScheduler(makeDeps(library, {}));

        const firstRun = scheduler.start(makeSettings({}), startOfLibrary());
        await waitFor("the first run to export the photo", () => library.exportedIds.length === 1);
        await scheduler.stop();
        await firstRun;

        const secondRun = scheduler.start(makeSettings({}), startOfLibrary());
        await waitFor("the second run to export the photo", () => library.exportedIds.length === 2);
        await scheduler.stop();
        await secondRun;

        expect(library.exportedIds).toEqual(["one", "one"]);
    });

    test("settings with no device album are refused, rather than running and importing nothing", () => {
        const library = new OneItemLibrary();
        const scheduler = new MobileAutoImportScheduler(makeDeps(library, {}));

        expect(() => scheduler.start(makeSettings({ sources: [] }), startOfLibrary()))
            .toThrow("no device album sources");
    });

    test("stopping when nothing is running does nothing", async () => {
        const library = new OneItemLibrary();
        const scheduler = new MobileAutoImportScheduler(makeDeps(library, {}));

        await scheduler.stop();

        expect(library.exportedIds).toEqual([]);
    });

    test("a run that fails says so through the promise it was started with", async () => {
        const library = new OneItemLibrary();
        const scheduler = new MobileAutoImportScheduler(makeDeps(library, {
            importBatch: async () => { throw new Error("the import blew up"); },
        }));

        const run = scheduler.start(makeSettings({}), startOfLibrary());

        await expect(run).rejects.toThrow("the import blew up");
        // The failure also clears the run, so automatic import can be started again afterwards.
        expect(scheduler.isRunning()).toBe(false);
    });

    test("a run that fails while it is being stopped does not make the stop look like it failed", async () => {
        const library = new OneItemLibrary();
        const errors: string[] = [];

        // The import is held open until the test lets it go, so the run is still in flight when stop
        // is called and fails afterwards. That is the ordering this is about, and holding it is the
        // only way to get it every time rather than most of the time.
        let releaseImport: (() => void) | undefined = undefined;
        const importHeld = new Promise<void>(resolve => { releaseImport = resolve; });

        const scheduler = new MobileAutoImportScheduler(makeDeps(library, {
            importBatch: async () => {
                await importHeld;
                throw new Error("the import blew up");
            },
            logError: message => errors.push(message),
        }));

        const run = scheduler.start(makeSettings({}), startOfLibrary());
        run.catch(() => { /* the failure is asserted through the log below. */ });

        await waitFor("the import to be handed the first batch", () => library.exportedIds.length > 0);

        const stopping = scheduler.stop();
        releaseImport!();

        // Resolves rather than rejecting: switching automatic import off worked, whatever the run
        // that was ending made of its last batch.
        await stopping;

        expect(errors.join(" ")).toContain("the import blew up");
    });

    test("the backfill position it is started from is where the walk resumes", async () => {
        const library = new OneItemLibrary();
        const scheduler = new MobileAutoImportScheduler(makeDeps(library, {}));

        // Started past the only page, so the backfill has nothing left to walk.
        const run = scheduler.start(makeSettings({}), { pageCursor: "past-the-end", completed: false });
        await scheduler.stop();
        await run;

        expect(library.exportedIds).toEqual([]);
    });
});
