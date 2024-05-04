//
// Provides a sink for adding/updating assets to indexeddb.
//

import { IAsset } from "../../def/asset";
import { IGallerySink } from "./gallery-sink";

//
// Use the "Local sink" in a component.
//
export function useLocalGallerySink({ indexeddbSink, outgoingSink }: { indexeddbSink: IGallerySink, outgoingSink: IGallerySink }): IGallerySink {

    //
    // Uploads an asset.
    //
    async function uploadAsset(assetId: string, assetType: string, contentType: string, data: Blob): Promise<void> {
        // 
        // Store the asset locally.
        //
        await indexeddbSink.uploadAsset(assetId, assetType, contentType, data);

        // 
        // Queue the asset for upload to the cloud.
        //
        await outgoingSink.uploadAsset(assetId, assetType, contentType, data);
    }

    //
    // Updates the configuration of the asset.
    //
    async function updateAsset(assetId: string, assetUpdate: Partial<IAsset>): Promise<void> {
        //
        // Update the asset locally.
        //
        await indexeddbSink.updateAsset(assetId, assetUpdate);

        //
        // Queue the update for upload to the cloud.
        //
        await outgoingSink.updateAsset(assetId, assetUpdate);
    }

    //
    // Check if asset has already been uploaded with a particular hash.
    //
    async function checkAsset(hash: string): Promise<string | undefined> {       
        const result = await indexeddbSink.checkAsset(hash);
        if (result) {
            return result;
        }

        return await outgoingSink.checkAsset(hash);
    }

    return {
        uploadAsset,
        updateAsset,
        checkAsset,
    };
}
