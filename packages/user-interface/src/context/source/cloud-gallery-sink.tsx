//
// Provides a sink for adding/updating assets in the cloud.
//

import { useApi } from "../api-context";
import { IGallerySink } from "./gallery-sink";
import { ICollectionOps } from "../../def/ops";

//
// Use the "Cloud sink" in a component.
//
export function useCloudGallerySink(): IGallerySink {

    //
    // Interface to the backend.
    //
    const api = useApi();

    //
    // Uploads an asset.
    //
    async function uploadAsset(collectionId: string, assetId: string, assetType: string, contentType: string, data: Blob): Promise<void> {
        await api.uploadSingleAsset(collectionId, assetId, assetType, contentType, data);
    }

    //
    // Updates the configuration of the asset.
    //
    async function updateAsset(collectionOps: ICollectionOps): Promise<void> {
        await api.submitOperations({
            ops: [ collectionOps ],
        });
    }

    //
    // Check that asset that has already been uploaded with a particular hash.
    //
    async function checkAsset(collectionId: string, hash: string): Promise<string | undefined> {
        return await api.checkAsset(collectionId, hash);
    }    

    return {
        uploadAsset,
        updateAsset,
        checkAsset,
    };
}
