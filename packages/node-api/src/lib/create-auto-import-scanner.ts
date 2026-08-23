import { IAsset, IFolderAutoImportSource, normaliseAutoImportSettings } from "api";
import { AutoImportQueue } from "api/src/lib/auto-import-queue";
import { IMediaItem } from "api/src/lib/media-source";
import { IStorage } from "storage";
import type { ITaskContext } from "task-queue";
import { log, swallowError } from "utils";
import { IBsonCollection } from "bdb";
import { AutoImportScanner, IAutoImportScannerProgress } from "./auto-import-scanner";
import { FolderMediaSource } from "./folder-media-source";
import { HashCache } from "./hash-cache";
import { IImportOptions } from "./import-assets.worker";
import { buildMediaSource, registerMediaSourceBuilder } from "./media-source-registry";

//
// Builds the scanner that feeds an automatic import, and everything it needs from the database.
//
// This is the part of automatic import that needs storage, a database and a task context. The
// decisions are in AutoImportScanner, kept apart so they can be tested with no filesystem, no photo
// library and no clock.
//
// It used to be a task of its own (`auto-import`), which ran a loop and started a separate
// `import-assets` task for every handful of photos the loop released. One import task fed by a
// scanner replaced both, which is what stopped the scan, the write lock and the hash cache being
// paid for per handful.
//

//
// Folders are the source kind node-api can serve, so it registers the builder for them. The mobile
// worker registers its own builder for the device photo library, and the scanner knows about
// neither.
//
registerMediaSourceBuilder("folder", (sources, options) => {
    return new FolderMediaSource(
        sources as IFolderAutoImportSource[],
        options.sessionTempDir,
        options.uuidGenerator
    );
});

//
// Everything the factory needs to build a scanner.
//
export interface ICreateAutoImportScannerOptions extends IImportOptions {
    // The database's storage, for reading the merkle tree and the saved backfill position.
    storage: IStorage;

    // The database's asset records, for the one question the hash cache cannot answer on its own:
    // whether a file that has been hashed before is in this database.
    metadataCollection: IBsonCollection<IAsset>;

    // The import's hash cache, already loaded. Shared with the import rather than loaded again,
    // because loading it reads and decodes the whole file.
    localHashCache: HashCache;

    // Where the media source materialises its temporary copies.
    sessionTempDir: string;

    // The task this scanner runs inside, for cancellation and the clock.
    context: ITaskContext;

    // Reports what the scanner is doing, so the user interface can show it.
    onProgress: (progress: IAutoImportScannerProgress) => void;
}

//
// Builds the scanner for one automatic import.
//
export async function createAutoImportScanner(options: ICreateAutoImportScannerOptions): Promise<AutoImportScanner> {
    const settings = normaliseAutoImportSettings(options);
    if (settings.sources.length === 0) {
        throw new Error("Automatic import was started with no sources configured. Nothing would be imported.");
    }

    // Every run reads the source from the beginning. Nothing is carried over from the last one, so
    // a photo that arrived since is found, and one already imported costs a hash cache lookup.
    const queue = new AutoImportQueue(settings.backfillItemsPerMinute);

    const source = buildMediaSource(settings.sources, {
        sessionTempDir: options.sessionTempDir,
        uuidGenerator: options.context.uuidGenerator,
    });

    // How many asset ids this run has recorded in the cache, so the cache is saved every so often
    // rather than only at the end: a run that is killed part way still keeps most of what it learnt.
    let cacheEntriesRecorded = 0;

    //
    // Answers whether an item is already in this database, without opening it.
    //
    // Three states, in the order they are cheapest to answer:
    //
    //  - An asset id recorded against the item means it is in the database. Nothing is read at all.
    //    A hard delete of that asset would make this wrong until the cache is cleared, which is a
    //    cost the user can undo with `psi hash-cache clear` and which no import path can produce:
    //    deleting an asset in Photosphere is a flag on the record, and the record and its hash stay.
    //  - A hash but no asset id means the item was hashed by an earlier run that did not get as far
    //    as recording where it landed. The database is asked for that hash, exactly as the import
    //    does, and the answer is recorded so it is not asked twice.
    //  - Nothing at all, or an entry whose size or created time no longer matches, means the item
    //    has to be opened, copied and hashed the long way. A photo library may reuse the id of a
    //    deleted item, so all three parts have to agree before an entry is believed.
    //
    async function alreadyImportedContentHash(item: IMediaItem): Promise<string | undefined> {
        const cacheEntry = options.localHashCache.getHash(item.sourceId);
        if (!cacheEntry) {
            return undefined;
        }

        if (cacheEntry.length !== item.size || cacheEntry.lastModified.getTime() !== item.createdAt.getTime()) {
            return undefined;
        }

        if (cacheEntry.assetId !== undefined) {
            return cacheEntry.hash.toString("hex");
        }

        const contentHash = cacheEntry.hash.toString("hex");
        const existingRecords = await options.metadataCollection.sortIndex("hash", "asc").findByValue(contentHash);
        if (existingRecords.length === 0) {
            return undefined;
        }

        options.localHashCache.setAssetId(item.sourceId, existingRecords[0]._id);
        cacheEntriesRecorded += 1;
        if (cacheEntriesRecorded % 100 === 0) {
            await swallowError(() => options.localHashCache.save());
        }

        return contentHash;
    }

    //
    // Drops what the cache knows about photos that are no longer on the device.
    //
    // Only entries filed under a source id are considered, and only those the walk did not see. A
    // file path that is not in the photo library is not a dead entry, it is a manual import, and
    // sweeping those would throw away the desktop's whole cache the first time automatic import
    // walked a folder.
    //
    async function onLibraryWalked(liveSourceIds: Set<string>): Promise<void> {
        const removed = options.localHashCache.removeSourceEntriesNotIn(liveSourceIds);
        if (removed > 0) {
            log.info(`Automatic import dropped ${removed} hash cache entry/entries for items no longer in the source.`);
            await swallowError(() => options.localHashCache.save());
        }
    }

    return new AutoImportScanner({
        source,
        queue,
        isCancelled: () => options.context.isCancelled(),
        nowMs: () => Date.now(),
        sleep: milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds)),
        sessionTempDir: options.sessionTempDir,
        uuidGenerator: options.context.uuidGenerator,
        alreadyImportedContentHash,
        onLibraryWalked,
        onProgress: options.onProgress,
        logInfo: message => log.info(message),
    });
}
