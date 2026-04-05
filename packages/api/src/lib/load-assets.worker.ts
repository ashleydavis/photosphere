//
// Load assets worker handler - loads assets from database in pages
//

import type { ITaskContext } from "task-queue";
import { createLazyDatabaseStorage, createMediaFileDatabase, isDatabasePartial } from "./media-file-database";
import { createStorage } from "storage";
import type { ILoadAssetsData, ILoadAssetsResult } from "./load-assets.types";

//
// Handler for loading assets from database
// Note: This handler sends progress messages via a callback mechanism
// The actual streaming is handled by the dev-server which sends messages to the frontend
//
export async function loadAssetsHandler(
    data: ILoadAssetsData,
    context: ITaskContext
): Promise<ILoadAssetsResult> {
    const { uuidGenerator, timestampProvider } = context;

    if (!data.databasePath) {
        throw new Error("databasePath is required");
    }

    console.log(`Loading assets from database ${data.databasePath}`);

    const isPartial = await isDatabasePartial(data.databasePath);

    // Only wrap in lazy storage for partial databases; plain storage otherwise.
    const storage = isPartial
        ? await createLazyDatabaseStorage(data.databasePath)
        : createStorage(data.databasePath, undefined, undefined).storage;

    // Create database instance
    const database = createMediaFileDatabase(storage, uuidGenerator, timestampProvider);
    
    const metadataCollection = database.metadataCollection;
    
    // Iterate through assets in sorted order (by photoDate, descending)
    // Data is already organized into pages, so we send each page as-is
    let nextPageId: string | undefined;
    let totalAssets = 0;
    let batchesSent = 0;
    
    while (!context.isCancelled()) {
        //todo: The sort order should be configurable.
        const result = await metadataCollection.sortIndex("photoDate", "desc").getPage(nextPageId);
        
        if (result.records.length === 0) {
            break;
        }
        
        // Send the entire page
        totalAssets += result.records.length;
        batchesSent++;
        
        // Send page via message
        context.sendMessage({ type: "asset-page", databasePath: data.databasePath, batch: result.records });
        
        if (!result.nextPageId) {
            break;
        }
        
        nextPageId = result.nextPageId;
    }
    
    // Queue thumb prefetch only for partial databases.
    if (isPartial) {
        context.queueTask("prefetch-database", { databasePath: data.databasePath }, data.databasePath);
    }

    return {
        totalAssets,
        batchesSent,
    };
}

