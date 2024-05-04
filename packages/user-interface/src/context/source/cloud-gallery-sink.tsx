//
// Provides a sink for adding/updating assets in the cloud.
//

import { useApi } from "../api-context";
import { IGallerySink } from "./gallery-sink";
import { IAsset } from "../../def/asset";

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
    async function uploadAsset(assetId: string, assetType: string, contentType: string, data: Blob): Promise<void> {
        await api.uploadSingleAsset(assetId, assetType, contentType, data);
    }

    //
    // Updates the configuration of the asset.
    //
    async function updateAsset(assetId: string, assetUpdate: Partial<IAsset>): Promise<void> {
        await api.submitOperations([
            {
                id: assetId,
                ops: [
                    {
                        type: "set",
                        fields: assetUpdate, //TODO: Should use push/pull for labels.
                    }
                ],
            },        
        ]);
    }

    //
    // Check that asset that has already been uploaded with a particular hash.
    //
    async function checkAsset(hash: string): Promise<string | undefined> {
        return await api.checkAsset(hash);
    }    

    return {
        uploadAsset,
        updateAsset,
        checkAsset,
    };
}
