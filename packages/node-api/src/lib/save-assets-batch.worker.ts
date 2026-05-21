import { createWriteStream } from "fs";
import { join } from "path";
import { pipeline } from "stream/promises";
import type { IStorage } from "storage";
import { createLazyDatabaseStorage, streamAsset } from "./media-file-database";
import type { ITaskContext } from "task-queue";

//
// Cache of lazy database storage instances keyed by database path.
// Avoids recreating storage on every task.
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
// Describes a single asset to be saved as part of a batch download.
//
export interface ISaveAssetsBatchItem {
    //
    // The ID of the asset to save.
    //
    assetId: string;

    //
    // The asset type to fetch (e.g. "asset", "display", "thumb").
    //
    assetType: string;

    //
    // The filename to save as inside the chosen folder.
    //
    filename: string;
}

//
// Data payload for the save-assets-batch task.
//
export interface ISaveAssetsBatchData {
    //
    // The assets to download.
    //
    assets: ISaveAssetsBatchItem[];

    //
    // The destination folder chosen by the user.
    //
    folderPath: string;

    //
    // The database path the assets belong to.
    //
    databasePath: string;
}

//
// Details of a single file that failed to save.
//
export interface ISaveAssetsBatchFailure {
    //
    // The filename of the asset that failed.
    //
    filename: string;

    //
    // The error message describing why the save failed.
    //
    error: string;
}

//
// Result returned by the save-assets-batch task.
//
export interface ISaveAssetsBatchResult {
    //
    // The destination folder all files were saved into.
    //
    folderPath: string;

    //
    // Filenames of assets that were saved successfully.
    //
    succeededFiles: string[];

    //
    // Details of assets that failed to save.
    //
    failedFiles: ISaveAssetsBatchFailure[];
}

//
// Background task handler that saves multiple assets into a single folder.
// Processes each asset individually and accumulates success and failure results.
//
export async function saveAssetsBatchHandler(data: ISaveAssetsBatchData, _context: ITaskContext): Promise<ISaveAssetsBatchResult> {
    const { assets, folderPath, databasePath } = data;
    const storage = await getAssetStorage(databasePath);
    const succeededFiles: string[] = [];
    const failedFiles: ISaveAssetsBatchFailure[] = [];

    for (const asset of assets) {
        try {
            const destPath = join(folderPath, asset.filename);
            const assetStream = await streamAsset(storage, asset.assetId, asset.assetType);
            const writeStream = createWriteStream(destPath);
            await pipeline(assetStream, writeStream);
            succeededFiles.push(asset.filename);
        }
        catch (err) {
            failedFiles.push({
                filename: asset.filename,
                error: err instanceof Error ? err.message : String(err),
            });
        }
    }

    return { folderPath, succeededFiles, failedFiles };
}
