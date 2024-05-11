//
// Provides a sink for adding/updating assets in the cloud.
//

import { useApi } from "../api-context";
import { IGallerySink } from "./gallery-sink";
import { IDatabaseOp } from "../../def/ops";
import { IAssetData } from "../../def/asset-data";

//
// Use the "Cloud sink" in a component.
//
export function useCloudGallerySink(): IGallerySink {

    //
    // Interface to the backend.
    //
    const api = useApi();

    //
    // Stores an asset.
    //
    async function storeAsset(collectionId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void> {
        await api.uploadSingleAsset(collectionId, assetId, assetType, assetData);
    }

    //
    // Submits operations to change the database.
    //
    async function submitOperations(ops: IDatabaseOp[]): Promise<void> {
        await api.submitOperations(ops);
    }

    //
    // Check that asset that has already been uploaded with a particular hash.
    //
    async function checkAsset(collectionId: string, hash: string): Promise<string | undefined> {
        return await api.checkAsset(collectionId, hash);
    }    

    return {
        storeAsset,
        submitOperations,
        checkAsset,
    };
}
