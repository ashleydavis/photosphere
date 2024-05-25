//todo: prolly don't need this now!

//
// Provides a sink for adding/updating assets in the cloud.
//

import { IApi, IAssetData, IAssetSink, IDatabaseOp } from "database";

//
// Use the "Cloud sink" in a component.
//
export function useCloudGallerySink({ api }: { api: IApi }): IAssetSink {

    //
    // Submits operations to change the database.
    //
    async function submitOperations(ops: IDatabaseOp[]): Promise<void> {
        await api.submitOperations(ops);
    }

    //
    // Stores an asset.
    //
    async function storeAsset(collectionId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void> {
        await api.uploadSingleAsset(collectionId, assetId, assetType, assetData);
    }

    return {
        submitOperations,
        storeAsset,
    };
}
