import type { ITaskQueue } from "task-queue";
import type { ILoadAssetData, ILoadAssetResult } from "./load-asset.types";

//
// Loads a single asset from the database using a background task
// Returns a promise that resolves with the asset data as a Blob
// Throws an error if the asset is not found or the task fails
//
export async function loadAsset(queue: ITaskQueue, assetId: string, assetType: string): Promise<Blob> {
    const data: ILoadAssetData = {
        assetId,
        assetType,
    };
    
    const result = await queue.awaitTask<ILoadAssetData, ILoadAssetResult>("load-asset", data);

    // Convert base64 data to Blob
    const binaryString = atob(result.assetData); //TODO: Be good if we could pass binary data thru and avoid this conversion.
    const bytes = new Uint8Array(binaryString.length);
    for (let i = 0; i < binaryString.length; i++) {
        bytes[i] = binaryString.charCodeAt(i);
    }
    return new Blob([bytes]);
}

