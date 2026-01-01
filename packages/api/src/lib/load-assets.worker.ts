//
// Load assets worker handler - loads assets from database in pages
//

import { createStorage } from "storage";
import { resolve } from "node:path";
import type { ITaskContext } from "task-queue";
import { createMediaFileDatabase, loadDatabase } from "./media-file-database";
import type { ILoadAssetsData, ILoadAssetsResult } from "./load-assets.types";

//
// Handler for loading assets from database
// Note: This handler sends progress messages via a callback mechanism
// The actual streaming is handled by the dev-server which sends messages to the frontend
//
export async function loadAssetsHandler(
    _data: ILoadAssetsData,
    _workingDirectory: string,
    context: ITaskContext
): Promise<ILoadAssetsResult> {
    const { uuidGenerator, timestampProvider } = context;

    // Use hardcoded path to test database (relative to project root)
    // Resolve from current file location: packages/api/src/lib -> project root -> test/dbs/v5
    // In ES modules, we use import.meta.url to get __dirname equivalent
    const dbDir = resolve(__dirname, "../../../../test/dbs/v5");

    // Create storage without encryption
    const { storage: assetStorage } = createStorage(dbDir, undefined, undefined);
    
    // Create database instance
    const database = createMediaFileDatabase(assetStorage, uuidGenerator, timestampProvider);
    
    // Load the database
    await loadDatabase(assetStorage, database.metadataCollection);
    
    const metadataCollection = database.metadataCollection;
    
    // Iterate through assets in sorted order (by photoDate, descending)
    // Data is already organized into pages, so we send each page as-is
    let nextPageId: string | undefined;
    let totalAssets = 0;
    let batchesSent = 0;
    
    while (true) {
        //todo: The sort order should be configurable.
        const result = await metadataCollection.getSorted("photoDate", "desc", nextPageId);
        
        if (result.records.length === 0) {
            break;
        }
        
        // Send the entire page
        totalAssets += result.records.length;
        batchesSent++;
        
        // Send page via message
        context.sendMessage({ type: "asset-page", batch: result.records });
        
        if (!result.nextPageId) {
            break;
        }
        
        nextPageId = result.nextPageId;
    }
    
    return {
        totalAssets,
        batchesSent,
    };
}

