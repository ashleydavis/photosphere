import { IAsset, IDatabaseDescriptor, IFolderAutoImportSource, normaliseAutoImportSettings } from "api";
import { runSourceCleanup } from "api/src/lib/source-cleanup";
import type { IAutoImportSettings } from "api";
import { IMediaItem } from "api/src/lib/media-source";
import { BsonDatabase } from "bdb";
import { ensureDir, getProcessTmpDir, remove } from "node-utils";
import * as path from "path";
import { createStorage, loadEncryptionKeysFromPem } from "storage";
import type { ITaskContext } from "task-queue";
import { log, swallowError } from "utils";
import { FolderMediaSource } from "./folder-media-source";
import { getHashCacheDir, HashCache } from "./hash-cache";
import { buildMediaSource, registerMediaSourceBuilder } from "./media-source-registry";
import { resolveStorageCredentials } from "./resolve-storage-credentials";

//
// Deleting the photos a device still holds that the database already has.
//
// This used to happen inside automatic import, on whatever one batch had just confirmed. That tied
// the number of deletions per request to the size of an import batch, and on a phone every request
// raises a system confirmation dialog, so the user was asked once per handful of photos. It is now
// its own operation, run when the user asks for it: one walk, one set of dialogs, at a moment they
// chose.
//
// It answers its own question rather than being told what to delete. For each item the device still
// holds it asks the hash cache what that photo hashes to, and the database whether it holds that
// hash. Nothing is deleted on the strength of an import having reported success: the database
// saying it holds the content is the only thing that counts.
//
// What it cannot see: a photo imported on another device and synced into this database. This device
// never hashed it, so the cache has no entry for it, and finding out would mean copying and hashing
// every photo in the library, which is the cost automatic import exists to avoid. Such a photo is
// left on the device.
//

//
// How many source files are deleted per request.
//
// Batched because Android and iOS both put a system confirmation in front of deleting media the app
// does not own, and one dialog per photo would be unusable. Whether one request can carry every
// pending item, and what the real ceiling is on each platform, has not been established: this is
// the number that was already here.
//
export const SOURCE_CLEANUP_BATCH_SIZE = 50;

//
// How many items are read from the source per page while looking for what to delete.
//
export const CLEANUP_PAGE_SIZE = 50;

//
// Folders are the source kind node-api can serve. Registered here as well as by the import scanner
// because this task can run on its own, before an import has been started in this process.
//
registerMediaSourceBuilder("folder", (sources, options) => {
    return new FolderMediaSource(
        sources as IFolderAutoImportSource[],
        options.sessionTempDir,
        options.uuidGenerator
    );
});

//
// Payload for the cleanup-sources task.
//
export interface ICleanupSourcesData {
    // Identifies the database to check against, and its optional encryption key.
    storageDescriptor: IDatabaseDescriptor;

    // Where to look for photos to delete: the same sources automatic import watches.
    settings: IAutoImportSettings;

    // When true, nothing is deleted and the result says what would have been. This is what the
    // button uses to show a count before the user commits to anything.
    dryRun: boolean;
}

//
// What a cleanup run did.
//
export interface ICleanupSourcesResult {
    // How many items the source was asked about.
    considered: number;

    // The source ids that are in the database and can go.
    deletableSourceIds: string[];

    // The source ids that were actually deleted. Empty for a dry run.
    deletedSourceIds: string[];

    // The source ids the device refused or failed to delete.
    failedSourceIds: string[];
}

//
// Deletes the photos the device still holds that the database already has.
//
export async function cleanupSourcesHandler(data: ICleanupSourcesData, context: ITaskContext): Promise<ICleanupSourcesResult> {
    const settings = normaliseAutoImportSettings(data.settings);
    if (settings.sources.length === 0) {
        throw new Error("Cleanup was asked to run with no sources configured. There is nowhere to look.");
    }

    const sessionTempDir = path.join(getProcessTmpDir(), "photosphere", context.uuidGenerator.generate());
    await ensureDir(sessionTempDir);

    const { s3Config, encryptionKeyPems } = await resolveStorageCredentials(data.storageDescriptor.databasePath, data.storageDescriptor.encryptionKey);
    const { options: storageOptions } = await loadEncryptionKeysFromPem(encryptionKeyPems);
    const { storage } = createStorage(data.storageDescriptor.databasePath, s3Config, storageOptions);
    const bsonDatabase = new BsonDatabase(storage, ".db/bson", context.uuidGenerator, context.timestampProvider);
    const metadataCollection = bsonDatabase.collection<IAsset>("metadata");

    const localHashCache = new HashCache(getHashCacheDir(data.storageDescriptor.databasePath), true);
    await localHashCache.load();

    const source = buildMediaSource(settings.sources, {
        sessionTempDir,
        uuidGenerator: context.uuidGenerator,
    });

    //
    // Whether the database holds the photo this item is, going by what this device recorded when it
    // hashed it. All three parts of the entry have to agree, because a photo library may reuse the
    // id of an item that has been deleted, and deleting the wrong photo is not recoverable.
    //
    async function isInTheDatabase(item: IMediaItem): Promise<boolean> {
        const cacheEntry = localHashCache.getHash(item.sourceId);
        if (!cacheEntry) {
            return false;
        }

        if (cacheEntry.length !== item.size || cacheEntry.lastModified.getTime() !== item.createdAt.getTime()) {
            return false;
        }

        // Asked of the database itself even when an asset id is recorded, because this deletes the
        // user's only copy of a photo. An id in the cache is good enough to skip an import; it is
        // not good enough to delete anything.
        const existingRecords = await metadataCollection.sortIndex("hash", "asc").findByValue(cacheEntry.hash.toString("hex"));
        return existingRecords.length > 0;
    }

    try {
        const deletableSourceIds: string[] = [];
        let considered = 0;
        let cursor: string | undefined = undefined;

        do {
            const page = await source.listPage(cursor, CLEANUP_PAGE_SIZE);
            for (const item of page.items) {
                considered += 1;
                if (await isInTheDatabase(item)) {
                    deletableSourceIds.push(item.sourceId);
                }
            }
            cursor = page.nextCursor;
        } while (cursor !== undefined && !context.isCancelled());

        if (data.dryRun || deletableSourceIds.length === 0) {
            return { considered, deletableSourceIds, deletedSourceIds: [], failedSourceIds: [] };
        }

        const cleanupResult = await runSourceCleanup(source, deletableSourceIds, SOURCE_CLEANUP_BATCH_SIZE);
        if (cleanupResult.failedSourceIds.length > 0) {
            // Not retried: a source that refused once will refuse again, and looping would ask the
            // user the same question forever. Said out loud so the files are known to still be there.
            log.error(`Cleanup could not delete ${cleanupResult.failedSourceIds.length} source file(s): ${cleanupResult.failedSourceIds.join(", ")}`);
        }

        return {
            considered,
            deletableSourceIds,
            deletedSourceIds: cleanupResult.deletedSourceIds,
            failedSourceIds: cleanupResult.failedSourceIds,
        };
    }
    finally {
        await swallowError(() => remove(sessionTempDir));
    }
}
