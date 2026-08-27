import { AutoImportQueue } from "api/src/lib/auto-import-queue";
import { IFileCacheIdentity } from "api/src/lib/import-assets.types";
import { IMediaItem, IMediaSource, IMediaSourceListPage } from "api/src/lib/media-source";
import { IUuidGenerator } from "utils";
import { ScanProgressCallback, scanPath } from "./file-scanner";
import { IImportScanner, IScannedImportFile } from "./import-scanner";

//
// The scanner for automatic import: it reads somewhere media arrives and pushes what it finds.
//
// This is everything the old `auto-import` task's loop did, moved behind IImportScanner so that one
// long-lived `import-assets` task serves automatic import as well as manual. Before this there were
// two tasks: a loop that decided what to import, and an `import-assets` task started and torn down
// for every handful of photos it decided on. Everything `import-assets` amortises over a run (the
// scan, the write lock, loading and saving the hash cache) was being paid per handful.
//
// What is platform-specific stays behind IMediaSource, so this same scanner runs over a watched
// folder on the desktop and over the device photo library on a phone.
//

//
// How often the scanner wakes up to release whatever the pacing allows. Short enough that a photo
// the user has just taken appears promptly, long enough that an idle scanner costs nothing.
//
export const AUTO_IMPORT_TICK_MS = 250;

//
// How many items are fetched from the source per backfill page. The pacing decides how quickly they
// are released; this only decides how often the source is asked.
//
export const BACKFILL_PAGE_SIZE = 50;

//
// What the scanner is doing, reported so the user interface can show it.
//
export interface IAutoImportScannerProgress {
    // The item most recently pushed to the import.
    currentItem: string | undefined;

    // How many items the scanner recognised as already imported and did not push.
    skippedAsAlreadyImported: number;

    // Total milliseconds spent copying items out of the source.
    exportMs: number;

    // True when there is nothing left to push: the whole library has been walked and both lanes are
    // empty. This is when the import writes out what it has learnt, because it is the moment that
    // costs nothing and the moment after which nothing further may happen for hours.
    caughtUp: boolean;
}

//
// Everything the scanner needs from the platform driving it.
//
// Everything with a side effect is passed in rather than reached for, which is what lets the whole
// scanner be tested without a filesystem, a photo library or a clock, and lets the pacing be walked
// forward without waiting for real time to pass.
//
export interface IAutoImportScannerDeps {
    // Where media arrives, already built for the configured sources.
    source: IMediaSource;

    // The two lanes and the pacing, already positioned at the persisted backfill cursor.
    queue: AutoImportQueue;

    // True once the caller wants the scan to stop.
    isCancelled: () => boolean;

    // The current time in milliseconds since the epoch. Injected so the pacing is testable.
    nowMs: () => number;

    // Waits for the given number of milliseconds. Injected for the same reason.
    sleep: (milliseconds: number) => Promise<void>;

    // Where a zip's contents are extracted to, and where the source materialises its copies.
    sessionTempDir: string;

    // Names the temporary files extracted from a zip.
    uuidGenerator: IUuidGenerator;

    // Answers whether an item is already in the database, without opening it: its content hash when
    // it is, undefined when it is not or when nothing is known about it.
    //
    // This is what stops the scanner paying for a photo that has already been imported. Opening an
    // item on a phone copies the whole photo out of the library into the sandbox, and hashing it
    // reads that copy back, so a library that is already imported would otherwise cost a full copy
    // and a full hash per photo on every run.
    alreadyImportedContentHash: (item: IMediaItem) => Promise<string | undefined>;

    // Reports every source id the library holds, after a walk that read the whole listing.
    //
    // Called only when the walk reached the end and the backfill was already complete, so what it
    // reports really is the whole library rather than the part of it read so far. The platform uses
    // it to drop what it recorded about photos that have since left the device.
    onLibraryWalked: (liveSourceIds: Set<string>) => Promise<void>;

    // Reports what the scanner is doing, so the user interface can show it.
    onProgress: (progress: IAutoImportScannerProgress) => void;

    // Says something worth reading in the log.
    logInfo: (message: string) => void;
}

//
// Pushes photos at the import as they arrive, and as the pacing allows.
//
export class AutoImportScanner implements IImportScanner {
    //
    // Everything the scanner needs from the platform driving it.
    //
    private readonly deps: IAutoImportScannerDeps;

    //
    // Every source id this run has seen, gathered page by page so the platform can drop what it
    // recorded about photos that have since left the device.
    //
    private readonly liveSourceIds = new Set<string>();

    //
    // The cursor the next page of the source listing starts at, and whether the listing has already
    // ended. The run carries these itself: nothing outside it ever sees them, because every run
    // reads the source from the beginning.
    //
    private nextPageCursor: string | undefined = undefined;

    //
    // True once a page has come back with no page after it.
    //
    private listingFinished = false;

    //
    // Whether the whole library has already been reported to onLibraryWalked in this run.
    //
    private hasReportedFullLibrary = false;

    //
    // The item most recently pushed to the import, for the user interface to name.
    //
    private currentItem: string | undefined = undefined;

    //
    // How many items were recognised as already imported and never opened.
    //
    private skippedAsAlreadyImported = 0;

    // Total milliseconds spent copying items out of the source, summed over every item copied.
    private exportMs = 0;

    //
    // The source item each pushed file came from, so the copy can be released once the import has
    // finished with it. Keyed by the path the import knows the file by.
    //
    private itemsByExportedPath = new Map<string, IMediaItem>();

    constructor(deps: IAutoImportScannerDeps) {
        this.deps = deps;
    }

    //
    // Pushes photos until the source has been read to the end, then returns.
    //
    // One pass and no more. A photo that arrives after this run has read past it is found by the
    // next run, which the app starts a short while after this one ends. That is what keeps the
    // scanner off the timers and the filesystem watchers it used to hold.
    //
    async scan(visitFile: (result: IScannedImportFile) => Promise<void>, onProgress: ScanProgressCallback): Promise<void> {
        const { deps } = this;

        while (!deps.isCancelled() && !this.hasNothingLeftToPush()) {
            if (this.queueNeedsBackfillPage()) {
                await this.fetchBackfillPage();
            }

            const item = deps.queue.nextItem(deps.nowMs());
            if (item !== undefined) {
                await this.pushItem(item, visitFile, onProgress);
            }

            // Reported on every tick, not only when something was released. It is what the panel
            // shows, and the import writes out what it has learnt on the back of it.
            deps.onProgress(this.progress());

            if (deps.isCancelled()) {
                break;
            }

            if (item === undefined) {
                // Nothing was released, so wait rather than spinning. A tick after an item was
                // released would only slow the import down: the pacing already decides the rate.
                await deps.sleep(AUTO_IMPORT_TICK_MS);
            }
        }

        // Said once more on the way out, because the loop stops the moment there is nothing left and
        // the import has to hear that it is caught up before the run ends.
        deps.onProgress(this.progress());
    }

    //
    // Releases the temporary copy the source materialised for one file.
    //
    // A photo library item is not a file: it had to be copied into the app's sandbox to be read at
    // all, and this is what deletes that copy. Called by the import once it has finished with the
    // file, whatever it made of it.
    //
    async release(filePath: string): Promise<void> {
        const item = this.itemsByExportedPath.get(filePath);
        if (item === undefined) {
            // Not one of ours, or already released. Releasing twice would ask the source to delete
            // a copy that is not there, and a scan whose files are all released is the normal end.
            return;
        }

        this.itemsByExportedPath.delete(filePath);
        await this.deps.source.closeItem(item);
    }

    //
    // What the scanner is doing, for the user interface.
    //
    private progress(): IAutoImportScannerProgress {
        return {
            currentItem: this.currentItem,
            skippedAsAlreadyImported: this.skippedAsAlreadyImported,
            exportMs: this.exportMs,
            caughtUp: this.hasNothingLeftToPush(),
        };
    }

    //
    // Hands one item to the import: asks whether it is already there, copies it out of the source if
    // it is not, and pushes it through the same file scan a manual import uses.
    //
    private async pushItem(item: IMediaItem, visitFile: (result: IScannedImportFile) => Promise<void>, onProgress: ScanProgressCallback): Promise<void> {
        const { deps } = this;

        this.currentItem = item.displayName;

        // Asked before the item is opened, which is the whole point: opening it on a phone copies
        // the entire photo out of the library, and that copy is what this avoids.
        const importedContentHash = await deps.alreadyImportedContentHash(item);
        if (importedContentHash !== undefined) {
            this.skippedAsAlreadyImported += 1;
            return;
        }

        // Timed because on a phone this copies the whole photo out of the library into the app's
        // sandbox before anything can read it, and how much of an import that accounts for has never
        // been established.
        const exportStartedAt = Date.now();
        const exportedPath = await deps.source.openItem(item);
        this.exportMs += Date.now() - exportStartedAt;

        // Whether this item was already a file before the import looked at it. A folder source says
        // so by naming the file; a photo library item has no path at all until it is copied out.
        const isAlreadyAFile = item.filePath.length > 0;

        // Put through the same scan a manual import uses rather than described by hand, so the
        // content type check, the stat and the zip handling are the one implementation. A source
        // that exported nothing readable simply produces no file and nothing is pushed.
        let pushed = false;
        await scanPath(
            exportedPath,
            async result => {
                pushed = true;
                this.itemsByExportedPath.set(result.filePath, item);

                // What this file really is, so the import files its hash under something that
                // outlives the temporary copy. See IFileCacheIdentity.
                //
                // For an item that was already a file, the file's own size and modified time are
                // what to record: they are what every later listing of that folder will report, and
                // the listing this item came from can be a moment out of date. A file still being
                // copied into a watched folder is listed at whatever size it had reached, and an
                // entry recorded against that never matches the finished file again.
                //
                // For a photo library item there is no file until the copy, and the copy's own size
                // and time describe the copy rather than the photo, so the library's values are the
                // only ones that mean anything.
                const cacheIdentity: IFileCacheIdentity = {
                    key: item.sourceId,
                    length: isAlreadyAFile ? result.fileStat.length : item.size,
                    lastModified: isAlreadyAFile ? result.fileStat.lastModified.getTime() : item.createdAt.getTime(),
                };

                await visitFile({ ...result, cacheIdentity });
            },
            onProgress,
            { ignorePatterns: [/\.db/] },
            deps.sessionTempDir,
            deps.uuidGenerator
        );

        if (!pushed) {
            // The scan ignored it, so nothing will ever call release for it.
            await deps.source.closeItem(item);
        }
    }

    //
    // Reads one page of the source listing.
    //
    private async listSourcePage(cursor: string | undefined): Promise<IMediaSourceListPage> {
        return await this.deps.source.listPage(cursor, BACKFILL_PAGE_SIZE);
    }

    //
    // Whether the backfill lane has run dry and there is another page of the library to fetch.
    //
    private queueNeedsBackfillPage(): boolean {
        return !this.listingFinished && !this.deps.queue.hasPendingBackfill();
    }

    //
    // Fetches the next page of the existing library into the backfill lane.
    //
    private async fetchBackfillPage(): Promise<void> {
        const { deps } = this;
        const page = await this.listSourcePage(this.nextPageCursor);
        this.nextPageCursor = page.nextCursor;
        this.listingFinished = page.nextCursor === undefined;
        const accepted = deps.queue.addBackfillItems(page.items);
        deps.logInfo(`Automatic import found ${page.items.length} item(s) in the source, ${accepted} of them new.`);

        for (const item of page.items) {
            this.liveSourceIds.add(item.sourceId);
        }

        // Every run reads the listing from the beginning, so reaching the end means this run has seen
        // the whole library and can say what is still on the device.
        if (page.nextCursor === undefined && !this.hasReportedFullLibrary) {
            this.hasReportedFullLibrary = true;
            await deps.onLibraryWalked(this.liveSourceIds);
        }
    }

    //
    // True when there is nothing left to push: the library has been walked and both lanes are empty.
    //
    private hasNothingLeftToPush(): boolean {
        const { queue } = this.deps;
        return this.listingFinished && !queue.hasPendingBackfill() && !queue.hasPendingFastLane();
    }
}
