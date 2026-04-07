import { createWriteStream } from "fs";
import { pipeline } from "stream/promises";
import type { IStorage } from "storage";
import { createLazyDatabaseStorage, streamAsset } from "./media-file-database";
import type { ITaskContext } from "task-queue";

//
// Cache of lazy database storage instances keyed by database path.
// Avoids recreating storage on every save-asset task.
//
const storageCache = new Map<string, IStorage>();

//
// Returns a cached lazy storage instance for the given database path, creating one if needed.
//
async function getAssetStorage(databasePath: string): Promise<IStorage> {
    const cached = storageCache.get(databasePath);
    if (cached) {
        return cached;
    }
    const storage = await createLazyDatabaseStorage(databasePath);
    storageCache.set(databasePath, storage);
    return storage;
}

//
// Data payload for the save-asset task.
//
export interface ISaveAssetData {
    //
    // The ID of the asset to save.
    //
    assetId: string;

    //
    // The asset type to fetch (e.g. "asset", "display", "thumb").
    //
    assetType: string;

    //
    // The destination file path chosen by the user.
    //
    destPath: string;

    //
    // The database path the asset belongs to.
    //
    databasePath: string;
}

//
// Background task handler that streams an asset from the database to a local file.
//
export async function saveAssetHandler(data: ISaveAssetData, _context: ITaskContext): Promise<void> {
    const { assetId, assetType, destPath, databasePath } = data;

    const storage = await getAssetStorage(databasePath);
    const assetStream = await streamAsset(storage, assetId, assetType);
    const writeStream = createWriteStream(destPath);
    await pipeline(assetStream, writeStream);
}
