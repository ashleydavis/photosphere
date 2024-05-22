import { IApi, IAssetData, IAssetSource } from "database";

//
// Provides a source of assets for the gallery from the cloud.
//
export function useCloudGallerySource({ api }: { api: IApi }): IAssetSource {

    //
    // Loads data for an asset.
    //
    async function loadAsset(collectionId: string, assetId: string, assetType: string): Promise<IAssetData | undefined> {
        const assetBlob = await api.getAsset(collectionId, assetId, assetType);
        return {
            contentType: assetBlob.type,
            data: assetBlob,
        };
    }

    return {
        isInitialised: api.isInitialised,
        loadAsset,
    };
}
