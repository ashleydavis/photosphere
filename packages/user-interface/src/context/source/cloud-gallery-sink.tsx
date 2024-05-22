//
// Provides a sink for adding/updating assets in the cloud.
//

import { IApi, IAssetData, IAssetSink } from "database";

//
// Use the "Cloud sink" in a component.
//
export function useCloudGallerySink({ api }: { api: IApi }): IAssetSink {

    //
    // Stores an asset.
    //
    async function storeAsset(collectionId: string, assetId: string, assetType: string, assetData: IAssetData): Promise<void> {
        await api.uploadSingleAsset(collectionId, assetId, assetType, assetData);
    }


    return {
        storeAsset,
    };
}
