//
// Provides a sink for adding/updating assets to indexeddb.
//

import { IAsset } from "../../def/asset";
import { IGallerySink } from "./gallery-sink";

//
// Use the "Local sink" in a component.
//
export function useLocalGallerySink({ cloudSink }: { cloudSink: IGallerySink }): IGallerySink {

    //
    // Uploads an asset.
    //
    async function uploadAsset(assetId: string, assetType: string, contentType: string, data: Blob): Promise<void> {

        ///todo: save it in indexeddb. Queue for upload to cloud.

        await cloudSink.uploadAsset(assetId, assetType, contentType, data);
    }

    //
    // Adds an asset to the gallery.
    //
    async function addAsset(asset: IAsset): Promise<void> {

        const assetId = await cloudSink.addAsset(asset);

        //todo: add to indexeddb. Queue for upload to cloud.
    }

    //
    // Updates the configuration of the asset.
    //
    async function updateAsset(assetId: string, assetUpdate: Partial<IAsset>): Promise<void> {

        //todo: update in indexeddb. Queue for upload to cloud.

        await cloudSink.updateAsset(assetId, assetUpdate);
    }

    //
    // Check that asset that has already been uploaded with a particular hash.
    //
    async function checkAsset(hash: string): Promise<string | undefined> {
        return await cloudSink.checkAsset(hash);

        //todo: check and fallback to cloud.
    }

    return {
        addAsset,
        uploadAsset,
        updateAsset,
        checkAsset,
    };
}
